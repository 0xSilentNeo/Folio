import Foundation

/// A library section or a metadata item of a Plex server's JSON answer
/// (`Accept: application/json`), the fields the browser uses. Plex sends
/// some numbers as text on some versions, so numbers and keys read either.
struct PlexItem: Decodable, Hashable {
    var key: String
    var ratingKey: String?
    var type: String?
    var title: String
    var year: Int?
    var index: Int?
    var parentIndex: Int?
    var grandparentTitle: String?
    var parentRatingKey: String?
    var addedAt: Date?
    /// Seconds (Plex sends milliseconds).
    var duration: Double?
    var thumb: String?
    var leafCount: Int?
    var childCount: Int?
    /// The first file of the first version: what plays.
    var partKey: String?
    var file: String?
    var size: Int64?

    private enum Keys: String, CodingKey {
        case key, ratingKey, type, title, year, index, parentIndex, grandparentTitle, parentRatingKey
        case addedAt, duration, thumb, leafCount, childCount
        case media = "Media", part = "Part", file, size
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func string(_ c: KeyedDecodingContainer<Keys>, _ k: Keys) -> String? {
            if let s = (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil { return s }
            return ((try? c.decodeIfPresent(Int64.self, forKey: k)) ?? nil).map(String.init)
        }
        func number(_ c: KeyedDecodingContainer<Keys>, _ k: Keys) -> Int64? {
            if let n = (try? c.decodeIfPresent(Int64.self, forKey: k)) ?? nil { return n }
            if let d = (try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil { return Int64(d) }
            return string(c, k).flatMap { Int64($0) }
        }
        guard let key = string(c, .key) else { throw ServerError.parse }
        self.key = key
        ratingKey = string(c, .ratingKey)
        type = string(c, .type)
        title = string(c, .title) ?? ""
        year = number(c, .year).map(Int.init)
        index = number(c, .index).map(Int.init)
        parentIndex = number(c, .parentIndex).map(Int.init)
        grandparentTitle = string(c, .grandparentTitle)
        parentRatingKey = string(c, .parentRatingKey)
        addedAt = number(c, .addedAt).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        duration = number(c, .duration).map { Double($0) / 1000 }
        thumb = string(c, .thumb)
        leafCount = number(c, .leafCount).map(Int.init)
        childCount = number(c, .childCount).map(Int.init)
        // Media[0].Part[0]
        if var media = try? c.nestedUnkeyedContainer(forKey: .media), !media.isAtEnd,
           let m = try? media.nestedContainer(keyedBy: Keys.self),
           var parts = try? m.nestedUnkeyedContainer(forKey: .part), !parts.isAtEnd,
           let p = try? parts.nestedContainer(keyedBy: Keys.self) {
            partKey = string(p, .key)
            file = string(p, .file)
            size = number(p, .size)
        }
    }

    /// A section of /library/sections.
    var sectionEntry: CatalogEntry {
        var e = CatalogEntry(id: key, kind: .library, name: title)
        e.libraryType = type
        e.children = "/library/sections/\(ServerHTTP.segment(key))/all"
        e.image = thumb
        return e
    }

    var entry: CatalogEntry {
        var kind: CatalogEntry.Kind
        switch type {
        case "show": kind = .series
        case "season": kind = .season
        case "movie": kind = .movie
        case "episode": kind = .episode
        case "track": kind = .audio
        default: kind = .video                  // clips; without a file, a folder (below)
        }
        // Artists, albums, collections: nothing to play, so opened as folders.
        if [.movie, .episode, .audio, .video].contains(kind), partKey == nil { kind = .folder }
        var e = CatalogEntry(id: ratingKey ?? key, kind: kind, name: title)
        e.year = year
        if kind == .season { e.season = index } else { e.season = parentIndex; e.episode = index }
        e.seriesName = grandparentTitle
        e.added = addedAt
        e.size = size
        e.duration = duration
        e.fileName = file.map { ($0.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent }
        e.childCount = kind == .series ? childCount : (leafCount ?? childCount)
        if !e.isPlayable {
            // A folder's own key says where its children are ("/library/metadata/12/children",
            // "/library/collections/7/children").
            if key.hasPrefix("/"), key.hasSuffix("/children") { e.children = key }
            else { e.children = ratingKey.map { "/library/metadata/\(ServerHTTP.segment($0))/children" } }
        }
        e.part = partKey
        e.image = thumb
        return e
    }
}

/// Plex's API with a pasted X-Plex-Token: addresses, headers and answers,
/// apart from the network so tests can read them. No plex.tv sign-in yet.
enum PlexAPI {
    /// Section types with nothing the player opens.
    static let skippedSections: Set<String> = ["photo"]

    /// Every request: JSON, the token, and who's asking (Plex lists the
    /// app on its Devices page by these).
    static func headers(token: String, clientID: String) -> [String: String] {
        [
            "Accept": "application/json",
            "X-Plex-Token": token,
            "X-Plex-Product": "Folio",
            "X-Plex-Version": JellyfinAPI.appVersion,
            "X-Plex-Client-Identifier": clientID,
            "X-Plex-Platform": "iOS",
        ]
    }

    static func sectionsURL(base: URL) -> URL? { ServerHTTP.endpoint(base, "/library/sections") }

    /// Where an entry's children are: a section's items, a show's seasons, a season's episodes.
    static func childrenURL(base: URL, path: String) -> URL? { ServerHTTP.endpoint(base, path) }
    /// The server's search across its libraries (Home's search, 1.22.5).
    static func searchURL(base: URL, query: String) -> URL? {
        ServerHTTP.endpoint(base, "/hubs/search", [URLQueryItem(name: "query", value: query), URLQueryItem(name: "limit", value: "15")])
    }
    /// Kinds of search results kept: films, shows, seasons and episodes
    /// (hubs/search also answers with music, people, collections…).
    static let searchedTypes: Set<String> = ["movie", "show", "season", "episode"]

    /// The file: a part key, already in URL form ("/library/parts/301/1690000000/file.mkv").
    static func partURL(base: URL, part: String) -> URL? { ServerHTTP.endpoint(base, part) }

    /// A smaller copy of a picture from Plex's own resizer.
    static func imageURL(base: URL, thumb: String, height: Int, poster: Bool) -> URL? {
        let width = poster ? height * 2 / 3 : height * 16 / 9
        return ServerHTTP.endpoint(base, "/photo/:/transcode", [
            URLQueryItem(name: "width", value: String(width)),
            URLQueryItem(name: "height", value: String(height)),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "upscale", value: "1"),
            URLQueryItem(name: "url", value: thumb),
        ])
    }

    /// The entries of a MediaContainer: sections come as "Directory", items as "Metadata".
    static func decode(_ data: Data) throws -> [PlexItem] {
        struct Answer: Decodable {
            struct Container: Decodable {
                var directory: LenientList<PlexItem>?
                var metadata: LenientList<PlexItem>?
                enum CodingKeys: String, CodingKey { case directory = "Directory", metadata = "Metadata" }
            }
            var container: Container
            enum CodingKeys: String, CodingKey { case container = "MediaContainer" }
        }
        guard let a = try? JSONDecoder().decode(Answer.self, from: data) else { throw ServerError.parse }
        return (a.container.directory?.items ?? []) + (a.container.metadata?.items ?? [])
    }

    /// hubs/search's answer: one hub per kind, each with its "Metadata".
    static func decodeHubs(_ data: Data) throws -> [PlexItem] {
        struct Answer: Decodable {
            struct Hub: Decodable {
                var metadata: LenientList<PlexItem>?
                enum CodingKeys: String, CodingKey { case metadata = "Metadata" }
            }
            struct Container: Decodable {
                var hub: LenientList<Hub>?
                enum CodingKeys: String, CodingKey { case hub = "Hub" }
            }
            var container: Container
            enum CodingKeys: String, CodingKey { case container = "MediaContainer" }
        }
        guard let a = try? JSONDecoder().decode(Answer.self, from: data) else { throw ServerError.parse }
        return (a.container.hub?.items ?? []).flatMap { $0.metadata?.items ?? [] }.filter { searchedTypes.contains($0.type ?? "") }
    }
}

/// A Plex server with its token. Immutable: safe from any task.
final class PlexClient: CatalogSource, @unchecked Sendable {
    let server: MediaServer
    let base: URL
    private let token: String

