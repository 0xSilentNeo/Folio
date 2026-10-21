import Foundation

/// IMDb's own charts (Top 250 movies / TV) read from the structured data
/// embedded in the chart page, so "Top Rated" matches what IMDb shows.
enum IMDbCharts {
    private static var cache: [String: (Date, [MetaItem])] = [:]
    private static let lock = NSLock()

    static func top(type: String) async -> [MetaItem] {
        let key = type
        lock.lock()
        if let hit = cache[key], Date().timeIntervalSince(hit.0) < 12 * 3600 { lock.unlock(); return hit.1 }
        lock.unlock()
        let path = type == "series" ? "/chart/toptv/" : "/chart/top/"
        guard let url = URL(string: "https://www.imdb.com" + path) else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        guard let r = try? await URLSession.shared.data(for: req), let html = String(data: r.0, encoding: .utf8) else {
            dlog("imdb/error", "chart fetch failed for \(type)")
            return []
        }
        let items = parse(html: html, type: type)
        dlog("imdb", "chart \(type): \(items.count) items")
        if !items.isEmpty { lock.lock(); cache[key] = (Date(), items); lock.unlock() }
        return items
    }

    /// Finds the JSON-LD ItemList and converts its entries.
    static func parse(html: String, type: String) -> [MetaItem] {
        guard let re = try? NSRegularExpression(pattern: #"<script[^>]*type="application/ld\+json"[^>]*>(.*?)</script>"#, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let json = ns.substring(with: m.range(at: 1))
            guard let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = obj["itemListElement"] as? [[String: Any]], !list.isEmpty else { continue }
            var out: [MetaItem] = []
            for (i, el) in list.enumerated() {
                let item = (el["item"] as? [String: Any]) ?? el
                guard let urlStr = item["url"] as? String,
                      let id = urlStr.split(separator: "/").first(where: { $0.hasPrefix("tt") }).map(String.init) else { continue }
                let name = unescape((item["name"] as? String) ?? (item["alternateName"] as? String) ?? id)
                let rating = ((item["aggregateRating"] as? [String: Any])?["ratingValue"]).map { "\($0)" }
                let genre = item["genre"] as? String
                let genres = genre.map { [$0] } ?? (item["genre"] as? [String])
                var poster = item["image"] as? String
                // Ask IMDb's image CDN for a poster-sized rendition.
                if let p = poster, let dot = p.range(of: "._V1_") { poster = String(p[..<dot.lowerBound]) + "._V1_QL75_UX300_.jpg" }
                out.append(MetaItem(id: id, type: type, name: name, poster: poster, description: unescape(item["description"] as? String),
                                    releaseInfo: nil, imdbRating: rating, genres: genres, rank: i + 1))
            }
            if !out.isEmpty { return out }
        }
        return []
    }

    private static func unescape(_ s: String?) -> String {
        guard var s else { return "" }
        for (a, b) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">")] { s = s.replacingOccurrences(of: a, with: b) }
        return s
    }
}
