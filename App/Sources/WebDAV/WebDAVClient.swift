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
    let contentType: String?

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

final class WebDAVClient {
    let server: WebDAVServer
    private let session: URLSession

    init(server: WebDAVServer) {
        self.server = server
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: c)
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
        <d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getcontenttype/></d:prop></d:propfind>
        """.data(using: .utf8)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw WebDAVError.parse }
        if http.statusCode == 401 || http.statusCode == 403 { throw WebDAVError.unauthorized }
        guard (200..<300).contains(http.statusCode) || http.statusCode == 207 else { throw WebDAVError.http(http.statusCode) }

        let parser = PropfindParser(base: url)
        guard parser.parse(data) else { throw WebDAVError.parse }
        let selfPath = url.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return parser.items.filter { item in
            item.url.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != selfPath
        }
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
    private var contentType = ""
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
            href = ""; displayName = ""; isCollection = false; length = ""; modified = ""; contentType = ""
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
        case "getcontenttype": if propstatOK { contentType = value }
        case "status": if value.contains(" 404") { propstatOK = false }
        case "response":
            inResponse = false
            guard !href.isEmpty, let url = resolve(href) else { break }
            let fallbackName = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            let name = displayName.isEmpty ? fallbackName : displayName
            let isDir = isCollection || href.hasSuffix("/") && length.isEmpty
            items.append(DAVItem(url: url, name: name, isDirectory: isDir,
                                 size: Int64(length), modified: Self.dateFormatter.date(from: modified),
                                 contentType: contentType.isEmpty ? nil : contentType))
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
