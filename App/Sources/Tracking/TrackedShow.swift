import Foundation

// The airing tracker (1.21.0): shows you track, with when their next
// episodes air. Series schedules come from TVmaze (exact air times in UTC,
// free, no key), anime from AniList (MyAnimeList's own API needs a
// registered client and only gives a weekly slot in Japan time).

/// One episode on a show's schedule. Everything optional: AniList numbers
/// each season on its own (no season), and an episode may have no title yet.
struct AiringEpisode: Codable, Hashable, Sendable {
    var season: Int?
    var number: Int?
    var title: String?
    /// The moment it airs (TVmaze's airstamp, AniList's airingAt).
    var airDate: Date?

    /// "S1 · E5", "E5", "S1 · Special".
    var label: String {
        switch (season, number) {
        case let (s?, n?): return "S\(s) · E\(n)"
        case let (nil, n?): return "E\(n)"
        case let (s?, nil): return "S\(s) · Special"
        default: return "New episode"
        }
    }
}

/// A show you track. Every field but `id` and `name` is optional, and the
/// enums read values they don't know as `.unknown`, so a list saved by any
/// version always reads back (TrackingStore also skips an entry it can't read).
struct TrackedShow: Codable, Identifiable, Hashable, Sendable {
    enum Status: String, Codable, Sendable {
        case airing, upcoming, ended, unknown

        init(from decoder: Decoder) throws {
            self = Status(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .unknown
        }

        var title: String {
            switch self {
            case .airing: return "Airing"
            case .upcoming: return "Coming soon"
            case .ended: return "Ended"
            case .unknown: return "No schedule yet"
            }
        }
    }

    /// Where the schedule comes from.
    enum Source: String, Codable, Sendable {
        case tvmaze, anilist, unknown

        init(from decoder: Decoder) throws {
            self = Source(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .unknown
        }

        var title: String {
            switch self {
            case .tvmaze: return "TVmaze"
            case .anilist: return "AniList"
            case .unknown: return "the web"
            }
        }
    }

    /// "tt31510819", or "anilist:…" / "mal:…" / "kitsu:…" for anime without
    /// an IMDb id, or "name:…" (TrackedShow.makeID).
    var id: String
    var name: String
    var imdb: String?
    var tvmaze: Int?
    var anilist: Int?
    var mal: Int?
    var kitsu: Int?
    /// Japanese animation: AniList is asked first (AiringRoute).
    var anime: Bool?
    /// The premiere year Folio knows, for a search by name.
    var year: Int?
    /// Anime from the library: the season its files are in (AniList has an
    /// entry per season).
    var season: Int?
    var poster: String?
    var status: Status?
    /// The network or streaming service ("HBO", "Crunchyroll").
    var network: String?
    var next: AiringEpisode?
    /// Episodes known after `next` (AniList's schedule), soonest first.
    var later: [AiringEpisode]?
    var lastAired: AiringEpisode?
    var source: Source?
    /// The show's page on TVmaze or MyAnimeList.
    var page: String?
    /// When the schedule was last fetched. A fetch that failed leaves it,
    /// and the schedule, as they were.
    var updated: Date?
    var added: Date?
    /// The schedule's source was reached and doesn't know the show.
    var notFound: Bool?

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

// MARK: - Schedule

extension TrackedShow {
    /// Every episode with an air time, oldest first.
    var schedule: [AiringEpisode] {
        var seen = Set<String>(), out: [AiringEpisode] = []
        for e in [lastAired, next].compactMap({ $0 }) + (later ?? []) {
            guard let d = e.airDate, seen.insert("\(e.season ?? -1):\(e.number ?? -1):\(d.timeIntervalSince1970)").inserted else { continue }
            out.append(e)
        }
        return out.sorted { $0.airDate! < $1.airDate! }
    }

    /// The episodes still to come at `now`, soonest first.
    func upcoming(after now: Date) -> [AiringEpisode] { schedule.filter { $0.airDate! > now } }

    /// What the show's row is about at `now` (AiringClock.headline): an
    /// episode out in the last six hours, else the next one.
    func headline(at now: Date) -> AiringEpisode? {
        let s = schedule
        return AiringClock.headline(s.map { $0.airDate! }, at: now).map { s[$0] }
    }

