import Foundation

/// `-labDAV` (CI UI tests): a WebDAV server "Lab DAV" whose folder listing is
/// a canned 207 Multi-Status answer, parsed by the real PropfindParser. Folders
/// with and without dates, episodes 1, 2 and 10 (numeric order), files with
/// only `getlastmodified` and with `creationdate` too, a subtitle and a
/// non-media file.
enum LabDAV {
    static var on: Bool { CommandLine.arguments.contains("-labDAV") }
    static let base = "https://dav.lab.invalid/"

    /// `-labDAVServer=<address>`: a real WebDAV server for the simulator lab
    /// (a local one that serves files, with a folder per torrent as on a
    /// debrid service), added as "Lab Server" (1.23.2).
    @MainActor static func seedServer() {
        guard let arg = CommandLine.arguments.first(where: { $0.hasPrefix("-labDAVServer=") }) else { return }
        let base = String(arg.dropFirst("-labDAVServer=".count))
        if !ServerStore.shared.servers.contains(where: { $0.baseURL == base }) {
            ServerStore.shared.upsert(WebDAVServer(name: "Lab Server", baseURL: base, username: ""))
            dlog("lab", "WebDAV server added: \(base)")
        }
        // `-labPlayDAV=<path on it>`: plays that file as Continue Watching
        // would (loading-time measurements).
        guard let play = CommandLine.arguments.first(where: { $0.hasPrefix("-labPlayDAV=") }),
              let server = ServerStore.shared.servers.first(where: { $0.baseURL == base }),
              let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + String(play.dropFirst("-labPlayDAV=".count))) else { return }
        // No settings written: pass "-resumePlayback NO" for a fresh open
        // (the launch's argument domain, gone at the next launch).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let item = WebDAVClient(server: server).mediaItem(for: DAVItem(url: url, name: url.lastPathComponent, isDirectory: false, size: nil, modified: nil, contentType: nil), cleanTitles: true)
            dlog("lab", "playing \(url.lastPathComponent) from the lab server")
            ContinueQueue.play(item)
        }
    }

    @MainActor static func seed() {
        guard on, !ServerStore.shared.servers.contains(where: { $0.baseURL == base }) else { return }
        ServerStore.shared.upsert(WebDAVServer(name: "Lab DAV", baseURL: base, username: ""))
    }

    static func list(_ url: URL) throws -> [DAVItem] {
        let parser = PropfindParser(base: url)
        guard parser.parse(Data(xml.utf8)) else { throw WebDAVError.parse }
        let items = parser.items.filter { $0.url.path != "/" }
        WebDAVClient.logProperties(host: url.host ?? "?", items)
        return items
    }

    private static func entry(_ href: String, dir: Bool, size: Int64? = nil, modified: String? = nil, created: String? = nil) -> String {
        var props = dir ? "<d:resourcetype><d:collection/></d:resourcetype>" : "<d:resourcetype/>"
        if let size { props += "<d:getcontentlength>\(size)</d:getcontentlength>" }
        if let modified { props += "<d:getlastmodified>\(modified)</d:getlastmodified>" }
        if let created { props += "<d:creationdate>\(created)</d:creationdate>" }
        let missing = (size == nil && !dir ? "<d:getcontentlength/>" : "") + (modified == nil ? "<d:getlastmodified/>" : "")
        var out = "<d:response><d:href>\(href)</d:href><d:propstat><d:prop>\(props)</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>"
        if !missing.isEmpty { out += "<d:propstat><d:prop>\(missing)</d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>" }
        return out + "</d:response>"
    }

    private static let mb: Int64 = 1_048_576
    private static var xml: String {
        """
        <?xml version="1.0" encoding="utf-8"?><d:multistatus xmlns:d="DAV:">
        \(entry("/", dir: true, modified: "Mon, 01 Jan 2024 00:00:00 GMT"))
        \(entry("/Season%201/", dir: true, modified: "Mon, 06 Jan 2025 10:00:00 GMT"))
        \(entry("/Extras/", dir: true))
        \(entry("/Another%20Show/", dir: true, modified: "Wed, 01 Oct 2025 08:00:00 GMT"))
        \(entry("/Lab%20Show%20-%20Episode%2010.mkv", dir: false, size: 700 * mb, modified: "Mon, 10 Mar 2025 09:00:00 GMT", created: "2025-03-10T09:00:00Z"))
        \(entry("/Lab%20Show%20-%20Episode%202.mkv", dir: false, size: 650 * mb, modified: "Sun, 02 Mar 2025 09:00:00 GMT", created: "2025-03-02T09:00:00Z"))
        \(entry("/Lab%20Show%20-%20Episode%201.mkv", dir: false, size: 900 * mb, modified: "Sat, 01 Mar 2025 09:00:00 GMT"))
        \(entry("/Lab%20Show%20-%20Episode%201.en.srt", dir: false, size: 30_000, modified: "Sat, 01 Mar 2025 09:05:00 GMT"))
        \(entry("/notes.txt", dir: false, size: 1_000))
        </d:multistatus>
        """
    }
}
