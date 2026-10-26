import Foundation

/// Optional TMDB source for Discover. Enabled when the
/// user adds their own API key in Settings → Discover. Items keep their
/// TMDB id and are resolved to an IMDb id when opened, so IMDb details
/// and stream addons keep working.
enum TMDB {
    static var apiKey: String {
        get { UserDefaults.standard.string(forKey: "tmdbApiKey")?.trimmingCharacters(in: .whitespaces) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "tmdbApiKey") }
    }
    static var enabled: Bool { !apiKey.isEmpty }
    /// True when the last request failed (bad key, offline).
    static var lastError = false
    static let image = "https://image.tmdb.org/t/p/"

    private static var genreCache: [String: [String: Int]] = [:]
    private static let lock = NSLock()

    private static func get(_ path: String, _ query: [String: String] = [:]) async -> [String: Any]? {
        var comps = URLComponents(string: "https://api.themoviedb.org/3" + path)!
        var items = [URLQueryItem(name: "api_key", value: apiKey), URLQueryItem(name: "language", value: Locale.preferredLanguages.first ?? "en-US")]
        items += query.map { URLQueryItem(name: $0.key, value: $0.value) }
        comps.queryItems = items
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 15
        guard let r = try? await URLSession.shared.data(for: req),
              (r.1 as? HTTPURLResponse)?.statusCode == 200 else {
            dlog("tmdb/error", "request failed: \(path)")
            lastError = true
            return nil
        }
        lastError = false
        return try? JSONSerialization.jsonObject(with: r.0) as? [String: Any]
    }

    private static func genreID(_ name: String, type: String) async -> Int? {
        let t = type == "series" ? "tv" : "movie"
        lock.lock(); let cached = genreCache[t]; lock.unlock()
        var map = cached
        if map == nil, let obj = await get("/genre/\(t)/list"), let list = obj["genres"] as? [[String: Any]] {
            var m: [String: Int] = [:]
            for g in list { if let n = g["name"] as? String, let id = g["id"] as? Int { m[n.lowercased()] = id } }
            map = m
            lock.lock(); genreCache[t] = m; lock.unlock()
        }
        let key = name.lowercased()
        let aliases = ["sci-fi": "science fiction", "biography": "history", "sport": "action", "anime": "animation", "musical": "music"]
        return map?[key] ?? map?[aliases[key] ?? ""] ?? map?[key.replacingOccurrences(of: "sci-fi", with: "sci-fi & fantasy")]
    }

    static func browse(sort: BrowseModel.Sort, type: String, genre: String?, year: String, page: Int) async -> [MetaItem] {
        let t = type == "series" ? "tv" : "movie"
        var obj: [String: Any]?
        var q = ["page": String(page), "include_adult": "false"]
        switch sort {
        case .trending where genre == nil:
            obj = await get("/trending/\(t)/week", q)
        case .topRated where genre == nil:
            obj = await get("/\(t)/top_rated", q)
        default:
            if let genre, let gid = await genreID(genre, type: type) { q["with_genres"] = String(gid) }
            if genre?.lowercased() == "anime" { q["with_original_language"] = "ja" }
            switch sort {
            case .new:
                q[t == "tv" ? "first_air_date_year" : "primary_release_year"] = year
                q["sort_by"] = "popularity.desc"
            case .topRated:
                q["sort_by"] = "vote_average.desc"; q["vote_count.gte"] = "300"
            case .trending:
                q["sort_by"] = "popularity.desc"
            }
            obj = await get("/discover/\(t)", q)
        }
        guard let results = obj?["results"] as? [[String: Any]] else { return [] }
        return results.enumerated().compactMap { i, r in
            guard let id = r["id"] as? Int else { return nil }
            let name = (r["title"] as? String) ?? (r["name"] as? String) ?? "–"
            let date = (r["release_date"] as? String) ?? (r["first_air_date"] as? String) ?? ""
            let rating = (r["vote_average"] as? Double).map { String(format: "%.1f", $0) }
            var m = MetaItem(id: "tmdb:\(id)", type: type, name: name,
                             poster: (r["poster_path"] as? String).map { image + "w342" + $0 },
                             description: r["overview"] as? String, releaseInfo: String(date.prefix(4)), imdbRating: rating, genres: nil,
                             rank: sort == .topRated && genre == nil ? (page - 1) * 20 + i + 1 : nil)
            m.background = (r["backdrop_path"] as? String).map { image + "w780" + $0 }
            return m
        }
    }

    /// IMDb id for a tmdb:ID item (needed for details and streams).
    static func imdbID(for meta: MetaItem) async -> String? {
        guard meta.id.hasPrefix("tmdb:"), let num = meta.id.split(separator: ":").last else { return nil }
        let t = meta.type == "series" ? "tv" : "movie"
        guard let obj = await get("/\(t)/\(num)/external_ids"), let imdb = obj["imdb_id"] as? String, imdb.hasPrefix("tt") else { return nil }
        return imdb
    }
}