    /// The page on TVmaze or MyAnimeList, and what to call it.
    var pageLink: (title: String, url: URL)? {
        guard let page, let url = URL(string: page) else { return nil }
        if url.host?.contains("myanimelist") == true { return ("MyAnimeList", url) }
        if url.host?.contains("anilist") == true { return ("AniList", url) }
        return ("TVmaze", url)
    }

    /// Puts in what a source answered. The ids, the name and the poster you
    /// tracked it with stay; the schedule is the source's, even when it now
    /// has no next episode (it said so: that's not a failure).
    mutating func apply(_ f: AiringFetch, at now: Date) {
        source = f.source
        if let v = f.tvmaze { tvmaze = v }
        if let v = f.anilist { anilist = v }
        if let v = f.mal { mal = v }
        if imdb == nil { imdb = f.imdb }
        if poster == nil { poster = f.poster }
        if let p = f.page { page = p }
        status = f.status
        network = f.network ?? network
        next = f.next
        later = f.later.isEmpty ? nil : f.later
        lastAired = f.lastAired ?? lastAired
        updated = now
        notFound = nil
    }

    /// The source was reached and doesn't know the show. What was known
    /// before stays; it's asked again after the usual wait.
    mutating func markNotFound(at now: Date) {
        notFound = true
        updated = now
        if status == nil { status = .unknown }
    }
}

/// What TVmaze or AniList says about a show (AiringParse).
struct AiringFetch: Equatable, Sendable {
    var source: TrackedShow.Source
    var tvmaze: Int?
    var anilist: Int?
    var mal: Int?
    var imdb: String?
    var name: String?
    var status: TrackedShow.Status
    var network: String?
    var poster: String?
    var page: String?
    var next: AiringEpisode?
    var later: [AiringEpisode] = []
    var lastAired: AiringEpisode?
    /// AniList: the next season (an airing or announced one first), followed when this one has finished.
    var sequel: Int?
}

// MARK: - Making one

extension TrackedShow {
    /// A Discover title (MetaDetailView). `imdbID`: the IMDb id the page
    /// resolved, when it has one.
    init(meta m: MetaItem, imdbID: String?) {
        let ids = Self.animeIDs(m.id)
        let imdb = imdbID ?? (m.id.hasPrefix("tt") ? m.id : nil)
        self.init(id: Self.makeID(imdb: imdb, anilist: ids.anilist, mal: ids.mal, kitsu: ids.kitsu, name: m.name), name: m.name)
        self.imdb = imdb
        anilist = ids.anilist; mal = ids.mal; kitsu = ids.kitsu
        anime = m.isAnime || AiringRoute.isAnime(id: m.id, genres: m.genres, countries: m.countries)
        year = m.releaseInfo.flatMap { Int($0.prefix(4)) }
        poster = m.poster
    }

    /// A library series (TitleHeroView): its name, the metadata Folio found
    /// for it, an anime hint from its history, the newest season in the library.
    init(libraryTitle: String, meta: MediaMeta?, hint: AnimeHint?, season: Int?) {
        let imdb = meta.flatMap { $0.id.hasPrefix("tt") ? $0.id : nil }
        let name = meta?.name ?? libraryTitle
        self.init(id: Self.makeID(imdb: imdb, anilist: hint?.anilistId, mal: hint?.malId, kitsu: hint?.kitsuId, name: name), name: name)
        self.imdb = imdb
        anilist = hint?.anilistId; mal = hint?.malId; kitsu = hint?.kitsuId
        anime = AiringRoute.isAnime(id: meta?.id, genres: meta?.genres, hint: hint)
        year = meta?.year.flatMap { Int($0.prefix(4)) }
        self.season = season
        poster = meta?.poster
    }

    /// The IMDb id when there is one (what Discover and the library share),
    /// else an anime id, else the name.
    static func makeID(imdb: String?, anilist: Int?, mal: Int?, kitsu: Int?, name: String) -> String {
        if let imdb { return imdb }
        if let anilist { return "anilist:\(anilist)" }
        if let mal { return "mal:\(mal)" }
        if let kitsu { return "kitsu:\(kitsu)" }
        return "name:" + normalized(name)
    }

