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
    /// The network's date ("2026-11-13") when TVmaze has no time for it
    /// (1.22.6). Streaming releases mostly have none, and TVmaze's airstamp
    /// is then 12:00 UTC, which isn't when it comes out (Tulsa King showed
    /// "Airs tomorrow 11:00 pm" in Melbourne): such an episode shows its day
    /// only. `airDate` still orders it and decides when it's "New".
    var day: String?

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
    /// The show's other names (1.22.1): its original or romaji title, and
    /// the name its files have in the library. The library and Discover
    /// pages find it tracked by any of them (isSameShow), so a show tracked
    /// on one shows Tracking on the other with no id in common.
    var otherNames: [String]?
    /// The series is over (1.22.6): IMDb gives it an end year, or TVmaze
    /// calls it Ended. AniList's "finished" is a season's, not the show's,
    /// so it doesn't count. With it, a finished AniList season's sequel isn't
    /// followed (Dragon Ball took Dragon Ball Super: Beerus's schedule), and
    /// the show stops being tracked once its last episode's week is over.
    var seriesEnded: Bool?
    /// When IMDb was last asked whether the series has ended (1.30.2): a
    /// show still running was asked on every refresh.
    var endedChecked: Date?
    /// An ended series' AniList entry has been looked up again by name
    /// (1.30.2, TrackingStore.run): once is enough.
    var sequelRepaired: Bool?

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
        if f.source == .tvmaze, f.status == .ended { seriesEnded = true }
        network = f.network ?? network
        // The episode just out keeps the moment it aired when Folio saw it
        // coming: AniList names it without a time (1.22.1, for "New").
        let known = schedule
        func dated(_ e: AiringEpisode?) -> AiringEpisode? {
            guard var e, e.airDate == nil, e.number != nil else { return e }
            e.airDate = known.last { $0.number == e.number && ($0.season == nil || e.season == nil || $0.season == e.season) }?.airDate
            return e
        }
        next = f.next
        later = f.later.isEmpty ? nil : f.later
        lastAired = dated(f.lastAired) ?? lastAired
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

    /// Nothing more will air (1.22.6): the series has ended, nothing is on
    /// its schedule, and its last episode has had its week as "New" (or has
    /// no date: Bleach's last aired in 2012).
    func isOver(at now: Date) -> Bool {
        guard seriesEnded == true, upcoming(after: now).isEmpty else { return false }
        if let d = lastAired?.airDate, now.timeIntervalSince(d) < EpisodeAiring.newFor { return false }
        return true
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
    /// AniList: the sequel's format ("TV", "MOVIE", "SPECIAL"…). Only a TV
    /// or web series is followed (1.22.6).
    var sequelFormat: String?
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
        otherNames = Self.names([m.originalName], besides: m.name)
        if m.hasEnded { seriesEnded = true }
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
        otherNames = Self.names([meta?.originalName, libraryTitle, hint?.title], besides: name)
    }

    /// The names that aren't `name` (spelling aside), once each; nil when none.
    static func names(_ list: [String?], besides name: String) -> [String]? {
        var seen: Set<String> = [normalized(name)]
        let out = list.compactMap { $0 }.filter { n in
            let k = normalized(n)
            return !k.isEmpty && seen.insert(k).inserted
        }
        return out.isEmpty ? nil : out
    }

    /// Every name the show goes by, as isSameShow compares them.
    var allNames: Set<String> {
        Set(([name] + (otherNames ?? [])).map(Self.normalized).filter { !$0.isEmpty })
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

    /// The same show tracked from another page: any id in common, else a
    /// name in common (and the year, when both know it). 1.22.1: any of
    /// their names, not just the first — the library's file name ("Sousou no
    /// Frieren") against Discover's English title.
    func isSameShow(as o: TrackedShow) -> Bool {
        if id == o.id { return true }
        func same<T: Equatable>(_ a: T?, _ b: T?) -> Bool { a != nil && a == b }
        if same(imdb, o.imdb) || same(anilist, o.anilist) || same(mal, o.mal) || same(kitsu, o.kitsu) || same(tvmaze, o.tvmaze) { return true }
        // Two different IMDb ids are two different shows, whatever their names.
        if imdb != nil, o.imdb != nil { return false }
        guard !allNames.isDisjoint(with: o.allNames) else { return false }
        if let a = year, let b = o.year { return abs(a - b) <= 1 }
        return true
    }
}

// MARK: - Episode tiles

/// What a tracked show's episode tile says on a title page (1.22.1).
enum AiringMark: Equatable {
    /// Out in the last week, and the newest out.
    case new
    /// Not out yet: when it airs, and the network's date when the hour
    /// isn't known (AiringEpisode.day).
    case airs(Date, day: String? = nil)
}

/// A tracked show's schedule as a title page's episode tiles use it: "New"
/// on the episode just out, when it airs on the ones not out yet. From the
/// schedule the tracker already keeps: no request per tile.
struct EpisodeAiring: Equatable {
    /// An episode is "New" for its first week (or until the next one is out).
    static let newFor: TimeInterval = 7 * 86400

    /// Not out yet, soonest first.
    let upcoming: [AiringEpisode]
    /// Out most recently, while it's new.
    let justOut: AiringEpisode?
    /// The season the schedule means when it numbers episodes without one
    /// (AniList has an entry per season): the tracked season, else the
    /// page's newest.
    let season: Int?

    init(show: TrackedShow, now: Date, newestSeason: Int?) {
        let s = show.schedule
        upcoming = s.filter { $0.airDate! > now }
        justOut = s.last { $0.airDate! <= now }.flatMap { now.timeIntervalSince($0.airDate!) < Self.newFor ? $0 : nil }
        season = show.season ?? newestSeason
    }

    /// The mark for the page's episode `episode` of `season`, if it has one.
    func mark(season s: Int?, episode n: Int?) -> AiringMark? {
        guard let n else { return nil }
        if let e = upcoming.first(where: { matches($0, s, n) }) { return .airs(e.airDate!, day: e.day) }
        if let e = justOut, matches(e, s, n) { return .new }
        return nil
    }

    /// The episodes not out yet that the page has no tile for, under the
    /// season it shows: that season's, and a season the page doesn't have
    /// yet under its newest. At most `limit`.
    func untiled(shown: Int?, seasons: [Int], episodes: [Int], limit: Int = 3) -> [AiringEpisode] {
        let newest = seasons.max()
        return Array(upcoming.filter { e in
            let es = e.season ?? season
            if let es, let shown, es != shown {
                guard !seasons.contains(es), shown == newest else { return false }
                return true
            }
            return e.number.map { !episodes.contains($0) } ?? true
        }.prefix(limit))
    }

    private func matches(_ e: AiringEpisode, _ s: Int?, _ n: Int) -> Bool {
        guard e.number == n else { return false }
        // When either side doesn't know the season, the number decides.
        guard let es = e.season ?? season, let s else { return true }
        return es == s
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
    static func of(_ show: TrackedShow, now: Date, calendar: Calendar = .autoupdatingCurrent) -> AiringGroup {
        guard let d = show.headline(at: now)?.airDate else { return .other }
        if d <= now || calendar.isDate(d, inSameDayAs: now) { return .today }
        if let end = calendar.date(byAdding: .day, value: 8, to: calendar.startOfDay(for: now)), d < end { return .week }
        return .later
    }

    /// The groups that have shows, each soonest first (the last by name).
    static func grouped(_ shows: [TrackedShow], now: Date, calendar: Calendar = .autoupdatingCurrent) -> [AiringSection] {
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
