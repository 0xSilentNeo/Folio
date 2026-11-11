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

    /// An addon's answer, its text's HTML references decoded (MetaItem.htmlDecoded).
    struct CatalogResponse: Decodable {
        var metas: [MetaItem]?
        init(from decoder: Decoder) throws {
            metas = try decoder.container(keyedBy: CodingKeys.self).lossy(MetaItem.self, .metas)?.map(\.htmlDecoded)
        }
        enum CodingKeys: String, CodingKey { case metas }
    }
    struct MetaResponse: Decodable {
        var meta: MetaItem?
        init(from decoder: Decoder) throws {
            meta = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(MetaItem.self, forKey: .meta)?.htmlDecoded
        }
        enum CodingKeys: String, CodingKey { case meta }
    }
    struct StreamsResponse: Decodable {
        var streams: [AddonStream]?
        init(from decoder: Decoder) throws {
            streams = try decoder.container(keyedBy: CodingKeys.self).lossy(AddonStream.self, .streams)
        }
        enum CodingKeys: String, CodingKey { case streams }
    }
    struct SubtitlesResponse: Decodable {
        var subtitles: [AddonSubtitle]?
        init(from decoder: Decoder) throws {
            subtitles = try decoder.container(keyedBy: CodingKeys.self).lossy(AddonSubtitle.self, .subtitles)
        }
        enum CodingKeys: String, CodingKey { case subtitles }
    }

    static func catalog(_ addon: InstalledAddon, _ cat: AddonManifest.Catalog, extra: [String: String] = [:]) async throws -> [MetaItem] {
        var path = "\(addon.baseURL)/catalog/\(enc(cat.type))/\(enc(cat.id))"
        if !extra.isEmpty {
            let parts = extra.sorted { $0.key < $1.key }.map { "\(enc($0.key))=\(enc($0.value))" }
            path += "/" + parts.joined(separator: "&")
        }
        return try await timed(addon, "catalog") { try await get(CatalogResponse.self, path + ".json").metas ?? [] }
    }

    static func meta(_ addon: InstalledAddon, type: String, id: String) async throws -> MetaItem? {
        try await timed(addon, "details") { try await get(MetaResponse.self, "\(addon.baseURL)/meta/\(enc(type))/\(enc(id)).json").meta }
    }

    static func streams(_ addon: InstalledAddon, type: String, id: String) async throws -> [AddonStream] {
        try await timed(addon, "streams") { try await get(StreamsResponse.self, "\(addon.baseURL)/stream/\(enc(type))/\(enc(id)).json").streams ?? [] }
    }

    static func subtitles(_ addon: InstalledAddon, type: String, id: String) async throws -> [AddonSubtitle] {
        try await timed(addon, "subtitles") { try await get(SubtitlesResponse.self, "\(addon.baseURL)/subtitles/\(enc(type))/\(enc(id)).json").subtitles ?? [] }
    }

    /// How long the addon took, for Addons' "answered in" line (1.27.0).
    /// A request given up on (a page left) isn't the addon's doing.
    private static func timed<T>(_ addon: InstalledAddon, _ what: String, _ work: () async throws -> T) async throws -> T {
        let t0 = CFAbsoluteTimeGetCurrent()
        let id = addon.id
        do {
            let result = try await work()
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            Task { @MainActor in AddonHealth.shared.note(id, ms: ms, ok: true, what: what) }
            return result
        } catch {
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            if !cancelled {
                let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                Task { @MainActor in AddonHealth.shared.note(id, ms: ms, ok: false, what: what) }
            }
            throw error
        }
    }
}

@MainActor
final class AddonStore: ObservableObject {
    static let shared = AddonStore()
    static let cinemeta = "https://v3-cinemeta.strem.io/manifest.json"

