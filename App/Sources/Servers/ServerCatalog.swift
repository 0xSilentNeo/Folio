import Foundation

/// One entry of a Jellyfin or Plex server, as the browser shows it: a
/// library, a folder, a show, a season, or something to play. Both servers'
/// answers are read into this, so one browser (CatalogBrowserView) serves both.
struct CatalogEntry: Identifiable, Hashable {
    enum Kind: Hashable { case library, folder, series, season, movie, episode, video, audio }

    /// The server's id: a Jellyfin item id, a Plex rating key or section key.
    var id: String
    var kind: Kind
    /// As the server names it.
    var name: String
    /// A library's type ("movies", "tvshows", "music"; Plex "movie", "show", "artist").
    var libraryType: String?
    var year: Int?
    /// An episode's season, or a season's own number.
    var season: Int?
    var episode: Int?
    var seriesName: String?
    var added: Date?
    var size: Int64?
    /// Seconds.
    var duration: Double?
    /// The file's name, when the server sends it (clean titles of unmatched files).
    var fileName: String?
    /// Seasons of a show, episodes of a season, items of a library.
    var childCount: Int?
    /// Where its children are listed: a Jellyfin parent id, a Plex path
    /// ("/library/sections/1/all", "/library/metadata/12/children").
    var children: String?
    /// Plex: the file to play ("/library/parts/…").
    var part: String?
    /// A Jellyfin image tag or a Plex thumb path.
    var image: String?

    var isPlayable: Bool { [.movie, .episode, .video, .audio].contains(kind) }
    /// Episode stills and videos are 16:9; films, shows and seasons have posters.
    var hasWideArt: Bool { kind == .episode || kind == .video }
}

/// A Jellyfin or Plex server the browser reads from.
protocol CatalogSource: AnyObject, Sendable {
    var server: MediaServer { get }
    /// The libraries (nil) or an entry's children.
    func children(of parent: CatalogEntry?) async throws -> [CatalogEntry]
    /// Something to play, with `parent` (its season or folder) remembered
    /// for Continue Watching. Without its login: preparedForPlayback adds it.
    func mediaItem(for entry: CatalogEntry, parent: CatalogEntry?) -> MediaItem
    /// A picture of the entry about `pixels` tall, login in the headers.
    func imageRequest(for entry: CatalogEntry, pixels: Int) -> URLRequest?
    /// Films, shows and episodes whose name matches, from the whole server
    /// (Home's search, 1.22.5).
    func search(_ query: String) async throws -> [CatalogEntry]
}

extension CatalogSource {
    /// The history key of an entry: a stable one per server and item, so a
    /// new address for the server keeps its history.
    func historyKey(_ e: CatalogEntry) -> String { ServerPlayback.historyKey(kind: server.kind, server: server.id, item: e.id) }
}

enum ServerError: LocalizedError, Equatable {
    case badAddress, unauthorized, notSignedIn, http(Int), parse

    var errorDescription: String? {
        switch self {
        case .badAddress: return "Invalid server address."
        case .unauthorized: return "The server refused the login."
        case .notSignedIn: return "Not signed in. Edit the server to sign in again."
        case .http(let c): return "Server returned HTTP \(c)."
        case .parse: return "Could not read the server's answer."
        }
    }

    /// Said plainly, as the WebDAV browser does.
    static func message(_ error: Error, server: String) -> (text: String, offline: Bool) {
        let codes: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed]
        if let u = error as? URLError, codes.contains(u.code) { return ("You're offline, or \(server) can't be reached right now.", true) }
        if let s = error as? SMBError, s.isOffline { return ("\(server) can't be reached right now. \(s.localizedDescription)", true) }
        return (error.localizedDescription, false)
    }
}

enum ServerHTTP {
    /// One session for every Jellyfin and Plex server: connections are kept
    /// from one listing to the next.
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.httpMaximumConnectionsPerHost = 4
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    /// The body of a 2xx answer. Logs nothing: the request carries a token.
    static func data(_ request: URLRequest) async throws -> Data {
        let (data, resp) = try await session.data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw ServerError.parse }
        if http.statusCode == 401 || http.statusCode == 403 { throw ServerError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw ServerError.http(http.statusCode) }
        return data
    }

    /// `base` with `path` after its own path (a server behind a proxy at
    /// /jellyfin keeps it). `path` is already in URL form.
    static func endpoint(_ base: URL, _ path: String, _ query: [URLQueryItem] = []) -> URL? {
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var basePath = c.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        c.percentEncodedPath = basePath + (path.hasPrefix("/") ? path : "/" + path)
        c.queryItems = query.isEmpty ? nil : query
        return c.url
    }

    /// One path segment from a server's id, so an odd id can't step out of the path.
    static func segment(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#;"))) ?? s
    }
}

