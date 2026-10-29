import Foundation

enum AddonError: LocalizedError {
    case badURL, http(Int), decode
    var errorDescription: String? {
        switch self {
        case .badURL: return "That doesn't look like an addon manifest URL."
        case .http(let c): return "Addon returned HTTP \(c)."
        case .decode: return "Couldn't read the addon's response."
        }
    }
}

enum AddonAPI {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.requestCachePolicy = .useProtocolCachePolicy
        c.urlCache = URLCache(memoryCapacity: 20_000_000, diskCapacity: 100_000_000)
        return URLSession(configuration: c)
    }()

    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("stremio://") { s = "https://" + s.dropFirst("stremio://".count) }
        if !s.contains("://") { s = "https://" + s }
        if !s.hasSuffix("manifest.json") {
            s = (s.hasSuffix("/") ? s : s + "/") + "manifest.json"
        }
        return URL(string: s) != nil ? s : nil
    }

    static func get<T: Decodable>(_ type: T.Type, _ urlString: String) async throws -> T {
        guard let url = URL(string: urlString) else { throw AddonError.badURL }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // Each request's timing (NetTrace): slow at the server, queued, or not connecting.
        let host = url.host ?? "?"
        let others = NetTrace.begin(host)
        defer { NetTrace.end(host) }
        let timer = NetTrace.Timer()
        let t0 = CFAbsoluteTimeGetCurrent()
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req, delegate: timer)
        } catch {
            NetTrace.report("addon", url: url, others: others, started: t0, timer: timer, status: nil, bytes: nil, error: error)
            throw error
        }
        NetTrace.report("addon", url: url, others: others, started: t0, timer: timer, status: (resp as? HTTPURLResponse)?.statusCode, bytes: data.count, error: nil)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw AddonError.http(http.statusCode) }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw AddonError.decode }
    }

    static func manifest(_ url: String) async throws -> AddonManifest {
        try await get(AddonManifest.self, url)
    }

    private static func enc(_ s: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?&=")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    struct CatalogResponse: Decodable { var metas: [MetaItem]? }
    struct MetaResponse: Decodable { var meta: MetaItem? }
    struct StreamsResponse: Decodable { var streams: [AddonStream]? }
    struct SubtitlesResponse: Decodable { var subtitles: [AddonSubtitle]? }

    static func catalog(_ addon: InstalledAddon, _ cat: AddonManifest.Catalog, extra: [String: String] = [:]) async throws -> [MetaItem] {
        var path = "\(addon.baseURL)/catalog/\(enc(cat.type))/\(enc(cat.id))"
        if !extra.isEmpty {
            let parts = extra.sorted { $0.key < $1.key }.map { "\(enc($0.key))=\(enc($0.value))" }
            path += "/" + parts.joined(separator: "&")
        }
        return try await get(CatalogResponse.self, path + ".json").metas ?? []
    }

    static func meta(_ addon: InstalledAddon, type: String, id: String) async throws -> MetaItem? {
        try await get(MetaResponse.self, "\(addon.baseURL)/meta/\(enc(type))/\(enc(id)).json").meta
    }

    static func streams(_ addon: InstalledAddon, type: String, id: String) async throws -> [AddonStream] {
        try await get(StreamsResponse.self, "\(addon.baseURL)/stream/\(enc(type))/\(enc(id)).json").streams ?? []
    }

    static func subtitles(_ addon: InstalledAddon, type: String, id: String) async throws -> [AddonSubtitle] {
        try await get(SubtitlesResponse.self, "\(addon.baseURL)/subtitles/\(enc(type))/\(enc(id)).json").subtitles ?? []
    }
}

@MainActor
final class AddonStore: ObservableObject {
    static let shared = AddonStore()
    static let cinemeta = "https://v3-cinemeta.strem.io/manifest.json"

    @Published var addons: [InstalledAddon] = [] { didSet { save() } }
    @Published var installing = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: "addons"),
           let list = try? JSONDecoder().decode([InstalledAddon].self, from: data) {
            addons = list
        }
        // 1.6: metadata is built in (IMDb); the metadata catalog addon that
        // earlier versions installed automatically is removed once.
        if !UserDefaults.standard.bool(forKey: "cinemetaRemoved") {
            UserDefaults.standard.set(true, forKey: "cinemetaRemoved")
            UserDefaults.standard.set(true, forKey: "addonsSeeded")
            addons.removeAll { $0.transportURL == Self.cinemeta || $0.manifest.id == "com.linvo.cinemeta" }
        }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(addons), forKey: "addons")
    }

    func install(_ raw: String) async throws {
        guard let url = AddonAPI.normalize(raw) else { throw AddonError.badURL }
        installing = true
        defer { installing = false }
        let manifest = try await AddonAPI.manifest(url)
        let addon = InstalledAddon(transportURL: url, manifest: manifest)
        if let i = addons.firstIndex(where: { $0.transportURL == url || $0.manifest.id == manifest.id && $0.transportURL == url }) {
            addons[i] = addon
        } else {
            addons.append(addon)
        }
    }

    func refreshAll() async {
        for (i, a) in addons.enumerated() {
            if let m = try? await AddonAPI.manifest(a.transportURL), i < addons.count {
                addons[i].manifest = m
            }
        }
    }

    /// Settings preset import: adds the addons that aren't installed yet (by
    /// address), one by one, so an addon this version can't read is skipped
    /// instead of failing the rest. Returns how many were added.
    func merge(_ json: Data) -> Int {
        guard let list = try? JSONSerialization.jsonObject(with: json) as? [Any] else { return 0 }
        var n = 0
        for item in list {
            guard let data = try? JSONSerialization.data(withJSONObject: item),
                  let a = try? JSONDecoder().decode(InstalledAddon.self, from: data),
                  !addons.contains(where: { $0.transportURL == a.transportURL }) else { continue }
            addons.append(a)
            n += 1
        }
        return n
    }

    func remove(_ a: InstalledAddon) { addons.removeAll { $0.id == a.id } }
    func move(from: IndexSet, to: Int) { addons.move(fromOffsets: from, toOffset: to) }

    func metaAddon(type: String, id: String, preferred: InstalledAddon?) -> InstalledAddon? {
        if let preferred, preferred.manifest.supports(resource: "meta", type: type, id: id) { return preferred }
        return addons.first { $0.manifest.supports(resource: "meta", type: type, id: id) }
    }

    func streamAddons(type: String, id: String) -> [InstalledAddon] {
        addons.filter { $0.manifest.supports(resource: "stream", type: type, id: id) }
    }

    func subtitleAddons(type: String, id: String) -> [InstalledAddon] {
        addons.filter { $0.manifest.supports(resource: "subtitles", type: type, id: id) }
    }
}