    @Published var addons: [InstalledAddon] = [] { didSet { save() } }
    @Published var installing = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: "addons") {
            if let list = try? JSONDecoder().decode([InstalledAddon].self, from: data) {
                addons = list
            } else {
                // 1.23.4: one entry this version couldn't read left the whole
                // list empty, and the next change saved the empty list over
                // it. Each addon is read on its own now, and the list as it
                // was is kept aside ("addonsUnreadable") instead of lost.
                let all = (try? JSONSerialization.jsonObject(with: data) as? [Any])?.count ?? -1
                addons = JSONDecoder().decodeLossy(InstalledAddon.self, from: data) ?? []
                if UserDefaults.standard.data(forKey: "addonsUnreadable") == nil {
                    UserDefaults.standard.set(data, forKey: "addonsUnreadable")
                }
                dlog("addons", "the saved list couldn't be read whole: \(addons.count) of \(all) read; the list as saved is kept")
            }
        }
        dlog("addons", "\(addons.count) installed\(addons.isEmpty ? "" : ": " + addons.map(\.manifest.name).joined(separator: ", "))")
        // 1.6: metadata is built in (IMDb); the metadata catalog addon that
        // earlier versions installed automatically is removed once.
        if !UserDefaults.standard.bool(forKey: "cinemetaRemoved") {
            UserDefaults.standard.set(true, forKey: "cinemetaRemoved")
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
        // The same addon from the same server with a new configuration (a
        // different key or options in its link) replaces the old copy; it
        // used to be added as a second one. Another server's copy stays apart.
        let host = URL(string: url)?.host
        if let i = addons.firstIndex(where: { $0.transportURL == url || ($0.manifest.id == manifest.id && URL(string: $0.transportURL)?.host == host) }) {
            addons[i] = addon
        } else {
            addons.append(addon)
        }
    }

    private var checkedThisLaunch = false

    /// Each addon's manifest read again once per launch (1.27.1): an addon
    /// that changed (a new version, new catalogs or types) is up to date
    /// without being installed again. Your switch and order stay.
    func checkForUpdates() async {
        guard !checkedThisLaunch, !addons.isEmpty else { return }
        checkedThisLaunch = true
        var updated: [String] = [], failed = 0
        await withTaskGroup(of: (String, AddonManifest?).self) { group in
            for a in addons {
                group.addTask { (a.id, try? await AddonAPI.manifest(a.transportURL)) }
            }
            for await (id, m) in group {
                guard let i = addons.firstIndex(where: { $0.id == id }) else { continue }
                guard let m else { failed += 1; continue }
                let old = addons[i].manifest
                guard old != m else { continue }
                addons[i].manifest = m
                updated.append(old.version != m.version ? "\(m.name) \(old.version ?? "?") → \(m.version ?? "?")" : m.name)
            }
        }
        dlog("addons", "update check: \(addons.count) addon(s), \(updated.isEmpty ? "none changed" : "updated " + updated.joined(separator: ", "))\(failed > 0 ? ", \(failed) didn't answer" : "")")
    }

    /// Cinemeta, installed and switched on (a Discover source, 1.27.1).
    var cinemetaAddon: InstalledAddon? { active.first(where: Self.isCinemeta) }
    var cinemetaInstalled: InstalledAddon? { addons.first(where: Self.isCinemeta) }

    /// Addons → Discover's Titles → Install: Cinemeta's own manifest.
    func installCinemeta() async throws {
        try await install(Self.cinemeta)
        dlog("addons", "Cinemeta installed for Discover")
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

    /// The addons switched on (1.27.0): the only ones asked for anything.
    var active: [InstalledAddon] { addons.filter(\.enabled) }

    // MARK: Catalogs on Discover (1.27.0)

    /// A catalog of an addon's, as a row on Discover.
    struct CatalogRef: Identifiable, Hashable {
        let addon: InstalledAddon
        let catalog: AddonManifest.Catalog
        var id: String { AddonStore.catalogKey(addon, catalog) }
    }

    nonisolated static func catalogKey(_ a: InstalledAddon, _ c: AddonManifest.Catalog) -> String { "\(a.id)|\(c.type)|\(c.id)" }

    /// Catalogs taken off Discover in Addons, by catalogKey.
    @Published var hiddenCatalogs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "hiddenAddonCatalogs") ?? []) {
        didSet { UserDefaults.standard.set(Array(hiddenCatalogs).sorted(), forKey: "hiddenAddonCatalogs") }
    }

    /// Every catalog Discover can show (one that needs no search words), in
    /// the addons' order. 1.27.1: films, series and anime only: no debrid
    /// library (Torrentio's "RealDebrid", type "other"), which was clutter
    /// (9 Nov), and not Cinemeta's, which is a source for the whole grid.
    var browsableCatalogs: [CatalogRef] {
        active.filter { !Self.isCinemeta($0) }.flatMap { a in
            a.manifest.catalogs.filter { $0.isBrowsable && Self.onDiscover($0) }.map { CatalogRef(addon: a, catalog: $0) }
        }
    }

    /// Cinemeta, Stremio's catalog of IMDb's titles (1.27.1: a Discover source).
    nonisolated static func isCinemeta(_ a: InstalledAddon) -> Bool {
        a.manifest.id == "com.linvo.cinemeta" || a.transportURL == "https://v3-cinemeta.strem.io/manifest.json"
    }

    nonisolated static func onDiscover(_ c: AddonManifest.Catalog) -> Bool {
        guard ["movie", "series", "anime"].contains(c.type.lowercased()) else { return false }
        let text = "\(c.id) \(c.name ?? "")".lowercased()
        return !["debrid", "premiumize", "torbox", "offcloud", "easynews"].contains { text.contains($0) }
    }

    /// The ones shown on Discover.
    var discoverCatalogs: [CatalogRef] { browsableCatalogs.filter { !hiddenCatalogs.contains($0.id) } }

    func metaAddon(type: String, id: String, preferred: InstalledAddon?) -> InstalledAddon? {
        if let preferred, preferred.enabled, preferred.manifest.supports(resource: "meta", type: type, id: id) { return preferred }
        return active.first { $0.manifest.supports(resource: "meta", type: type, id: id) }
    }

    func streamAddons(type: String, id: String) -> [InstalledAddon] {
        active.filter { $0.manifest.supports(resource: "stream", type: type, id: id) }
    }

    func subtitleAddons(type: String, id: String) -> [InstalledAddon] {
        active.filter { $0.manifest.supports(resource: "subtitles", type: type, id: id) }
    }
}