    /// "kitsu:46474" → kitsu 46474; "mal:…", "anilist:…" likewise.
    static func animeIDs(_ id: String) -> (anilist: Int?, mal: Int?, kitsu: Int?) {
        let parts = id.split(separator: ":")
        guard parts.count >= 2, let n = Int(parts[1]) else { return (nil, nil, nil) }
        switch parts[0] {
        case "anilist": return (n, nil, nil)
        case "mal": return (nil, n, nil)
        case "kitsu": return (nil, nil, n)
        default: return (nil, nil, nil)
        }
    }

    /// Letters and digits only, lowercased: "Mob Land" and "MobLand" match.
    static func normalized(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// The same show tracked from another page: any id in common, else the
    /// same name (and year, when both know it).
    func isSameShow(as o: TrackedShow) -> Bool {
        if id == o.id { return true }
        func same<T: Equatable>(_ a: T?, _ b: T?) -> Bool { a != nil && a == b }
        if same(imdb, o.imdb) || same(anilist, o.anilist) || same(mal, o.mal) || same(kitsu, o.kitsu) || same(tvmaze, o.tvmaze) { return true }
        // Two different IMDb ids are two different shows, whatever their names.
        if imdb != nil, o.imdb != nil { return false }
        guard Self.normalized(name) == Self.normalized(o.name) else { return false }
        if let a = year, let b = o.year { return abs(a - b) <= 1 }
        return true
    }
}

// MARK: - Anime or series

/// Which source a show's schedule is asked from first. The signs Folio
/// already has: an anime addon's id, an anime hint with an id, the "Anime"
/// genre IMDbSource adds to Japanese animation, or Animation from Japan.
enum AiringRoute {
    static func isAnime(id: String?, genres: [String]?, countries: [String]? = nil, hint: AnimeHint? = nil) -> Bool {
        if let id, ["kitsu:", "mal:", "anilist:", "anidb:"].contains(where: { id.hasPrefix($0) }) { return true }
        // A hint alone isn't a sign: library episodes get one from their file
        // name (ShowCatalog.play). One with an anime database's id is.
        if let h = hint, h.malId != nil || h.anilistId != nil || h.kitsuId != nil || h.anidbId != nil { return true }
        let g = (genres ?? []).map { $0.lowercased() }
        if g.contains("anime") { return true }
        let japanese = (countries ?? []).contains { ["jp", "japan"].contains($0.lowercased()) }
        return g.contains("animation") && japanese
    }
}

// MARK: - Grouping

/// The Tracking screen's sections.
enum AiringGroup: Int, CaseIterable, Identifiable {
    case today, week, later, other
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .today: return "Airing today"
        case .week: return "This week"
        case .later: return "Later"
        case .other: return "Ended or no date yet"
        }
    }

    /// Today: out in the last six hours or airing before midnight. This week:
    /// the next seven days. Later: after that. Other: nothing to come.
    static func of(_ show: TrackedShow, now: Date, calendar: Calendar = .current) -> AiringGroup {
        guard let d = show.headline(at: now)?.airDate else { return .other }
        if d <= now || calendar.isDate(d, inSameDayAs: now) { return .today }
        if let end = calendar.date(byAdding: .day, value: 8, to: calendar.startOfDay(for: now)), d < end { return .week }
        return .later
    }

    /// The groups that have shows, each soonest first (the last by name).
    static func grouped(_ shows: [TrackedShow], now: Date, calendar: Calendar = .current) -> [AiringSection] {
        let byGroup = Dictionary(grouping: shows) { of($0, now: now, calendar: calendar) }
        return allCases.compactMap { g in
            guard let list = byGroup[g], !list.isEmpty else { return nil }
            let sorted = g == .other
                ? list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                : list.sorted { ($0.headline(at: now)?.airDate ?? .distantFuture) < ($1.headline(at: now)?.airDate ?? .distantFuture) }
            return AiringSection(group: g, shows: sorted)
        }
    }
}

struct AiringSection: Identifiable {
    let group: AiringGroup
    let shows: [TrackedShow]
    var id: Int { group.rawValue }
}