    /// `token`: one typed in the form and not saved yet (Test connection).
    init?(server: MediaServer, token: String? = nil) {
        guard let base = server.baseURL, let token = token ?? server.token, !token.isEmpty else { return nil }
        self.server = server
        self.base = base
        self.token = token
    }

    private func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        for (k, v) in PlexAPI.headers(token: token, clientID: server.id.uuidString) { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    func children(of parent: CatalogEntry?) async throws -> [CatalogEntry] {
        guard let parent else {
            guard let url = PlexAPI.sectionsURL(base: base) else { throw ServerError.badAddress }
            return try PlexAPI.decode(await ServerHTTP.data(request(url)))
                .filter { !PlexAPI.skippedSections.contains($0.type ?? "") }
                .map(\.sectionEntry)
        }
        guard let path = parent.children else { return [] }
        return try await children(at: path)
    }

    func children(at path: String) async throws -> [CatalogEntry] {
        guard let url = PlexAPI.childrenURL(base: base, path: path) else { throw ServerError.badAddress }
        return try PlexAPI.decode(await ServerHTTP.data(request(url))).map(\.entry)
    }

    func search(_ query: String) async throws -> [CatalogEntry] {
        guard let url = PlexAPI.searchURL(base: base, query: query) else { throw ServerError.badAddress }
        return try PlexAPI.decodeHubs(await ServerHTTP.data(request(url))).map(\.entry)
    }

    func mediaItem(for e: CatalogEntry, parent: CatalogEntry?) -> MediaItem {
        Self.mediaItem(for: e, parent: parent?.children, server: server, base: base)
    }

    static func mediaItem(for e: CatalogEntry, parent: String?, server: MediaServer, base: URL) -> MediaItem {
        let url = e.part.flatMap { PlexAPI.partURL(base: base, part: $0) }
        var m = MediaItem(url: url?.absoluteString ?? "", title: CatalogTitles.playerTitle(e), subtitle: CatalogTitles.playerSubtitle(e), source: .url)
        m.historyKey = ServerPlayback.historyKey(kind: .plex, server: server.id, item: e.id)
        m.remote = ServerItemRef(kind: .plex, serverID: server.id, id: e.id, part: e.part, parent: parent)
        m.durationHint = e.duration
        // No artwork address: Plex pictures need the token, and history is a plain file.
        if e.kind == .episode, let show = e.seriesName { m.anime = AnimeHint(title: show, episode: e.episode) }
        return m
    }

    func imageRequest(for e: CatalogEntry, pixels: Int) -> URLRequest? {
        guard let thumb = e.image, let url = PlexAPI.imageURL(base: base, thumb: thumb, height: pixels, poster: !e.hasWideArt) else { return nil }
        return request(url)
    }
}
