import Foundation

struct WebDAVServer: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var baseURL: String
    var username: String
    var rootPath: String = "/"

    var password: String? {
        get { Keychain.get("webdav-\(id.uuidString)") }
        nonmutating set { Keychain.set(newValue, for: "webdav-\(id.uuidString)") }
    }

    var authHeader: String? {
        guard !username.isEmpty else { return nil }
        let token = "\(username):\(password ?? "")".data(using: .utf8)!.base64EncodedString()
        return "Basic \(token)"
    }

    var base: URL? {
        var s = baseURL.trimmingCharacters(in: .whitespaces)
        if !s.contains("://") { s = "https://" + s }
        return URL(string: s)
    }

    static let presets: [(name: String, url: String)] = [
        ("Real-Debrid", "https://dav.real-debrid.com/"),
        ("TorBox", "https://webdav.torbox.app/"),
        ("Premiumize", "https://webdav.premiumize.me/"),
    ]
}

struct DAVItem: Identifiable, Hashable {
    var id: String { url.absoluteString }
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64?
    let modified: Date?
    /// `creationdate` (RFC 4918 §15.1), when the server sends it.
    var created: Date? = nil
    let contentType: String?
    /// `getetag` (RFC 4918 §15.6), when the server sends it: changes when the
    /// item changes, so the library index can skip folders that didn't.
    var etag: String? = nil

    /// When the item came to the server, for "Recently Added": its creation
    /// date when the server sends one, else its last change (`getlastmodified`,
    /// RFC 4918 §15.7, which every server here sends; a debrid service's
    /// folder or file doesn't change after it's added). Nil when neither came.
    var added: Date? { created ?? modified }

    var isMedia: Bool { !isDirectory && TitleParser.isMedia(name) }
    var isSubtitle: Bool { !isDirectory && TitleParser.isSubtitle(name) }
}

enum WebDAVError: LocalizedError {
    case badURL, unauthorized, http(Int), parse
    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid server address."
        case .unauthorized: return "Wrong username or password."
        case .http(let c): return "Server returned HTTP \(c)."
        case .parse: return "Could not read the server's folder listing."
        }
    }
}

/// Immutable (a server and its shared session): safe to use from any task.
final class WebDAVClient: @unchecked Sendable {
    let server: WebDAVServer
    private let session: URLSession

    init(server: WebDAVServer) {
        self.server = server
        session = Self.session(for: server.id)
    }

    /// One session per server, shared by every client: its connections (and
    /// their TLS handshakes) are reused from one folder to the next. Until
    /// 1.19.0 each client made its own session, and the browser made a new
    /// client each time it listed a folder.
    private static let sessionsLock = NSLock()
    nonisolated(unsafe) private static var sessions: [UUID: URLSession] = [:]
    private static func session(for id: UUID) -> URLSession {
        sessionsLock.lock(); defer { sessionsLock.unlock() }
        if let s = sessions[id] { return s }
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.httpMaximumConnectionsPerHost = 4
        let s = URLSession(configuration: c)
        sessions[id] = s
        return s
    }

    func url(forPath path: String) -> URL? {
        guard let base = server.base else { return nil }
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        var p = path.hasPrefix("/") ? path : "/" + path
        let basePath = comps?.path ?? ""
        if !basePath.isEmpty && basePath != "/" && !p.hasPrefix(basePath) {
            p = (basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath) + p
        }
        comps?.path = p
        return comps?.url
    }

