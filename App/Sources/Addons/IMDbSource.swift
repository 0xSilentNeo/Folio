import Foundation
import QuartzCore
import CryptoKit

/// Built-in IMDb metadata source: charts, filtered browsing, search, title
/// details and episode lists, read from IMDb's public pages (the JSON that
/// the site itself embeds: JSON-LD and the Next.js page data) and its
/// suggestion API. No key needed. Everything is cached on disk.
///
/// Two parsers run on every page so a layout change on one side does not
/// blank the app: `jsonLD(_:)` reads `application/ld+json` blocks and
/// `nextTitles(_:)` walks `__NEXT_DATA__` for anything that looks like a
/// title (an id starting with "tt" next to a title text).
enum IMDbSource {
    // MARK: - Configuration (Settings → Discover → IMDb)

    enum Key {
        static let language = "imdbLanguage"        // Accept-Language, e.g. "en-US"
        static let minVotes = "imdbMinVotes"        // Top Rated with a genre
        static let animeJapan = "imdbAnimeJapan"    // Anime = Animation from Japan
        static let trending = "imdbTrending"        // "popular" | "boxoffice"
        static let region = "imdbRegion"            // used for box office / release dates
    }
    static var language: String {
        let s = UserDefaults.standard.string(forKey: Key.language)?.trimmingCharacters(in: .whitespaces) ?? ""
        return s.isEmpty ? "en-US" : s
    }
    static var minVotes: Int { let v = UserDefaults.standard.integer(forKey: Key.minVotes); return v == 0 ? 25000 : v }
    static var animeJapanOnly: Bool { UserDefaults.standard.object(forKey: Key.animeJapan) as? Bool ?? true }

    static let genres = ["Action", "Adventure", "Animation", "Anime", "Biography", "Comedy", "Crime", "Documentary", "Drama", "Family", "Fantasy",
                         "Film-Noir", "History", "Horror", "Music", "Musical", "Mystery", "Romance", "Sci-Fi", "Sport", "Thriller", "War", "Western"]

