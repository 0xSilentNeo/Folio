import UIKit

/// An item of a Jellyfin server (BaseItemDto), the fields the browser uses.
/// Anything but the id may be missing or odd without losing the listing.
struct JellyfinItem: Decodable, Hashable {
    var id: String
    var name: String
    var type: String
    var collectionType: String?
    var isFolder: Bool
    var mediaType: String?
    var year: Int?
    var index: Int?
    var parentIndex: Int?
    var seriesName: String?
    var runTimeTicks: Int64?
    var created: Date?
    var path: String?
    var size: Int64?
    var primaryTag: String?
    var childCount: Int?

    private enum Keys: String, CodingKey {
        case id = "Id", name = "Name", type = "Type", collectionType = "CollectionType", isFolder = "IsFolder"
        case mediaType = "MediaType", year = "ProductionYear", index = "IndexNumber", parentIndex = "ParentIndexNumber"
        case seriesName = "SeriesName", runTimeTicks = "RunTimeTicks", created = "DateCreated", path = "Path"
        case mediaSources = "MediaSources", imageTags = "ImageTags", childCount = "ChildCount"
    }
    private struct Source: Decodable {
        var size: Int64?
        enum CodingKeys: String, CodingKey { case size = "Size" }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func opt<T: Decodable>(_ t: T.Type, _ k: Keys) -> T? { (try? c.decodeIfPresent(T.self, forKey: k)) ?? nil }
        id = try c.decode(String.self, forKey: .id)
        name = opt(String.self, .name) ?? ""
        type = opt(String.self, .type) ?? ""
        collectionType = opt(String.self, .collectionType)
        isFolder = opt(Bool.self, .isFolder) ?? false
        mediaType = opt(String.self, .mediaType)
        year = opt(Int.self, .year)
        index = opt(Int.self, .index)
        parentIndex = opt(Int.self, .parentIndex)
        seriesName = opt(String.self, .seriesName)
        runTimeTicks = opt(Int64.self, .runTimeTicks)
        created = opt(String.self, .created).flatMap(JellyfinAPI.date)
        path = opt(String.self, .path)
        size = opt([Source].self, .mediaSources)?.first?.size
        primaryTag = opt([String: String].self, .imageTags)?["Primary"]
        childCount = opt(Int.self, .childCount)
    }

    var entry: CatalogEntry {
        let kind: CatalogEntry.Kind
        switch type {
        case "CollectionFolder", "UserView": kind = .library
        case "Series": kind = .series
        case "Season": kind = .season
        case "Movie": kind = .movie
        case "Episode": kind = .episode
        case "Audio", "AudioBook": kind = .audio
        default:
            if isFolder { kind = .folder }
            else if mediaType == "Audio" { kind = .audio }
            else { kind = .video }          // Video, MusicVideo, Trailer…
        }
        var e = CatalogEntry(id: id, kind: kind, name: name)
        e.libraryType = collectionType
        e.year = year
        if kind == .season { e.season = index } else { e.season = parentIndex; e.episode = index }
        e.seriesName = seriesName
        e.added = created
        e.size = size
        e.duration = runTimeTicks.map { Double($0) / 10_000_000 }
        e.fileName = path.map { ($0.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent }
        e.childCount = childCount
        e.children = kind == .library || isFolder ? id : nil
        e.image = primaryTag
        return e
    }
}

/// Jellyfin's API (10.8 and later): the addresses, the sign-in header and
/// the answers, kept apart from the network so tests can read them.
enum JellyfinAPI {
    /// Library types with nothing the player can open.
    static let skippedLibraries: Set<String> = ["books", "livetv", "photos"]

    /// The device model ("iPhone", "iPad"), as Jellyfin's Devices page lists it.
    @MainActor static var deviceModel: String { UIDevice.current.model }

    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }

