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
        return await Inflight.shared.page(url.absoluteString, label: path) { await fetch(url, path) }
    }

    /// Pages already being downloaded, by address: a second request for the
    /// same page waits for that download instead of starting another. Your
    /// 30 Oct log: /title/tt5607616/ fetched twice 201 ms apart (1758 KB
    /// each), its /episodes/ twice (1779 and 4032 ms) — the title page's
    /// lookups run side by side and asked for the same pages. The download
    /// stops only when everyone waiting for it has gone (a page closed).
    private actor Inflight {
        static let shared = Inflight()
        private var pages: [String: (task: Task<String?, Never>, waiting: Int)] = [:]

        func page(_ key: String, label: String, load: @escaping @Sendable () async -> String?) async -> String? {
            let task: Task<String?, Never>
            if let out = pages[key] {
                task = out.task
                pages[key]?.waiting += 1
                dlog("imdb", "\(label): joined the same request already out")
            } else {
                task = Task { await load() }
                pages[key] = (task, 1)
            }
            let page = await withTaskCancellationHandler { await task.value } onCancel: { Task { await self.leave(key, task) } }
            if pages[key]?.task == task { pages[key] = nil }
            return page
        }

        private func leave(_ key: String, _ task: Task<String?, Never>) {
            guard var out = pages[key], out.task == task else { return }
            out.waiting -= 1
            if out.waiting <= 0 { task.cancel(); pages[key] = nil } else { pages[key] = out }
        }
    }

    private static func fetch(_ url: URL, _ path: String) async -> String? {
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
        // Only worth the radio and (sometimes) a browser page load when Discover
        // is actually in use: skipped if it hasn't been opened in a week or the
        // phone is in Low Power Mode. Discover itself fetches on open anyway.
        let last = UserDefaults.standard.double(forKey: "discoverLastUsed")
        guard last > 0, Date().timeIntervalSince1970 - last < 7 * 86400, !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            dlog("imdb", "warm-up skipped (Discover not used recently or Low Power Mode)")
            return
        }
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
    /// UI tests: fill the cache with a chart, a film and a series shaped like
    /// real IMDb results (cast without photos, as phones get them), so the
    /// Discover → title page path runs with no network.
    /// `art`: poster/backdrop URLs for the film and the series (the screenshot run).
    static func seedForLab(art: (String, String, String, String)? = nil) {
        let cast = [CastMember(id: "nm0000001", name: "Lab Actor One", character: "Hero", photo: nil),
                    CastMember(id: "nm0000002", name: "Lab Actor Two", character: "Rival", photo: nil),
                    CastMember(id: "nm0000003", name: "Lab Actor Three", character: nil, photo: nil),
                    CastMember(id: "nm0000004", name: "Lab Actor Four", character: "Friend / Narrator", photo: nil)]
        var film = MetaItem(id: "tt9000001", type: "movie", name: "Lab Movie", poster: nil,
                            description: String(repeating: "A long synopsis so the more button shows. ", count: 8),
                            releaseInfo: "2025", imdbRating: "7.5", genres: ["Drama", "Thriller"])
        film.runtime = "1h 52m"; film.contentRating = "M"; film.credits = cast; film.director = ["Lab Director"]
        if let art { film.poster = art.2; film.background = art.3 }
        var show = MetaItem(id: "tt9000002", type: "series", name: "Lab Series", poster: nil,
                            description: "A short synopsis.", releaseInfo: "2024", imdbRating: "9.3", genres: ["Animation", "Anime"])
        show.originalName = "Rabo Shirīzu"; show.contentRating = "TV-MA"; show.credits = cast; show.countries = ["JP"]
        if let art { show.poster = art.0; show.background = art.1 }
        let lang = language
        store("chart|/chart/moviemeter/|\(lang)", [film, show])
        store("chart|/chart/tvmeter/|\(lang)", [show, film])
        store("title4|\(film.id)|\(lang)", film)
        store("title4|\(show.id)|\(lang)", show)
        store("seasons|\(show.id)", SeasonList(seasons: [1, 2]))
        for season in [1, 2] {
            let eps = (1...6).map { e -> MetaVideo in
                var v = MetaVideo(id: "\(show.id):\(season):\(e)", title: "Episode title \(e)", season: season, episode: e)
                v.overview = "What happens in episode \(e)."
                return v
            }
            store("episodes2|\(show.id)|\(season)|\(lang)", eps)
        }
        // Live search as you type "lab" (and its first two letters).
        for q in ["la", "lab", "lab m", "lab mo", "lab mov", "lab movi", "lab movie"] { store("suggest|\(q)", q.count > 3 ? [film] : [film, show]) }
        store("suggest|labx", [MetaItem]())
        dlog("lab", "IMDb cache seeded (Lab Movie, Lab Series)")
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
        do {
            return try await suggest(query)
        } catch {
            if !isCancellation(error) { dlog("imdb/error", "suggestion failed for \(query): \(error.localizedDescription)") }
            return []
        }
    }

    /// The suggestion API's answer for `query`, the same as `search(_:)` but
    /// a failure is thrown instead of looking like "no results" (Discover's
    /// live search shows them differently). Cancelling the calling task
    /// cancels the request; the error is then CancellationError or
    /// URLError.cancelled (see isCancellation).
    static func suggest(_ query: String) async throws -> [MetaItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let key = "suggest|\(q)"
        if let hit = cached(key, ttl: 86400, as: [MetaItem].self) { return hit }
        let path = q.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? q
        guard let url = URL(string: "https://v3.sg.media-imdb.com/suggestion/x/\(path).json") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        try Task.checkCancellation()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"]) }
        let res = try JSONDecoder().decode(SuggestionResponse.self, from: data)
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

    /// A request ended because its task was cancelled (a newer query took over).
    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    // MARK: - Title details

    static func details(id: String, type hint: String) async -> MetaItem? {
        // title4 (1.18.1): titles saved before kept no original (romaji) title,
        // MetaItem's Codable left it out, so each one is fetched once more.
        let key = "title4|\(id)|\(language)"
        if let hit = cached(key, ttl: 7 * 86400, as: MetaItem.self) { return hit }
        guard let page = await html("/title/\(id)/") else { return nil }
        let m = parseDetails(page: page, id: id, hint: hint)
        if let m { store(key, m); dlog("imdb", "details \(id): \(m.name) rating=\(m.imdbRating ?? "-") cast=\(m.credits?.count ?? 0)\((m.credits?.first?.photo != nil) ? " with photos" : "")") } else { dlog("imdb/error", "details \(id): nothing parsed (\(page.count) chars)") }
        return m
    }

    /// The title page → a title (separate from the fetch so the lab can feed
    /// it page data in IMDb's shapes).
    static func parseDetails(page: String, id: String, hint: String) -> MetaItem? {
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
                if m2!.releaseInfo == nil { m2!.releaseInfo = fromData?.releaseInfo }
                if m2!.runtime == nil { m2!.runtime = fromData?.runtime }
                // One pass over the whole page data. Nothing is skipped: 1.13.0
                // stopped descending at the object holding `countriesOfOrigin`,
                // which is the main title object — and the cast with photos
                // lives inside it, so only the photo-less "Stars" were found.
                var mains: [(score: Int, d: [String: Any])] = []
                var castLists: [(path: String, members: [CastMember])] = []
                walkPaths(next, path: "") { d, path in
                    // The show's original title: from the object that IS this
                    // title (it carries year/rating/genres), not one that merely
                    // references it (an episode's "series" link carried the
                    // episode's own original title into the show in 1.13.0).
                    if (d["id"] as? String) == id, d["titleText"] != nil || d["originalTitleText"] != nil {
                        let score = ["titleText", "releaseYear", "ratingsSummary", "titleType", "genres", "plot", "runtimeSeconds", "releaseDate"].filter { d[$0] != nil }.count
                        mains.append((score, d))
                    }
                    for (key, value) in d {
                        guard let arr = value as? [[String: Any]], arr.count >= 2 else { continue }
                        let nodes = arr.map { ($0["node"] as? [String: Any]) ?? $0 }
                        let list = castMembers(nodes)
                        if list.count >= 2 { castLists.append((path + "." + key, list)) }
                    }
                    if let c = d["countriesOfOrigin"] as? [String: Any], let list = c["countries"] as? [[String: Any]] {
                        m2!.countries = list.compactMap { $0["id"] as? String }
                    }
                    if m2!.description == nil, let plot = d["plot"] as? [String: Any], let pt = plot["plotText"] as? [String: Any], let s = pt["plainText"] as? String {
                        m2!.description = unescape(s) as String
                    }
                    if m2!.releaseInfo == nil, let ry = d["releaseYear"] as? [String: Any], let y = ry["year"] as? Int { m2!.releaseInfo = String(y) }
                    if m2!.background == nil, let img = d["primaryVideos"] as? [String: Any], let edges = img["edges"] as? [[String: Any]],
                       let node = edges.first?["node"] as? [String: Any], let thumb = (node["thumbnail"] as? [String: Any])?["url"] as? String {
                        m2!.background = sized(thumb, width: 1280)
                    }
                }
                // Name and original title from the object that IS this title.
                if let best = mains.max(by: { $0.score < $1.score })?.d {
                    if let n = text(best["titleText"]), !n.isEmpty { m2!.name = unescape(n) }
                    if let o = text(best["originalTitleText"]), o != m2!.name { m2!.originalName = unescape(o) }
                }
                // The cast list with the most photos, then the most roles (actors
                // have characters; writer/director lists don't), then the longest.
                func rank(_ l: [CastMember]) -> (Int, Int, Int) {
                    (l.filter { $0.photo != nil }.count, l.filter { $0.character != nil }.count, l.count)
                }
                if let best = castLists.max(by: { rank($0.members) < rank($1.members) }) {
                    m2!.credits = best.members
                    dlog("imdb", "cast \(id): \(castLists.count) list(s); chose \(best.path) — \(best.members.count) people, \(best.members.filter { $0.photo != nil }.count) photos, \(best.members.filter { $0.character != nil }.count) roles")
                } else {
                    dlog("imdb", "cast \(id): no cast list found in page data")
                }
                dlog("imdb", "title \(id): \(mains.count) candidate object(s); name \(m2!.name), original \(m2!.originalName ?? "none")")
                if let best = mains.max(by: { $0.score < $1.score })?.d {
                    // The page data's own fields, as IMDb sent them.
                    let raw = ["titleText", "originalTitleText"].map { k in "\(k)=\(best[k].map { String(describing: $0) } ?? "absent")" }
                    dlog("imdb", "title \(id) raw: \(raw.joined(separator: " "))")
                }
                if (m2!.genres ?? []).contains(where: { $0.caseInsensitiveCompare("Animation") == .orderedSame }),
                   (m2!.countries ?? []).contains("JP") {
                    m2!.genres = (m2!.genres ?? []) + ["Anime"]
                }
                m = m2
            }
        }
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

    /// Episodes of one season as addon-style videos (`ttSERIES:season:episode`).
    /// A season's episodes; titles in English where IMDb only has the
    /// original-language one (Settings → General → Episode titles).
    static func episodes(id: String, season: Int) async -> [MetaVideo] {
        let raw = await imdbEpisodes(id: id, season: season)
        let show = cachedStale("title4|\(id)|\(language)", as: MetaItem.self)
        return await EpisodeTitles.apply(raw, imdbID: id, name: show?.name, year: show?.releaseInfo)
    }

    private static func imdbEpisodes(id: String, season: Int) async -> [MetaVideo] {
        let key = "episodes2|\(id)|\(season)|\(language)"
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
                var v = MetaVideo(id: "\(id):\(se):\(ep)", title: unescape(title) as String, season: se, episode: ep)
                if let original, original != title { v.originalTitle = unescape(original) as String }
                v.thumbnail = sized(imageURL(d["image"]) ?? imageURL(d["primaryImage"]), width: 480)
                v.overview = unescape((d["plot"] as? String) ?? ((d["plot"] as? [String: Any])?["plotText"] as? [String: Any])?["plainText"] as? String)
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
                             description: unescape((d["plot"] as? String) ?? ((d["plot"] as? [String: Any])?["plotText"] as? [String: Any])?["plainText"] as? String),
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
            let chars = characters(in: n)
            let photo = sized(imageURL(person["primaryImage"]), width: 180)
            let role: String? = chars.isEmpty ? nil : unescape(Optional(chars.prefix(2).joined(separator: " / ")))
            let clean: String = unescape(Optional(name)) ?? name
            out.append(CastMember(id: pid, name: clean, character: role, photo: photo))
            if out.count >= 24 { break }
        }
        return out
    }

    /// Role names in either shape IMDb uses: `characters: [{name}]` or
    /// `creditedRoles.edges[].node.characters.edges[].node.name`.
    private static func characters(in credit: [String: Any]) -> [String] {
        if let list = credit["characters"] as? [[String: Any]] {
            let names = list.compactMap { ($0["name"] as? String) ?? (($0["node"] as? [String: Any])?["name"] as? String) }
            if !names.isEmpty { return names }
        }
        if let c = credit["characters"] as? [String: Any], let edges = c["edges"] as? [[String: Any]] {
            let names = edges.compactMap { ($0["node"] as? [String: Any])?["name"] as? String }
            if !names.isEmpty { return names }
        }
        if let roles = credit["creditedRoles"] as? [String: Any], let edges = roles["edges"] as? [[String: Any]] {
            for e in edges {
                if let node = e["node"] as? [String: Any] {
                    let names = characters(in: node)
                    if !names.isEmpty { return names }
                }
            }
        }
        return []
    }

    /// Like `walk`, with the key path (for the log).
    static func walkPaths(_ node: Any, path: String, _ visit: ([String: Any], String) -> Void) {
        if let d = node as? [String: Any] {
            visit(d, path)
            for (k, v) in d { walkPaths(v, path: path + "." + k, visit) }
        } else if let a = node as? [Any] {
            for v in a { walkPaths(v, path: path + "[]", visit) }
        }
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
    /// Text from IMDb with its HTML character references decoded (all of
    /// them: until 1.19.0 a short list, and episode plots weren't decoded).
    static func unescape(_ s: String?) -> String? { s?.decodingHTMLEntities }
    static func unescape(_ s: String) -> String { unescape(Optional(s)) ?? s }
}