    // MARK: - HTTP

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.httpCookieAcceptPolicy = .always
        c.httpCookieStorage = .shared
        c.httpAdditionalHeaders = [
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ]
        return URLSession(configuration: c)
    }()

    /// Page HTML. Plain request first (with WebKit's user agent and the WAF
    /// token cookie once we have one); when IMDb answers with its JavaScript
    /// challenge (HTTP 202) the page is loaded through the hidden web view.
    private static func html(_ path: String, _ query: [String: String] = [:]) async -> String? {
        var comps = URLComponents(string: "https://www.imdb.com" + path)!
        if !query.isEmpty { comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = comps.url else { return nil }
        await IMDbPageLoader.shared.ensureUserAgent()
        var req = URLRequest(url: url)
        req.setValue(language + ",en;q=0.8", forHTTPHeaderField: "Accept-Language")
        if let ua = await IMDbPageLoader.shared.userAgent { req.setValue(ua, forHTTPHeaderField: "User-Agent") }
        let t0 = CACurrentMediaTime()
        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, let s = String(data: data, encoding: .utf8), s.contains("__NEXT_DATA__") || s.contains("ld+json") {
                dlog("perf", String(format: "imdb %@ plain HTTP %.0f ms (%d KB)", path, (CACurrentMediaTime() - t0) * 1000, data.count / 1024))
                return s
            }
            dlog("imdb", "HTTP \(status) for \(path) (\(data.count) bytes) → web view")
        } catch {
            if error is CancellationError { return nil }
            dlog("imdb", "\(path): \(error.localizedDescription) → web view")
        }
        if Task.isCancelled { return nil }
        let r = await IMDbPageLoader.shared.load(url)
        dlog("perf", String(format: "imdb %@ via web view %.0f ms", path, (CACurrentMediaTime() - t0) * 1000))
        return r
    }

    /// Gets the WAF token at launch (one web-view load of a tiny page) so the
    /// first Discover request can be plain HTTP instead of a browser page load.
    static func warmUp() {
        Task.detached(priority: .utility) {
            let t0 = CACurrentMediaTime()
            _ = await html("/chart/moviemeter/")   // also fills the Trending cache
            dlog("perf", String(format: "imdb warm-up done in %.0f ms", (CACurrentMediaTime() - t0) * 1000))
        }
    }

    // MARK: - Cache

    private static var memory: [String: (Date, Data)] = [:]
    private static let lock = NSLock()
    private static var dir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("imdb", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static let cacheVersion = "v2|"   // bump when parsed shapes change
    private static func cacheFile(_ key: String) -> URL {
        let h = SHA256.hash(data: Data((cacheVersion + key).utf8)).compactMap { String(format: "%02x", $0) }.joined().prefix(32)
        return dir.appendingPathComponent(String(h) + ".json")
    }
    /// Any cached value, however old (for showing something at once while a fresh copy loads).
    static func cachedStale<T: Decodable>(_ key: String, as: T.Type) -> T? { cached(key, ttl: .greatestFiniteMagnitude, as: T.self) }

    private static func cached<T: Decodable>(_ key: String, ttl: TimeInterval, as: T.Type) -> T? {
        lock.lock(); let m = memory[key]; lock.unlock()
        if let m, Date().timeIntervalSince(m.0) < ttl, let v = try? JSONDecoder().decode(T.self, from: m.1) { return v }
        let f = cacheFile(key)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: f.path), let date = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(date) < ttl, let d = try? Data(contentsOf: f), let v = try? JSONDecoder().decode(T.self, from: d) else { return nil }
        lock.lock(); memory[key] = (date, d); lock.unlock()
        return v
    }
    private static func store<T: Encodable>(_ key: String, _ value: T) {
        guard let d = try? JSONEncoder().encode(value) else { return }
        lock.lock(); memory[key] = (Date(), d); lock.unlock()
        try? d.write(to: cacheFile(key), options: .atomic)
    }
    static func clearCache() {
        lock.lock(); memory = [:]; lock.unlock()
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Formatting

    /// IMDb ratings arrive as doubles like 8.8000000000000007; show one decimal.
    static func rating(_ v: Any?) -> String? {
        if let d = v as? Double { return String(format: "%.1f", d) }
        if let i = v as? Int { return String(format: "%.1f", Double(i)) }
        if let s = v as? String, let d = Double(s) { return String(format: "%.1f", d) }
        return nil
    }

    // MARK: - Images

    /// IMDb image URLs accept a size spec before the extension.
    static func sized(_ url: String?, width: Int) -> String? {
        guard let url else { return nil }
        guard let r = url.range(of: "._V1_", options: .backwards) else { return url }
        let ext = (url as NSString).pathExtension.isEmpty ? "jpg" : (url as NSString).pathExtension
        return String(url[..<r.lowerBound]) + "._V1_QL80_UX\(width)_." + ext
    }

    // MARK: - Charts & browsing

    enum Sort { case trending, topRated, new }

    /// Discover grid. Mirrors IMDb itself: Most Popular / Top 250 charts when
    /// no genre is chosen, otherwise IMDb advanced search with the same rules.
    /// `staleOnly`: return whatever the cache holds (any age) without a request,
    /// so the grid can show the last list at once while a fresh one loads.
    static func browse(sort: Sort, type: String, genre: String?, year: String, staleOnly: Bool = false) async -> [MetaItem] {
        let series = type == "series"
        if genre == nil {
            switch sort {
            case .trending: return await chart(series ? "/chart/tvmeter/" : "/chart/moviemeter/", type: type, staleOnly: staleOnly)
            case .topRated: return await chart(series ? "/chart/toptv/" : "/chart/top/", type: type, staleOnly: staleOnly)
            case .new: break
            }
        }
        var q: [String: String] = [
            "title_type": series ? "tv_series,tv_miniseries" : "feature,tv_movie",
            "count": "100",
        ]
        if let genre {
            if genre == "Anime" {
                q["genres"] = "animation"
                if animeJapanOnly { q["country_of_origin"] = "JP"; q["countries"] = "JP" }
            } else {
                q["genres"] = genre.lowercased()
            }
        }
        switch sort {
        case .trending:
            q["sort"] = "moviemeter,asc"
        case .topRated:
            q["sort"] = "user_rating,desc"
            q["num_votes"] = "\(minVotes),"
        case .new:
            q["release_date"] = "\(year)-01-01,\(year)-12-31"
            q["sort"] = "moviemeter,asc"
        }
        let key = "search|" + q.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&") + "|" + language
        if staleOnly { return cachedStale(key, as: [MetaItem].self) ?? [] }
        if let hit = cached(key, ttl: 3 * 3600, as: [MetaItem].self) { return hit }
        let t0 = CACurrentMediaTime()
        defer { dlog("perf", String(format: "imdb search %@ %@ in %.0f ms", type, genre ?? "-", (CACurrentMediaTime() - t0) * 1000)) }
        guard let page = await html("/search/title/", q) else { return [] }
        var items = nextTitles(page, type: type)
        if items.isEmpty { items = jsonLDList(page, type: type) }
        items = items.filter { $0.type == type }
        if sort == .topRated { for i in items.indices { items[i].rank = i + 1 } }
        dlog("imdb", "search \(q["sort"] ?? "") \(type) genre=\(genre ?? "-") → \(items.count)")
        if !items.isEmpty { store(key, items) }
        return items
    }

    static func chart(_ path: String, type: String, staleOnly: Bool = false) async -> [MetaItem] {
        let key = "chart|\(path)|\(language)"
        if staleOnly { return cachedStale(key, as: [MetaItem].self) ?? [] }
        if let hit = cached(key, ttl: 6 * 3600, as: [MetaItem].self) { return hit }
        let t0 = CACurrentMediaTime()
        defer { dlog("perf", String(format: "imdb chart %@ in %.0f ms", path, (CACurrentMediaTime() - t0) * 1000)) }
        guard let page = await html(path) else { return [] }
        var items = nextTitles(page, type: type)
        if items.isEmpty { items = jsonLDList(page, type: type) }
        for i in items.indices where items[i].rank == nil { items[i].rank = i + 1 }
        dlog("imdb", "chart \(path) → \(items.count)")
        if !items.isEmpty { store(key, items) }
        return items
    }

    // MARK: - Search (suggestion API)

    struct Suggestion: Decodable {
        struct Img: Decodable { var imageUrl: String? }
        var id: String
        var l: String?
        var q: String?
        var qid: String?
        var y: Int?
        var yr: String?
        var s: String?
        var i: Img?
    }
    private struct SuggestionResponse: Decodable { var d: [Suggestion]? }

    static func search(_ query: String) async -> [MetaItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let key = "suggest|\(q)"
        if let hit = cached(key, ttl: 86400, as: [MetaItem].self) { return hit }
        let path = q.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? q
        guard let url = URL(string: "https://v3.sg.media-imdb.com/suggestion/x/\(path).json") else { return [] }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let r = try? await session.data(for: req), let res = try? JSONDecoder().decode(SuggestionResponse.self, from: r.0) else {
            dlog("imdb/error", "suggestion failed for \(q)")
            return []
        }
        let items: [MetaItem] = (res.d ?? []).compactMap { s in
            guard s.id.hasPrefix("tt"), let name = s.l else { return nil }
            let type: String
            switch s.qid ?? "" {
            case "movie", "tvMovie", "video", "short": type = "movie"
            case "tvSeries", "tvMiniSeries": type = "series"
            default: return nil
            }
            var m = MetaItem(id: s.id, type: type, name: name, poster: sized(s.i?.imageUrl, width: 240),
                             description: s.s, releaseInfo: s.yr ?? s.y.map(String.init), imdbRating: nil, genres: nil)
            m.background = sized(s.i?.imageUrl, width: 780)
            return m
        }
        store(key, items)
        return items
    }

    // MARK: - Title details

    static func details(id: String, type hint: String) async -> MetaItem? {
        let key = "title2|\(id)|\(language)"
        if let hit = cached(key, ttl: 7 * 86400, as: MetaItem.self) { return hit }
        guard let page = await html("/title/\(id)/") else { return nil }
        var m: MetaItem?
        for obj in jsonLD(page) {
            let t = (obj["@type"] as? String) ?? ""
            guard ["Movie", "TVSeries", "TVMiniSeries", "TVEpisode", "TVMovie", "VideoObject", "CreativeWork"].contains(t) || obj["name"] != nil, obj["itemListElement"] == nil else { continue }
            let type = t.hasPrefix("TV") && t != "TVMovie" && t != "TVEpisode" ? "series" : (t == "TVEpisode" ? hint : "movie")
            let name = unescape((obj["name"] as? String) ?? (obj["alternateName"] as? String) ?? id)
            var item = MetaItem(id: id, type: type, name: name, poster: sized(obj["image"] as? String, width: 500),
                                description: unescape(obj["description"] as? String),
                                releaseInfo: (obj["datePublished"] as? String).map { String($0.prefix(4)) },
                                imdbRating: Self.rating((obj["aggregateRating"] as? [String: Any])?["ratingValue"]),
                                genres: (obj["genre"] as? [String]) ?? (obj["genre"] as? String).map { [$0] })
            item.runtime = (obj["duration"] as? String).flatMap(prettyDuration)
            if let tr = obj["trailer"] as? [String: Any], let thumb = tr["thumbnailUrl"] as? String { item.background = sized(thumb, width: 1280) }
            item.cast = ((obj["actor"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            item.director = ((obj["director"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            item.contentRating = obj["contentRating"] as? String
            m = item
            break
        }
        // Extra facts only the page data carries; its titleText is the title in
        // the user's language (JSON-LD may carry the original one).
        if let next = nextData(page) {
            let fromData = nextTitles(page, type: hint).first { $0.id == id }
            var m2 = m ?? fromData
            if m2 != nil {
                if let n = fromData?.name, !n.isEmpty { m2!.name = n }
                if m2!.releaseInfo == nil { m2!.releaseInfo = fromData?.releaseInfo }
                if m2!.runtime == nil { m2!.runtime = fromData?.runtime }
                walk(next) { d in
                    if m2!.originalName == nil, (d["id"] as? String) == id, let o = text(d["originalTitleText"]), o != m2!.name {
                        m2!.originalName = o
                    }
                    // Top cast with headshots: `cast { edges { node { name, characters } } }`.
                    if (m2!.credits ?? []).isEmpty, let cast = d["cast"] as? [String: Any], let edges = cast["edges"] as? [[String: Any]] {
                        let list = castMembers(edges.compactMap { $0["node"] as? [String: Any] })
                        if !list.isEmpty { m2!.credits = list }
                    }
                    if let c = d["countriesOfOrigin"] as? [String: Any], let list = c["countries"] as? [[String: Any]] {
                        m2!.countries = list.compactMap { $0["id"] as? String }
                        return false
                    }
                    if m2!.description == nil, let plot = d["plot"] as? [String: Any], let pt = plot["plotText"] as? [String: Any], let s = pt["plainText"] as? String {
                        m2!.description = s
                    }
                    if m2!.releaseInfo == nil, let ry = d["releaseYear"] as? [String: Any], let y = ry["year"] as? Int { m2!.releaseInfo = String(y) }
                    if m2!.background == nil, let img = d["primaryVideos"] as? [String: Any], let edges = img["edges"] as? [[String: Any]],
                       let node = edges.first?["node"] as? [String: Any], let thumb = (node["thumbnail"] as? [String: Any])?["url"] as? String {
                        m2!.background = sized(thumb, width: 1280)
                    }
                    return true
                }
                if (m2!.genres ?? []).contains(where: { $0.caseInsensitiveCompare("Animation") == .orderedSame }),
                   (m2!.countries ?? []).contains("JP") {
                    m2!.genres = (m2!.genres ?? []) + ["Anime"]
                }
                m = m2
            }
        }
        if var m2 = m, (m2.credits ?? []).isEmpty, let next = nextData(page) {
            // No photo cast list on this page shape: fall back to the "Stars" credits (names only).
            var found: [CastMember] = []
            walk(next) { d in
                guard found.isEmpty, let pcs = d["principalCredits"] as? [[String: Any]] else { return true }
                for pc in pcs where typeID(pc["category"]) == "cast" {
                    found = castMembers((pc["credits"] as? [[String: Any]]) ?? [])
                }
                return found.isEmpty
            }
            if !found.isEmpty { m2.credits = found; m = m2 }
        }
        if let m { store(key, m); dlog("imdb", "details \(id): \(m.name) rating=\(m.imdbRating ?? "-") cast=\(m.credits?.count ?? 0)\((m.credits?.first?.photo != nil) ? " with photos" : "")") } else { dlog("imdb/error", "details \(id): nothing parsed (\(page.count) chars)") }
        return m
    }

    // MARK: - Episodes

    struct SeasonList: Codable { var seasons: [Int] }

    static func seasons(id: String) async -> [Int] {
        let key = "seasons|\(id)"
        if let hit = cached(key, ttl: 86400, as: SeasonList.self) { return hit.seasons }
        guard let page = await html("/title/\(id)/episodes/") else { return [] }
        var found: [Int] = []
        if let next = nextData(page) {
            walk(next) { d in
                if let s = d["seasons"] as? [[String: Any]] {
                    let vals = s.compactMap { ($0["value"] as? String).flatMap(Int.init) ?? ($0["value"] as? Int) }
                    if !vals.isEmpty { found = vals; return false }
                }
                return true
            }
        }
        if found.isEmpty {
            // Fallback: season selector options in the markup.
            if let re = try? NSRegularExpression(pattern: #"season=(\d+)"#) {
                let ns = page as NSString
                var set = Set<Int>()
                for m in re.matches(in: page, range: NSRange(location: 0, length: ns.length)) { set.insert(Int(ns.substring(with: m.range(at: 1))) ?? 0) }
                found = set.filter { $0 > 0 }.sorted()
            }
        }
        found = Array(Set(found)).sorted()
        dlog("imdb", "seasons \(id): \(found)")
        if !found.isEmpty { store(key, SeasonList(seasons: found)) }
        return found
    }

    /// Episodes of one season as Stremio-style videos (`ttSERIES:season:episode`).
    static func episodes(id: String, season: Int) async -> [MetaVideo] {
        let key = "episodes|\(id)|\(season)|\(language)"
        if let hit = cached(key, ttl: 86400, as: [MetaVideo].self) { return hit }
        guard let page = await html("/title/\(id)/episodes/", ["season": String(season)]) else { return [] }
        var out: [MetaVideo] = []
        if let next = nextData(page) {
            walk(next) { d in
                guard let epId = (d["id"] as? String), epId.hasPrefix("tt") else { return true }
                let localized = text(d["titleText"]), original = text(d["originalTitleText"])
                // Prefer the title in the user's language; IMDb's `titleText` is
                // sometimes the original one (Japanese, romanised) for anime episodes,
                // so when both exist and `titleText` looks like the original, swap.
                guard let title = localized ?? original else { return true }
                let numbers = (d["series"] as? [String: Any])?["episodeNumber"] as? [String: Any]
                let ep = int(d["episode"]) ?? int(numbers?["episodeNumber"])
                let se = int(d["season"]) ?? int(numbers?["seasonNumber"]) ?? season
                guard let ep else { return true }
                var v = MetaVideo(id: "\(id):\(se):\(ep)", title: title, season: se, episode: ep)
                if let original, original != title { v.originalTitle = original }
                v.thumbnail = sized(imageURL(d["image"]) ?? imageURL(d["primaryImage"]), width: 480)
                v.overview = (d["plot"] as? String) ?? ((d["plot"] as? [String: Any])?["plotText"] as? [String: Any])?["plainText"] as? String
                if let rd = d["releaseDate"] as? [String: Any], let y = rd["year"] as? Int {
                    v.released = String(format: "%04d-%02d-%02d", y, (rd["month"] as? Int) ?? 1, (rd["day"] as? Int) ?? 1)
                } else if let s = d["releaseDate"] as? String { v.released = s }
                v.rating = Self.rating(d["aggregateRating"])
                v.imdbId = epId
                out.append(v)
                return false
            }
        }
        var seen = Set<String>()
        out = out.filter { seen.insert($0.id).inserted }.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
        dlog("imdb", "episodes \(id) S\(season): \(out.count)")
        if !out.isEmpty { store(key, out) }
        return out
    }

    // MARK: - Parsers

    static func jsonLD(_ html: String) -> [[String: Any]] {
        guard let re = try? NSRegularExpression(pattern: #"<script[^>]*type="application/ld\+json"[^>]*>(.*?)</script>"#, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        return re.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let json = ns.substring(with: m.range(at: 1))
            return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        }
    }

    static func jsonLDList(_ html: String, type: String) -> [MetaItem] {
        for obj in jsonLD(html) {
            guard let list = obj["itemListElement"] as? [[String: Any]], !list.isEmpty else { continue }
            var out: [MetaItem] = []
            for (i, el) in list.enumerated() {
                let item = (el["item"] as? [String: Any]) ?? el
                guard let urlStr = item["url"] as? String,
                      let id = urlStr.split(separator: "/").first(where: { $0.hasPrefix("tt") }).map(String.init) else { continue }
                let name = unescape((item["alternateName"] as? String) ?? (item["name"] as? String) ?? id)
                let rating = Self.rating((item["aggregateRating"] as? [String: Any])?["ratingValue"])
                let genres = (item["genre"] as? [String]) ?? (item["genre"] as? String).map { [$0] }
                let t = (item["@type"] as? String) ?? ""
                let itemType = t == "TVSeries" || t == "TVMiniSeries" ? "series" : (t == "Movie" || t == "TVMovie" ? "movie" : type)
                out.append(MetaItem(id: id, type: itemType, name: name, poster: sized(item["image"] as? String, width: 240),
                                    description: unescape(item["description"] as? String), releaseInfo: nil, imdbRating: rating, genres: genres, rank: i + 1))
            }
            if !out.isEmpty { return out }
        }
        return []
    }

    static func nextData(_ html: String) -> Any? {
        guard let start = html.range(of: #"<script id="__NEXT_DATA__""#) else { return nil }
        guard let open = html[start.upperBound...].range(of: ">") else { return nil }
        guard let end = html[open.upperBound...].range(of: "</script>") else { return nil }
        let json = String(html[open.upperBound..<end.lowerBound])
        return try? JSONSerialization.jsonObject(with: Data(json.utf8))
    }

    /// Anything in the page data that looks like a title.
    static func nextTitles(_ html: String, type: String) -> [MetaItem] {
        guard let root = nextData(html) else { return [] }
        var out: [MetaItem] = []
        var seen = Set<String>()
        walk(root) { d in
            guard let id = (d["titleId"] as? String) ?? (d["id"] as? String), id.hasPrefix("tt"), id.count >= 9,
                  let name = text(d["titleText"]) ?? text(d["originalTitleText"]) ?? text(d["titleNameText"]) else { return true }
            // Episodes / people lists are not titles for the grid.
            if d["episode"] != nil || d["seasonNumber"] != nil { return true }
            guard seen.insert(id).inserted else { return false }
            let tt = typeID(d["titleType"])
            var itemType = type
            if let tt { itemType = tt.contains("Series") ? "series" : (tt == "tvEpisode" ? "episode" : "movie") }
            if itemType == "episode" { return false }
            let rating = (d["ratingSummary"] as? [String: Any])?["aggregateRating"] ?? (d["ratingsSummary"] as? [String: Any])?["aggregateRating"] ?? d["aggregateRating"]
            var m = MetaItem(id: id, type: itemType, name: unescape(name),
                             poster: sized(imageURL(d["primaryImage"]) ?? imageURL(d["image"]) ?? imageURL(d["poster"]), width: 240),
                             description: (d["plot"] as? String) ?? ((d["plot"] as? [String: Any])?["plotText"] as? [String: Any])?["plainText"] as? String,
                             releaseInfo: (int(d["releaseYear"]) ?? int((d["releaseYear"] as? [String: Any])?["year"])).map(String.init),
                             imdbRating: Self.rating(rating),
                             genres: genreList(d), rank: int(d["currentRank"]) ?? int(d["rank"]))
            m.runtime = (int(d["runtime"]) ?? int((d["runtime"] as? [String: Any])?["seconds"])).flatMap { $0 > 0 ? "\($0 / 60) min" : nil }
            out.append(m)
            return false
        }
        return out
    }

    /// Depth-first visit of every dictionary; return false from the visitor to skip its children.
    static func walk(_ node: Any, _ visit: ([String: Any]) -> Bool) {
        if let d = node as? [String: Any] {
            guard visit(d) else { return }
            for v in d.values { walk(v, visit) }
        } else if let a = node as? [Any] {
            for v in a { walk(v, visit) }
        }
    }

    private static func text(_ v: Any?) -> String? {
        if let s = v as? String { return s.isEmpty ? nil : s }
        if let d = v as? [String: Any] { return (d["text"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return nil
    }
    private static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }
    /// Credit nodes (`{ name: { id, nameText, primaryImage }, characters: [{ name }] }`) → cast members.
    private static func castMembers(_ nodes: [[String: Any]]) -> [CastMember] {
        var out: [CastMember] = []
        var seen = Set<String>()
        for n in nodes {
            guard let person = n["name"] as? [String: Any], let pid = person["id"] as? String, pid.hasPrefix("nm"),
                  let name = text(person["nameText"]), seen.insert(pid).inserted else { continue }
            let chars = ((n["characters"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            let photo = sized(imageURL(person["primaryImage"]), width: 180)
            let role: String? = chars.isEmpty ? nil : unescape(Optional(chars.prefix(2).joined(separator: " / ")))
            let clean: String = unescape(Optional(name)) ?? name
            out.append(CastMember(id: pid, name: clean, character: role, photo: photo))
            if out.count >= 24 { break }
        }
        return out
    }

    private static func imageURL(_ v: Any?) -> String? {
        if let s = v as? String, s.hasPrefix("http") { return s }
        if let d = v as? [String: Any] { return d["url"] as? String }
        return nil
    }
    private static func typeID(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let d = v as? [String: Any] { return (d["id"] as? String) ?? (d["text"] as? String) }
        return nil
    }
    private static func genreList(_ d: [String: Any]) -> [String]? {
        if let g = d["genres"] as? [String] { return g }
        if let g = d["genres"] as? [String: Any], let list = g["genres"] as? [[String: Any]] { return list.compactMap { $0["text"] as? String } }
        if let g = d["titleGenres"] as? [String: Any], let list = g["genres"] as? [[String: Any]] {
            return list.compactMap { ($0["genre"] as? [String: Any])?["text"] as? String }
        }
        return nil
    }
    private static func prettyDuration(_ iso: String) -> String? {
        // PT2H28M
        var h = 0, m = 0
        if let r = iso.range(of: #"(\d+)H"#, options: .regularExpression) { h = Int(iso[r].dropLast()) ?? 0 }
        if let r = iso.range(of: #"(\d+)M"#, options: .regularExpression) { m = Int(iso[r].dropLast()) ?? 0 }
        guard h + m > 0 else { return nil }
        return h > 0 ? "\(h)h \(m)m" : "\(m) min"
    }
    static func unescape(_ s: String?) -> String? {
        guard var s else { return nil }
        for (a, b) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&#x27;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        return s
    }
    static func unescape(_ s: String) -> String { unescape(Optional(s)) ?? s }
}