    /// `Authorization: MediaBrowser Client="Folio", Device=…, DeviceId=…, Version=…`,
    /// with the token after signing in. Quotes and commas would end a value early.
    static func authorization(device: String, deviceID: String, version: String, token: String? = nil) -> String {
        func v(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: ",", with: " ") }
        var h = "MediaBrowser Client=\"Folio\", Device=\"\(v(device))\", DeviceId=\"\(v(deviceID))\", Version=\"\(v(version))\""
        if let token { h += ", Token=\"\(v(token))\"" }
        return h
    }

    static func signInRequest(base: URL, username: String, password: String, device: String, deviceID: String, version: String) -> URLRequest? {
        guard let url = ServerHTTP.endpoint(base, "/Users/AuthenticateByName") else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(authorization(device: device, deviceID: deviceID, version: version), forHTTPHeaderField: "Authorization")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])
        return r
    }

    struct Session: Hashable {
        var token: String
        var userID: String
        var userName: String?
    }

    static func decodeSignIn(_ data: Data) throws -> Session {
        struct Answer: Decodable {
            struct User: Decodable {
                var id: String
                var name: String?
                enum CodingKeys: String, CodingKey { case id = "Id", name = "Name" }
            }
            var token: String
            var user: User
            enum CodingKeys: String, CodingKey { case token = "AccessToken", user = "User" }
        }
        guard let a = try? JSONDecoder().decode(Answer.self, from: data), !a.token.isEmpty else { throw ServerError.parse }
        return Session(token: a.token, userID: a.user.id, userName: a.user.name)
    }

    static func decodeItems(_ data: Data) throws -> [JellyfinItem] {
        struct Answer: Decodable {
            var items: LenientList<JellyfinItem>
            enum CodingKeys: String, CodingKey { case items = "Items" }
        }
        guard let a = try? JSONDecoder().decode(Answer.self, from: data) else { throw ServerError.parse }
        return a.items.items
    }

    static func viewsURL(base: URL, userID: String) -> URL? {
        ServerHTTP.endpoint(base, "/Users/\(ServerHTTP.segment(userID))/Views")
    }

    /// A folder's children, sorted by name; a season's episodes in order,
    /// with their file sizes (MediaSources, asked for only there: it is
    /// large for a whole library).
    static func itemsURL(base: URL, userID: String, parentID: String, episodes: Bool) -> URL? {
        var q = [
            URLQueryItem(name: "ParentId", value: parentID),
            URLQueryItem(name: "SortBy", value: episodes ? "ParentIndexNumber,IndexNumber,SortName" : "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "Fields", value: episodes ? "DateCreated,Path,ChildCount,MediaSources" : "DateCreated,Path,ChildCount"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary"),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
        ]
        q.append(URLQueryItem(name: "EnableUserData", value: "false"))
        return ServerHTTP.endpoint(base, "/Users/\(ServerHTTP.segment(userID))/Items", q)
    }

    /// The file itself, as it is on the server (no transcoding).
    static func streamURL(base: URL, itemID: String) -> URL? {
        ServerHTTP.endpoint(base, "/Videos/\(ServerHTTP.segment(itemID))/stream", [URLQueryItem(name: "static", value: "true")])
    }

    static func imageURL(base: URL, itemID: String, tag: String?, maxHeight: Int) -> URL? {
        var q = [URLQueryItem(name: "maxHeight", value: String(maxHeight)), URLQueryItem(name: "quality", value: "90")]
        if let tag { q.append(URLQueryItem(name: "tag", value: tag)) }
        return ServerHTTP.endpoint(base, "/Items/\(ServerHTTP.segment(itemID))/Images/Primary", q)
    }

    /// Jellyfin's dates have seven digits of fractions ("…:56.1234567Z"),
    /// more than the ISO 8601 reader takes: they're dropped.
    static func date(_ s: String) -> Date? {
        var t = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        if !t.hasSuffix("Z"), t.range(of: #"[+-]\d\d:?\d\d$"#, options: .regularExpression) == nil { t += "Z" }
        return isoFormatter.date(from: t)
    }
    nonisolated(unsafe) private static let isoFormatter = ISO8601DateFormatter()
}

/// A signed-in Jellyfin server. Immutable: safe from any task.
final class JellyfinClient: CatalogSource, @unchecked Sendable {
    let server: MediaServer
    let base: URL
    private let session: JellyfinAPI.Session
    private let device: String

