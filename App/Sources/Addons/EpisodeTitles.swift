import Foundation

/// English episode titles from TVmaze (free, no key; CC BY-SA, credited in
/// Settings). IMDb often has only the original-language title for anime
/// episodes ("Aku to wa nanika…" instead of "What is evil? Whatever springs
/// from weakness."). TVmaze API docs: look a show up by IMDb id
/// (`/lookup/shows?imdb=` answers with a redirect to the show), else by name;
/// episodes from `/shows/:id/episodes`; at least 20 calls per 10 s allowed.
enum EpisodeTitles {
    /// Settings → General → Episode titles: "english" (default) or "original".
    static var wantEnglish: Bool { language != "original" }
    static var language: String { UserDefaults.standard.string(forKey: SettingsKey.episodeTitleLanguage) ?? "english" }

    private struct Ep: Codable { let season: Int?; let number: Int?; let name: String? }
    private struct Cached: Codable { let date: Date; let showID: Int?; let titles: [String: String] }

    private static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("tvmaze", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 8
        return URLSession(configuration: c)
    }()

    /// "season:episode" → English title, for an IMDb series. Empty when TVmaze
    /// doesn't know the show (cached for a day so it isn't asked again). When
    /// TVmaze can't be reached nothing is cached, so it's asked again next time.
    static func titles(imdbID: String, name: String?, year: String?) async -> [String: String] {
        let file = dir.appendingPathComponent(imdbID + ".json")
        if let d = try? Data(contentsOf: file), let c = try? JSONDecoder().decode(Cached.self, from: d),
           Date().timeIntervalSince(c.date) < (c.titles.isEmpty ? 86400 : 7 * 86400) {
            return c.titles
        }
        var (showID, reached) = await lookup(imdbID: imdbID)
        if showID == nil, let name {
            let found = await search(name: name, year: year)
            showID = found.id
            reached = reached && found.reached
        }
        var titles: [String: String] = [:]
        if let showID, let url = URL(string: "https://api.tvmaze.com/shows/\(showID)/episodes") {
            if let r = await get(url) {
                if r.status == 200, let eps = try? JSONDecoder().decode([Ep].self, from: r.data) {
                    for e in eps {
                        guard let s = e.season, let n = e.number, let t = e.name?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { continue }
                        titles["\(s):\(n)"] = t
                    }
                }
            } else {
                reached = false
            }
        }
        dlog("tvmaze", "\(imdbID) \(name ?? ""): show \(showID.map(String.init) ?? "not found"), \(titles.count) English episode titles\(reached ? "" : " (TVmaze not reached)")")
        if !titles.isEmpty || reached,
           let d = try? JSONEncoder().encode(Cached(date: Date(), showID: showID, titles: titles)) { try? d.write(to: file, options: .atomic) }
        return titles
    }

    private struct Show: Decodable { let id: Int; let name: String?; let premiered: String? }
    private struct Hit: Decodable { let show: Show }

    /// A response, or nil when TVmaze couldn't be reached or was busy (5xx, 429).
    private static func get(_ url: URL) async -> (data: Data, status: Int)? {
        guard let (data, resp) = try? await session.data(from: url) else { return nil }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return status >= 500 || status == 429 ? nil : (data, status)
    }

    private static func lookup(imdbID: String) async -> (id: Int?, reached: Bool) {
        guard let url = URL(string: "https://api.tvmaze.com/lookup/shows?imdb=\(imdbID)") else { return (nil, true) }
        guard let r = await get(url) else { return (nil, false) }     // URLSession follows the 301 to the show
        guard r.status == 200, let show = try? JSONDecoder().decode(Show.self, from: r.data) else { return (nil, true) }
        return (show.id, true)
    }

    /// By name when TVmaze has no IMDb id for the show (Classroom of the Elite):
    /// the first result whose title matches and whose premiere year is within
    /// a year of IMDb's.
    private static func search(name: String, year: String?) async -> (id: Int?, reached: Bool) {
        var c = URLComponents(string: "https://api.tvmaze.com/search/shows")!
        c.queryItems = [URLQueryItem(name: "q", value: name)]
        guard let url = c.url else { return (nil, true) }
        guard let r = await get(url) else { return (nil, false) }
        guard r.status == 200, let hits = try? JSONDecoder().decode([Hit].self, from: r.data) else { return (nil, true) }
        let norm = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let want = norm(name), y = year.flatMap { Int($0.prefix(4)) }
        let id = hits.first { h in
            guard norm(h.show.name ?? "") == want else { return false }
            guard let y, let p = h.show.premiered.flatMap({ Int($0.prefix(4)) }) else { return true }
            return abs(p - y) <= 1
        }?.show.id
        return (id, true)
    }

    /// Replaces IMDb episode titles with English ones where known (the IMDb
    /// title is kept as `originalTitle`). No-op when the setting is "original".
    static func apply(_ eps: [MetaVideo], imdbID: String, name: String?, year: String?) async -> [MetaVideo] {
        guard wantEnglish, imdbID.hasPrefix("tt"), !eps.isEmpty else { return eps }
        let map = await titles(imdbID: imdbID, name: name, year: year)
        guard !map.isEmpty else { return eps }
        return eps.map { v in
            guard let s = v.season, let e = v.episode, let en = map["\(s):\(e)"], en != v.title else { return v }
            var out = v
            if out.originalTitle == nil { out.originalTitle = v.title }
            out.title = en
            return out
        }
    }
}