    func list(_ url: URL) async throws -> [DAVItem] {
        if LabDAV.on { return try LabDAV.list(url) }
        var req = URLRequest(url: url)
        req.httpMethod = "PROPFIND"
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let auth = server.authHeader { req.setValue(auth, forHTTPHeaderField: "Authorization") }
        req.httpBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:creationdate/><d:getcontenttype/><d:getetag/></d:prop></d:propfind>
        """.data(using: .utf8)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw WebDAVError.parse }
        if http.statusCode == 401 || http.statusCode == 403 { throw WebDAVError.unauthorized }
        guard (200..<300).contains(http.statusCode) || http.statusCode == 207 else { throw WebDAVError.http(http.statusCode) }

        Self.logRawAnswer(host: url.host ?? "?", data)
        let parser = PropfindParser(base: url)
        guard parser.parse(data) else { throw WebDAVError.parse }
        let selfPath = url.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let items = parser.items.filter { item in
            item.url.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != selfPath
        }
        Self.logProperties(host: url.host ?? "?", items)
        return items
    }

    /// Which of the asked-for properties the server actually sends, once per
    /// server per launch ("Recently Added" uses creationdate, else
    /// getlastmodified). Folders usually have no getcontentlength.
    private static let loggedLock = NSLock()
    nonisolated(unsafe) private static var logged: Set<String> = []
    static func logProperties(host: String, _ items: [DAVItem]) {
        loggedLock.lock()
        let first = logged.insert(host).inserted
        loggedLock.unlock()
        guard first, !items.isEmpty else { return }
        let dirs = items.filter(\.isDirectory), files = items.filter { !$0.isDirectory }
        func count(_ list: [DAVItem], _ has: (DAVItem) -> Bool) -> String { "\(list.filter(has).count)/\(list.count)" }
        dlog("webdav", "properties from \(host): getlastmodified folders \(count(dirs) { $0.modified != nil }), files \(count(files) { $0.modified != nil }); "
             + "creationdate folders \(count(dirs) { $0.created != nil }), files \(count(files) { $0.created != nil }); "
             + "getetag folders \(count(dirs) { $0.etag != nil }), files \(count(files) { $0.etag != nil }); "
             + "getcontentlength folders \(count(dirs) { $0.size != nil }), files \(count(files) { $0.size != nil })")
    }

    /// Trace (library and images): the first three entries of the first
    /// folder listing per server per launch, as the server sent them, so a
    /// report shows which properties it sends for folders and how.
    nonisolated(unsafe) private static var rawLogged: Set<String> = []
    static func logRawAnswer(host: String, _ data: Data) {
        guard LibTrace.on else { return }
        loggedLock.lock()
        let first = rawLogged.insert(host).inserted
        loggedLock.unlock()
        guard first, let text = String(data: data, encoding: .utf8) else { return }
        // Up to the end of the fourth entry: the folder itself and three of its items.
        let ns = text as NSString
        let ends = (try? NSRegularExpression(pattern: "</[A-Za-z]*:?response>", options: .caseInsensitive))?
            .matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? []
        let responses = ends.count >= 4 ? ns.substring(to: NSMaxRange(ends[3].range)) : text
        LibTrace.index.log("raw PROPFIND answer from \(host) (first entries):\n\(responses.prefix(4000))")
    }

    /// Playable URL + headers for mpv.
    func mediaItem(for item: DAVItem, cleanTitles: Bool) -> MediaItem {
        var m = MediaItem(url: item.url.absoluteString,
                          title: cleanTitles ? TitleParser.clean(item.name) : (item.name as NSString).deletingPathExtension,
                          subtitle: item.url.deletingLastPathComponent().lastPathComponent.removingPercentEncoding,
                          source: .webdav(serverID: server.id))
        if let auth = server.authHeader { m.headers["Authorization"] = auth }
        let parsed = TitleParser.parse(item.name)
        if parsed.episode != nil {
            m.anime = AnimeHint(title: parsed.title, episode: parsed.episode)
        }
        return m
    }
}

/// Parses a 207 Multi-Status PROPFIND response.
final class PropfindParser: NSObject, XMLParserDelegate {
    private let base: URL
    private(set) var items: [DAVItem] = []

    private var href = ""
    private var displayName = ""
    private var isCollection = false
    private var length = ""
    private var modified = ""
    private var created = ""
    private var contentType = ""
    private var etag = ""
    private var text = ""
    private var inResponse = false
    private var statusOK = true
    private var propstatOK = true

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    init(base: URL) { self.base = base }

    /// creationdate is an RFC 3339 date-time ("2025-03-10T09:00:00Z"),
    /// sometimes with fractions of a second.
    private static func isoDate(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    func parse(_ data: Data) -> Bool {
        let p = XMLParser(data: data)
        p.shouldProcessNamespaces = true
        p.delegate = self
        return p.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch elementName.lowercased() {
        case "response":
            inResponse = true
            href = ""; displayName = ""; isCollection = false; length = ""; modified = ""; created = ""; contentType = ""; etag = ""
        case "collection":
            if inResponse { isCollection = true }
        case "propstat":
            propstatOK = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName.lowercased() {
        case "href": href = value
        case "displayname": if propstatOK { displayName = value }
        case "getcontentlength": if propstatOK { length = value }
        case "getlastmodified": if propstatOK { modified = value }
        case "creationdate": if propstatOK { created = value }
        case "getcontenttype": if propstatOK { contentType = value }
        case "getetag": if propstatOK { etag = value }
        case "status": if value.contains(" 404") { propstatOK = false }
        case "response":
            inResponse = false
            guard !href.isEmpty, let url = resolve(href) else { break }
            let fallbackName = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            let name = displayName.isEmpty ? fallbackName : displayName
            let isDir = isCollection || href.hasSuffix("/") && length.isEmpty
            var item = DAVItem(url: url, name: name, isDirectory: isDir,
                               size: Int64(length), modified: Self.dateFormatter.date(from: modified),
                               contentType: contentType.isEmpty ? nil : contentType)
            item.created = Self.isoDate(created)
            item.etag = etag.isEmpty ? nil : etag
            items.append(item)
        default: break
        }
        text = ""
    }

    private func resolve(_ href: String) -> URL? {
        if let abs = URL(string: href), abs.scheme != nil { return abs }
        // Re-encode in case the server sent raw characters.
        let encoded = href.removingPercentEncoding.flatMap {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        } ?? href
        return URL(string: encoded, relativeTo: base)?.absoluteURL
    }
}