    /// `session`: one from Test connection, not saved yet; else the Keychain's.
    init?(server: MediaServer, session: JellyfinAPI.Session? = nil, device: String) {
        guard let base = server.baseURL else { return nil }
        if let session {
            self.session = session
        } else {
            guard let token = server.token, let user = server.userID else { return nil }
            self.session = JellyfinAPI.Session(token: token, userID: user)
        }
        self.server = server
        self.base = base
        self.device = device
    }

    /// Signs in with a user name and password; nothing is saved here.
    static func signIn(server: MediaServer, username: String, password: String, device: String) async throws -> JellyfinAPI.Session {
        guard let base = server.baseURL,
              let r = JellyfinAPI.signInRequest(base: base, username: username, password: password, device: device,
                                                deviceID: server.id.uuidString, version: JellyfinAPI.appVersion) else { throw ServerError.badAddress }
        do {
            let s = try JellyfinAPI.decodeSignIn(await ServerHTTP.data(r))
            dlog("servers", "jellyfin: signed in to \(base.host ?? "?")")
            return s
        } catch ServerError.unauthorized {
            throw JellyfinError.wrongLogin
        }
    }

    private func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(JellyfinAPI.authorization(device: device, deviceID: server.id.uuidString, version: JellyfinAPI.appVersion, token: session.token),
                   forHTTPHeaderField: "Authorization")
        return r
    }

    func children(of parent: CatalogEntry?) async throws -> [CatalogEntry] {
        guard let parent else {
            guard let url = JellyfinAPI.viewsURL(base: base, userID: session.userID) else { throw ServerError.badAddress }
            return try JellyfinAPI.decodeItems(await ServerHTTP.data(request(url)))
                .filter { !JellyfinAPI.skippedLibraries.contains($0.collectionType ?? "") }
                .map { var e = $0.entry; e.kind = .library; e.children = $0.id; return e }
        }
        return try await children(at: parent.children ?? parent.id, episodes: parent.kind == .season)
    }

    func children(at parentID: String, episodes: Bool) async throws -> [CatalogEntry] {
        guard let url = JellyfinAPI.itemsURL(base: base, userID: session.userID, parentID: parentID, episodes: episodes) else { throw ServerError.badAddress }
        return try JellyfinAPI.decodeItems(await ServerHTTP.data(request(url))).map(\.entry)
    }

    func mediaItem(for e: CatalogEntry, parent: CatalogEntry?) -> MediaItem {
        Self.mediaItem(for: e, parent: parent?.children ?? parent?.id, server: server, base: base)
    }

    static func mediaItem(for e: CatalogEntry, parent: String?, server: MediaServer, base: URL) -> MediaItem {
        var m = MediaItem(url: JellyfinAPI.streamURL(base: base, itemID: e.id)?.absoluteString ?? "",
                          title: CatalogTitles.playerTitle(e), subtitle: CatalogTitles.playerSubtitle(e), source: .url)
        m.historyKey = ServerPlayback.historyKey(kind: .jellyfin, server: server.id, item: e.id)
        m.remote = ServerItemRef(kind: .jellyfin, serverID: server.id, id: e.id, parent: parent)
        m.durationHint = e.duration
        // Continue Watching's picture. Jellyfin serves pictures without a
        // login, so the address carries none.
        if e.image != nil { m.artwork = JellyfinAPI.imageURL(base: base, itemID: e.id, tag: e.image, maxHeight: 360)?.absoluteString }
        if e.kind == .episode, let show = e.seriesName { m.anime = AnimeHint(title: show, episode: e.episode) }
        return m
    }

    func imageRequest(for e: CatalogEntry, pixels: Int) -> URLRequest? {
        guard e.image != nil, let url = JellyfinAPI.imageURL(base: base, itemID: e.id, tag: e.image, maxHeight: pixels) else { return nil }
        return request(url)
    }

    /// Ends the session on the server (the server was removed). Best effort.
    func signOut() async {
        guard let url = ServerHTTP.endpoint(base, "/Sessions/Logout") else { return }
        var r = request(url)
        r.httpMethod = "POST"
        r.timeoutInterval = 8
        _ = try? await ServerHTTP.data(r)
    }
}

enum JellyfinError: LocalizedError {
    case wrongLogin
    var errorDescription: String? { "Wrong user name or password." }
}
