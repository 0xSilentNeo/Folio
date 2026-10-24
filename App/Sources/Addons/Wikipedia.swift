import Foundation

/// Finds the Wikipedia article for a title. One small JSON request, cached on
/// disk; falls back to a search link so the button always goes somewhere.
enum Wikipedia {
    private static let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("wikipedia.json")
    private static let lock = NSLock()
    private static var table: [String: String] = {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))) ?? [:]
    }()

    static func searchURL(name: String, year: String?, type: String) -> URL {
        let q = [name, year ?? "", type == "series" ? "TV series" : "film"].filter { !$0.isEmpty }.joined(separator: " ")
        var c = URLComponents(string: "https://en.wikipedia.org/w/index.php")!
        c.queryItems = [URLQueryItem(name: "search", value: q)]
        return c.url!
    }

    /// The article URL, resolved through the search API (best match), or nil.
    static func article(name: String, year: String?, type: String) async -> URL? {
        let key = [name.lowercased(), year ?? "", type].joined(separator: "|")
        lock.lock(); let hit = table[key]; lock.unlock()
        if let hit { return URL(string: hit) }
        var c = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        let q = [name, year ?? "", type == "series" ? "television series" : "film"].filter { !$0.isEmpty }.joined(separator: " ")
        c.queryItems = [URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "list", value: "search"),
                        URLQueryItem(name: "srsearch", value: q), URLQueryItem(name: "srlimit", value: "3"),
                        URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "utf8", value: "1")]
        var req = URLRequest(url: c.url!); req.timeoutInterval = 8
        req.setValue("GlassPlayer/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        guard let r = try? await URLSession.shared.data(for: req),
              let root = try? JSONSerialization.jsonObject(with: r.0) as? [String: Any],
              let hits = (root["query"] as? [String: Any])?["search"] as? [[String: Any]] else { return nil }
        let norm = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let want = norm(name)
        // Prefer a hit whose title starts with the name (not a "List of…" or an actor page).
        let best = hits.first { t in
            guard let title = t["title"] as? String else { return false }
            let n = norm(title)
            return n.hasPrefix(want) || want.hasPrefix(n)
        } ?? hits.first
        guard let title = best?["title"] as? String,
              let url = URL(string: "https://en.wikipedia.org/wiki/" + (title.replacingOccurrences(of: " ", with: "_")
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title)) else { return nil }
        lock.lock(); table[key] = url.absoluteString; let snapshot = table; lock.unlock()
        if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: file, options: .atomic) }
        return url
    }
}