/// Titles for server entries. Jellyfin and Plex name things cleanly when
/// they matched them; a file they didn't match is named after the file
/// ("Dune.Part.Two.2024.2160p.WEB-DL"), which is cleaned like a WebDAV file.
enum CatalogTitles {
    /// A file's release name rather than a title.
    static func looksLikeRelease(_ s: String) -> Bool {
        if TitleParser.parse(s).resolution != nil { return true }
        return !s.contains(" ") && (s.contains(".") || s.contains("_"))
    }

    static func cleanName(_ s: String) -> String { looksLikeRelease(s) ? TitleParser.clean(s) : s }

    /// "Dune: Part Two (2024)".
    static func film(_ e: CatalogEntry) -> String {
        if looksLikeRelease(e.name) { return TitleParser.clean(e.name) }
        if let y = e.year, !e.name.contains("(\(y))") { return "\(e.name) (\(y))" }
        return e.name
    }

    /// "S1 · E5", "E12", "Special"; nil for anything but an episode.
    static func tag(_ e: CatalogEntry) -> String? {
        guard e.kind == .episode else { return nil }
        if e.season == 0 { return e.episode.map { "Special \($0)" } ?? "Special" }
        guard let ep = e.episode else { return nil }
        return e.season.map { "S\($0) · E\(ep)" } ?? "E\(ep)"
    }

    /// What a row says (an episode's tag is drawn apart, in bold).
    static func rowTitle(_ e: CatalogEntry) -> String {
        switch e.kind {
        case .movie: return film(e)
        case .episode, .video, .audio: return cleanName(e.name)
        default: return e.name
        }
    }

    /// The title in the player and in history, as WebDAV files have it:
    /// "Frieren · S01E05", "Dune (2021)".
    static func playerTitle(_ e: CatalogEntry) -> String {
        switch e.kind {
        case .movie:
            return film(e)
        case .episode:
            guard let show = e.seriesName, !show.isEmpty else { return cleanName(e.name) }
            guard let ep = e.episode else { return "\(show) · \(cleanName(e.name))" }
            if let s = e.season { return show + String(format: " · S%02dE%02d", s, ep) }
            return show + String(format: " · E%02d", ep)
        default:
            return cleanName(e.fileName ?? e.name)
        }
    }

    /// Under the title in the player (Now Playing): an episode's name.
    static func playerSubtitle(_ e: CatalogEntry) -> String? {
        e.kind == .episode && e.seriesName != nil ? cleanName(e.name) : nil
    }

    /// "1 h 52 min", "24 min".
    static func length(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }

    /// The year, how many seasons or episodes, the length.
    static func details(_ e: CatalogEntry) -> [String] {
        var out: [String] = []
        switch e.kind {
        case .series:
            if let y = e.year { out.append(String(y)) }
            if let n = e.childCount { out.append(n == 1 ? "1 season" : "\(n) seasons") }
        case .season:
            if let n = e.childCount { out.append(n == 1 ? "1 episode" : "\(n) episodes") }
        case .movie, .episode, .video, .audio:
            if let d = e.duration, d >= 60 { out.append(length(d)) }
        case .library, .folder:
            if let n = e.childCount { out.append(n == 1 ? "1 item" : "\(n) items") }
        }
        return out
    }
}

/// The browser's order, as the WebDAV browser's (DAVOrder): what can be
/// opened first; Name is the episode order for episodes and seasons, else
/// the shown title (Finder's compare: "Part 2" before "Part 10");
/// Recently Added by the server's date, missing ones last; Size for files.
enum CatalogOrder {
    static func sorted(_ list: [CatalogEntry], by sort: LibrarySort, ascending: Bool) -> [CatalogEntry] {
        let titles = Dictionary(list.map { ($0.id, CatalogTitles.rowTitle($0)) }, uniquingKeysWith: { a, _ in a })
        func name(_ e: CatalogEntry) -> String { titles[e.id] ?? e.name }
        func byName(_ a: CatalogEntry, _ b: CatalogEntry) -> Bool {
            if a.kind == b.kind, a.kind == .episode || a.kind == .season {
                let x = (a.season ?? Int.max, a.episode ?? Int.max), y = (b.season ?? Int.max, b.episode ?? Int.max)
                if x != y { return x < y }
            }
            return name(a).localizedStandardCompare(name(b)) == .orderedAscending
        }
        func compare<T: Comparable>(_ x: T?, _ y: T?, _ a: CatalogEntry, _ b: CatalogEntry) -> Bool {
            switch (x, y) {
            case let (x?, y?) where x != y: return ascending ? x < y : x > y
            case (.some, .none): return true
            case (.none, .some): return false
            default: return byName(a, b)
            }
        }
        return list.sorted { a, b in
            if a.isPlayable != b.isPlayable { return !a.isPlayable }
            switch sort {
            case .name:
                if byName(a, b) { return ascending }
                if byName(b, a) { return !ascending }
                return false
            case .recent:
                return compare(a.added, b.added, a, b)
            case .size:
                if !a.isPlayable { return byName(a, b) }
                return compare(a.size, b.size, a, b)
            }
        }
    }
}

/// True for the first caller only: a continuation is resumed once, by the
/// answer or by the deadline, whichever comes first.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
