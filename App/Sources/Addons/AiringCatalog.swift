import Foundation

/// What's airing now, for Discover's "Airing now" row (1.26.0).
/// Series: TVmaze's schedule (US TV and streaming, yesterday and today),
/// the most followed shows first. Anime: AniList's releasing anime, the
/// most talked about first. Both free and keyless, like the tracker's
/// schedules (AiringService). Kept for 30 minutes in memory and on disk,
/// so the row shows at once on the next launch while a fresh copy loads.
enum AiringCatalog {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case series, anime
        var id: String { rawValue }
        var title: String { self == .series ? "Series" : "Anime" }
    }

    /// One tile: the title, and what's new or next ("S2 · E4 today", "E7 in 2 days").
    struct Entry: Codable, Hashable, Identifiable, Sendable {
        var meta: MetaItem
        var note: String?
        var id: String { meta.id }
    }

    private struct Saved: Codable { var at: Date; var entries: [Entry] }
    private static let freshFor: TimeInterval = 30 * 60

    /// The last list for `kind` (any age), from disk.
    static func cached(_ kind: Kind) -> (entries: [Entry], fresh: Bool)? {
        guard let data = try? Data(contentsOf: file(kind)), let s = try? JSONDecoder().decode(Saved.self, from: data), !s.entries.isEmpty else { return nil }
        return (s.entries, Date().timeIntervalSince(s.at) < freshFor)
    }

    /// A fresh list (empty when the service couldn't be reached).
    static func load(_ kind: Kind) async -> [Entry] {
        let entries = kind == .series ? await series() : await anime()
        if !entries.isEmpty, let data = try? JSONEncoder().encode(Saved(at: Date(), entries: entries)) {
            try? data.write(to: file(kind), options: .atomic)
        }
        dlog("discover", "airing now (\(kind.rawValue)): \(entries.count) title(s)")
        return entries
    }

    private static func file(_ kind: Kind) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("airing-now-\(kind.rawValue).json")
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.httpAdditionalHeaders = ["User-Agent": "Folio/1.0"]
        return URLSession(configuration: c)
    }()

    // MARK: Series (TVmaze)

    private struct TVItem: Decodable {
        var season: Int?
        var number: Int?
        var airstamp: String?
        var show: TVShow?
        var _embedded: Embedded?
        struct Embedded: Decodable { var show: TVShow? }
        var theShow: TVShow? { show ?? _embedded?.show }
    }

    private struct TVShow: Decodable {
        struct Rating: Decodable { var average: Double? }
        struct Externals: Decodable { var imdb: String? }
        struct Image: Decodable { var medium: String?; var original: String? }
        var id: Int
        var name: String
        var language: String?
        var genres: [String]?
        var type: String?
        var premiered: String?
        var rating: Rating?
        var weight: Int?
        var externals: Externals?
        var image: Image?
        var summary: String?
    }

    static func series(now: Date = Date()) async -> [Entry] {
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "America/New_York")
        day.dateFormat = "yyyy-MM-dd"
        let dates = [now.addingTimeInterval(-86_400), now].map { day.string(from: $0) }
        var urls: [URL] = []
        for d in dates {
            if let u = URL(string: "https://api.tvmaze.com/schedule?country=US&date=\(d)") { urls.append(u) }
            if let u = URL(string: "https://api.tvmaze.com/schedule/web?date=\(d)") { urls.append(u) }
        }
        let items = await withTaskGroup(of: [TVItem].self) { group in
            for u in urls {
                group.addTask {
                    guard let (data, resp) = try? await session.data(from: u), (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
                    // Entry by entry (1.30.4): one odd entry in TVmaze's day dropped the whole day.
                    return JSONDecoder().decodeLossy(TVItem.self, from: data) ?? []
                }
            }
            var all: [TVItem] = []
            for await part in group { all += part }
            return all
        }
        // One tile per show, its newest episode out.
        var best: [Int: (show: TVShow, item: TVItem)] = [:]
        for it in items {
            guard let s = it.theShow, let imdb = s.externals?.imdb, imdb.hasPrefix("tt"), s.image != nil,
                  !(s.genres ?? []).contains("Anime"), s.type != "News", s.type != "Talk Show", s.type != "Sports",
                  s.language == nil || s.language == "English" else { continue }
            if let have = best[s.id], (have.item.airstamp ?? "") >= (it.airstamp ?? "") { continue }
            best[s.id] = (s, it)
        }
        let iso = ISO8601DateFormatter()
        return best.values
            .sorted { ($0.show.weight ?? 0, $0.show.rating?.average ?? 0) > ($1.show.weight ?? 0, $1.show.rating?.average ?? 0) }
            .prefix(24)
            .map { s, it in
                var m = MetaItem(id: s.externals?.imdb ?? "", type: "series", name: s.name,
                                 poster: s.image?.original ?? s.image?.medium,
                                 description: s.summary.map(stripTags), releaseInfo: s.premiered.map { String($0.prefix(4)) },
                                 imdbRating: s.rating?.average.map { String(format: "%.1f", $0) }, genres: s.genres)
                m.posterShape = "poster"
                let ep = [it.season.map { "S\($0)" }, it.number.map { "E\($0)" }].compactMap { $0 }.joined(separator: " · ")
                let when = it.airstamp.flatMap { iso.date(from: $0) }.map { relative($0, now: now) }
                return Entry(meta: m, note: [ep.isEmpty ? nil : ep, when].compactMap { $0 }.joined(separator: " "))
            }
    }

    // MARK: Anime (AniList)

    private struct ALAnswer: Decodable {
        struct D: Decodable { var Page: P? }
        struct P: Decodable { var media: [ALMedia]? }
        var data: D?
    }

    private struct ALMedia: Decodable {
        struct Title: Decodable { var romaji: String?; var english: String? }
        struct Cover: Decodable { var extraLarge: String?; var large: String? }
        struct Next: Decodable { var episode: Int?; var airingAt: Int? }
        var id: Int
        var title: Title?
        var coverImage: Cover?
        var bannerImage: String?
        var averageScore: Int?
        var seasonYear: Int?
        var genres: [String]?
        var description: String?
        var nextAiringEpisode: Next?
        var isAdult: Bool?
    }

    static func anime(now: Date = Date()) async -> [Entry] {
        let query = """
        query { Page(page: 1, perPage: 30) { media(type: ANIME, status: RELEASING, isAdult: false, format_in: [TV, TV_SHORT, ONA], sort: [TRENDING_DESC, POPULARITY_DESC]) {
          id title { romaji english } coverImage { extraLarge large } bannerImage averageScore seasonYear genres
          description(asHtml: false) nextAiringEpisode { episode airingAt } isAdult } } }
        """
        guard let url = URL(string: "https://graphql.anilist.co") else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let media = (try? JSONDecoder().decode(ALAnswer.self, from: data))?.data?.Page?.media else { return [] }
        return media.filter { $0.isAdult != true }.prefix(24).map { a in
            let name = a.title?.english ?? a.title?.romaji ?? "Anime \(a.id)"
            var m = MetaItem(id: "anilist:\(a.id)", type: "series", name: name,
                             poster: a.coverImage?.extraLarge ?? a.coverImage?.large,
                             description: a.description.map(stripTags), releaseInfo: a.seasonYear.map(String.init),
                             imdbRating: a.averageScore.map { String(format: "%.1f", Double($0) / 10) },
                             genres: (a.genres ?? []) + ["Anime"])
            m.background = a.bannerImage
            if let r = a.title?.romaji, r != name { m.originalName = r }
            var note: String?
            if let n = a.nextAiringEpisode, let e = n.episode, let at = n.airingAt {
                note = "E\(e) \(relative(Date(timeIntervalSince1970: TimeInterval(at)), now: now))"
            }
            return Entry(meta: m, note: note)
        }
    }

    // MARK: Helpers

    /// "today", "yesterday", "in 3 days", "tomorrow".
    static func relative(_ date: Date, now: Date) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case let d where d > 1: return "in \(d) days"
        default: return "\(-days) days ago"
        }
    }

    private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").decodingHTMLEntities
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
