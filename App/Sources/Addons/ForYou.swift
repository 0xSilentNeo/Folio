import Foundation

/// Discover's "For you" row (1.20.3): titles like the ones you've watched.
///
/// - Seeds: up to 5 titles of the watch history that have an IMDb id,
///   Continue Watching first, then the rest by when they were played. An
///   addon's item has its own id; a library or WebDAV file has the IMDb id
///   of its release's saved confident match (ReleaseMatcher, as the history
///   linking check reads it), else of the library metadata (MetadataService,
///   looked up when the file was played and kept).
/// - Candidates: IMDb's "More like this" of each seed (from the title page,
///   kept 7 days with the title's details) and, with a TMDB key, TMDB's
///   recommendations (/find from the IMDb id, then /recommendations).
/// - Ranking: titles more seeds recommend first, then the more popular
///   (more ratings). Nothing already in the history is recommended.
///
/// The row is kept 12 hours and shown at once, stale, while a fresh one
/// loads; it is fetched only when Discover is open, a few seeds at a time.
enum ForYou {
    static let maxSeeds = 5
    static let rowSize = 20
    /// History titles (shows, not episodes) looked at: the seeds are the
    /// first of them with an IMDb id, and none of them is recommended.
    static let scanned = 20
    /// Seeds fetched at once (each is a title page and two TMDB requests).
    static let parallel = 3
    static let freshFor: TimeInterval = 12 * 3600

    /// A title from the history the row starts from. `type`: "movie",
    /// "series" or nil (not known; TMDB's /find then takes either).
    struct Seed: Hashable, Sendable {
        var id: String
        var type: String?
    }

    /// What the history gives: the seeds, and every IMDb title found in it.
    struct History: Equatable, Sendable {
        var seeds: [Seed] = []
        var watched: Set<String> = []
    }

    /// One title one seed recommends, from IMDb ("tt…") or TMDB ("tmdb:…").
    struct Candidate: Hashable, Sendable {
        var seed: String
        var meta: MetaItem
        /// How many people rated it (IMDb's count, or TMDB's): the popularity
        /// that orders titles as many seeds recommend.
        var votes: Int
    }

    /// A title of the row and why it's there.
    struct Pick: Hashable {
        var meta: MetaItem
        var seeds: Int
        var votes: Int
    }

    // MARK: - Seeds

    static func isIMDbID<S: StringProtocol>(_ s: S) -> Bool {
        s.count > 2 && s.hasPrefix("tt") && s.dropFirst(2).allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// An addon item's title: its meta id ("series|tt0944947|tt0944947:1:3"),
    /// else the video id in its history key ("addon:tt0816692"). Other ids
    /// (kitsu:…) have none.
    static func addonTitle(_ e: HistoryEntry) -> Seed? {
        if let ref = e.item.addonRef {
            let parts = ref.split(separator: "|", omittingEmptySubsequences: false)
            if parts.count >= 2, isIMDbID(parts[1]) {
                let type = parts[0] == "movie" || parts[0] == "series" ? String(parts[0]) : nil
                return Seed(id: String(parts[1]), type: type)
            }
        }
        guard let identity = TitleIdentity.fromAddonKey(e.id) else { return nil }
        let parts = identity.split(separator: ":")
        return Seed(id: String(parts[0]), type: parts.count > 1 ? "series" : "movie")
    }

    /// A library or WebDAV file's title, from what was found before and kept:
    /// the release's confident match (the folder's for a season pack), else
    /// the library metadata's answer for the file name.
    static func fileTitle(_ e: HistoryEntry) async -> Seed? {
        let name: String
        var folder: String?
        switch e.item.source {
        case .webdav:
            guard let u = URL(string: e.item.url) else { return nil }
            name = u.lastPathComponent.removingPercentEncoding ?? u.lastPathComponent
            let f = u.deletingLastPathComponent().lastPathComponent
            folder = f.removingPercentEncoding ?? f
        case .local:
            name = (e.item.url as NSString).lastPathComponent
        default:
            return nil
        }
        guard !name.isEmpty else { return nil }
        if let release = folder.flatMap({ ReleaseName.folder($0) }) ?? ReleaseName.file(name),
           let match = await ReleaseMatcher.shared.saved(release), match.confident, let tt = match.imdbID, isIMDbID(tt) {
            return Seed(id: tt, type: ReleaseMatch.kind(of: release).map { $0 == .movie ? "movie" : "series" })
        }
        if let meta = await MetadataService.shared.lookup(filename: name), isIMDbID(meta.id) {
            return Seed(id: meta.id, type: meta.type == "movie" ? "movie" : "series")
        }
        return nil
    }

    /// `shows`: one entry per show, Continue Watching first, then the history
    /// newest first. `all`: the whole history (every addon title in it is
    /// left out of the row; files only as far as `shows` goes, as each needs
    /// a lookup).
    static func history(_ shows: [HistoryEntry], all: [HistoryEntry],
                        file: (HistoryEntry) async -> Seed? = { await fileTitle($0) }) async -> History {
        var h = History()
        for e in all { if let s = addonTitle(e) { h.watched.insert(s.id) } }
        for e in shows.prefix(scanned) {
            var seed = addonTitle(e)
            if seed == nil { seed = await file(e) }
            guard let seed else { continue }
            h.watched.insert(seed.id)
            if h.seeds.count < maxSeeds, !h.seeds.contains(where: { $0.id == seed.id }) { h.seeds.append(seed) }
        }
        return h
    }

    // MARK: - Ranking

    /// TMDB's key for a TMDB title ("tmdb:603" or "tmdb:movie:603"): its ids
    /// are per kind, so the key has the kind ("tmdb:movie:603").
    static func tmdbKey(_ m: MetaItem) -> String? {
        guard m.id.hasPrefix("tmdb:"), let num = m.id.split(separator: ":").last else { return nil }
        return "tmdb:\(m.type == "movie" ? "movie" : "series"):\(num)"
    }

    private static func nameKey(_ name: String, type: String, year: Int) -> String {
        "\(type)|\(ReleaseMatch.norm(name))|\(year)"
    }

    /// Merges what every seed recommends, leaves out anything in `watched`
    /// (IMDb ids, and TMDB keys of the seeds themselves), and ranks: the
    /// titles more seeds recommend first, then the more rated, then as the
    /// seeds' lists had them.
    ///
    /// A TMDB title is the IMDb title it's known to be (`imdbIDs`, TMDB key →
    /// IMDb id), else the one with the same name, kind and year (a year
    /// apart too: a festival year against a release year); its tile is
    /// IMDb's then.
    static func rank(_ candidates: [Candidate], watched: Set<String>, imdbIDs: [String: String] = [:], limit: Int = rowSize) -> [Pick] {
        var byName: [String: String] = [:]
        for c in candidates where c.meta.id.hasPrefix("tt") {
            guard let year = c.meta.releaseInfo.flatMap({ Int($0.prefix(4)) }) else { continue }
            for n in [c.meta.name, c.meta.originalName].compactMap({ $0 }) where byName[nameKey(n, type: c.meta.type, year: year)] == nil {
                byName[nameKey(n, type: c.meta.type, year: year)] = c.meta.id
            }
        }
        func imdbID(_ c: Candidate) -> String? {
            if c.meta.id.hasPrefix("tt") { return c.meta.id }
            if let key = tmdbKey(c.meta), let tt = imdbIDs[key], isIMDbID(tt) { return tt }
            guard let year = c.meta.releaseInfo.flatMap({ Int($0.prefix(4)) }) else { return nil }
            for n in [c.meta.name, c.meta.originalName].compactMap({ $0 }) {
                for y in [year, year - 1, year + 1] {
                    if let tt = byName[nameKey(n, type: c.meta.type, year: y)] { return tt }
                }
            }
            return nil
        }

        struct Group { var meta: MetaItem; var seeds: Set<String>; var votes: Int; let order: Int; var fromIMDb: Bool }
        var groups: [String: Group] = [:]
        for (i, c) in candidates.enumerated() {
            let tt = imdbID(c)
            guard let key = tt ?? tmdbKey(c.meta) else { continue }
            if watched.contains(key) || tmdbKey(c.meta).map(watched.contains) == true { continue }
            let fromIMDb = c.meta.id.hasPrefix("tt")
            var meta = c.meta
            // A TMDB tile keeps its kind in its id: TMDB numbers films and
            // series apart, so "tmdb:100" can be either (the title page reads both).
            meta.id = tt ?? key
            meta.rank = nil
            if var g = groups[key] {
                g.seeds.insert(c.seed)
                g.votes = max(g.votes, c.votes)
                if fromIMDb && !g.fromIMDb {
                    // IMDb's tile over TMDB's (its name is in IMDb's language,
                    // like the rest of Discover); TMDB's poster if IMDb has none.
                    if meta.poster == nil { meta.poster = g.meta.poster }
                    g.meta = meta
                    g.fromIMDb = true
                }
                groups[key] = g
            } else {
                groups[key] = Group(meta: meta, seeds: [c.seed], votes: c.votes, order: i, fromIMDb: fromIMDb)
            }
        }
        let ranked = groups.values.sorted { a, b in
            if a.seeds.count != b.seeds.count { return a.seeds.count > b.seeds.count }
            if a.votes != b.votes { return a.votes > b.votes }
            return a.order < b.order
        }
        var ids = Set<String>()
        return ranked.filter { ids.insert($0.meta.id).inserted }.prefix(limit).map { Pick(meta: $0.meta, seeds: $0.seeds.count, votes: $0.votes) }
    }

    // MARK: - Fetching

    /// One seed's recommendations; `answered` false when neither IMDb nor
    /// TMDB could be reached.
    struct Fetched: Sendable {
        var candidates: [Candidate] = []
        /// The seed's own TMDB key: TMDB recommends nothing you've watched either.
        var seedTMDB: String?
        var answered = false
    }

    static func fetch(_ seed: Seed) async -> Fetched {
        async let imdb = IMDbSource.related(id: seed.id, type: seed.type ?? "movie")
        async let tmdb = tmdbRecommendations(seed)
        let fromIMDb = await imdb
        let fromTMDB = await tmdb
        var f = Fetched()
        f.answered = fromIMDb != nil || fromTMDB?.list != nil
        for r in fromIMDb ?? [] { f.candidates.append(Candidate(seed: seed.id, meta: r.meta, votes: r.votes ?? 0)) }
        if let t = fromTMDB {
            f.seedTMDB = "tmdb:\(t.isMovie ? "movie" : "series"):\(t.id)"
            for r in t.list ?? [] { f.candidates.append(Candidate(seed: seed.id, meta: r.meta, votes: r.votes)) }
        }
        let imdbNote = fromIMDb.map { "\($0.count) from IMDb" } ?? "IMDb didn't answer"
        let tmdbNote = fromTMDB.map { t in t.list.map { ", \($0.count) from TMDB" } ?? ", TMDB didn't answer" } ?? ""
        dlog("foryou", "\(seed.id): " + imdbNote + tmdbNote)
        return f
    }

    private static func tmdbRecommendations(_ seed: Seed) async -> (id: Int, isMovie: Bool, list: [TMDB.Recommendation]?)? {
        guard TMDB.enabled, let found = await TMDB.find(imdb: seed.id, type: seed.type) else { return nil }
        return (found.id, found.isMovie, await TMDB.recommendations(tmdb: found.id, isMovie: found.isMovie))
    }

    /// `work` for each item, at most `limit` at once; the answers in the items' order.
    static func each<T: Sendable, R: Sendable>(_ items: [T], limit: Int, _ work: @escaping @Sendable (T) async -> R) async -> [R] {
        await withTaskGroup(of: (Int, R).self) { group in
            var out = [R?](repeating: nil, count: items.count)
            var next = 0
            while next < min(limit, items.count) {
                let i = next, item = items[i]
                group.addTask { (i, await work(item)) }
                next += 1
            }
            while let r = await group.next() {
                out[r.0] = r.1
                if next < items.count {
                    let i = next, item = items[i]
                    group.addTask { (i, await work(item)) }
                    next += 1
                }
            }
            return out.compactMap { $0 }
        }
    }

    private struct TMDBRef: Sendable { let key: String; let id: Int; let isMovie: Bool }

    /// The row for the history's seeds, and the TMDB → IMDb ids now known;
    /// nil when no seed's lookups were answered (offline): the last row stays.
    static func build(_ history: History, known: [String: String]) async -> (metas: [MetaItem], imdbIDs: [String: String])? {
        let fetched = await each(history.seeds, limit: parallel) { await fetch($0) }
        guard fetched.contains(where: \.answered) else { return nil }
        var watched = history.watched
        for f in fetched { if let t = f.seedTMDB { watched.insert(t) } }
        let candidates = fetched.flatMap(\.candidates)
        let keys = Set(candidates.compactMap { tmdbKey($0.meta) })
        var ids = known.filter { keys.contains($0.key) }
        var picks = rank(candidates, watched: watched, imdbIDs: ids)
        // A TMDB title in the row that's matched to no IMDb one: its IMDb id,
        // so one you've watched (under another name) isn't recommended.
        let unknown = picks.compactMap { p -> TMDBRef? in
            guard let key = tmdbKey(p.meta), ids[key] == nil, let num = Int(key.split(separator: ":").last ?? "") else { return nil }
            return TMDBRef(key: key, id: num, isMovie: p.meta.type == "movie")
        }.prefix(10)
        if !unknown.isEmpty {
            let found = await each(Array(unknown), limit: 4) { ref in (ref.key, await TMDB.imdbID(tmdb: ref.id, isMovie: ref.isMovie)) }
            for (key, tt) in found { if let tt { ids[key] = tt } }
            dlog("foryou", "IMDb ids of \(found.filter { $0.1 != nil }.count) of \(found.count) TMDB title(s)")
            picks = rank(candidates, watched: watched, imdbIDs: ids)
        }
        dlog("foryou", "row: \(picks.count) title(s) from \(candidates.count) recommendation(s) of \(history.seeds.count) seed(s)"
             + (picks.first.map { "; first \($0.meta.id) (\($0.seeds) seed(s), \($0.votes) ratings)" } ?? ""))
        return (picks.map(\.meta), ids)
    }

    // MARK: - Saved row

    struct Saved: Codable {
        var date: Date
        var seeds: [String]
        var tmdb: Bool
        var metas: [MetaItem]
        /// TMDB titles' IMDb ids found so far (TMDB key → "tt…").
        var imdbIDs: [String: String]

        /// Fresh: under 12 hours old, for the same seeds and sources.
        func isFresh(for seeds: [Seed], tmdb: Bool, now: Date = Date()) -> Bool {
            now.timeIntervalSince(date) < ForYou.freshFor && Set(self.seeds) == Set(seeds.map(\.id)) && self.tmdb == tmdb
        }
    }

    private static var file: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("foryou.json")
    }
    static func saved() -> Saved? {
        guard let d = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: d)
    }
    static func save(_ s: Saved) {
        guard let d = try? JSONEncoder().encode(s) else { return }
        try? d.write(to: file, options: .atomic)
    }
}

/// The For you row's titles: the saved row at once, a fresh one when it's
/// older than 12 hours or the history's seeds changed. A newer load makes
/// an older one's answer stale (generation), and a load that reaches
/// nothing keeps the row it had.
@MainActor
final class ForYouModel: ObservableObject {
    @Published private(set) var metas: [MetaItem] = []
    /// The history has a title to start from: the row shows only then.
    @Published private(set) var hasSeeds = false
    @Published private(set) var loading = false
    private var generation = 0

    init() {
        // The last row, so it's there on the first frame (until the history says otherwise).
        if let saved = ForYou.saved(), !saved.seeds.isEmpty {
            metas = saved.metas
            hasSeeds = true
        }
    }

    /// Discover is open (`force`: pulled to refresh, the 12 hours don't count).
    func load(force: Bool = false) {
        guard !loading || force else { return }
        generation += 1
        let gen = generation
        loading = true
        let history = HistoryStore.shared
        var keys = Set<String>()
        var shows: [HistoryEntry] = []
        for e in history.continueWatching + history.recent {
            if shows.count >= ForYou.scanned { break }
            if keys.insert(HistoryStore.showKey(e)).inserted { shows.append(e) }
        }
        let all = history.entries
        Task {
            defer { if gen == generation { loading = false } }
            let found = await ForYou.history(shows, all: all)
            guard gen == generation else { return }
            hasSeeds = !found.seeds.isEmpty
            guard hasSeeds else {
                metas = []
                dlog("foryou", "no title in the history with an IMDb id: no row")
                return
            }
            let saved = ForYou.saved()
            if let saved { metas = saved.metas.filter { !found.watched.contains($0.id) } }
            let tmdb = TMDB.enabled
            if !force, let saved, saved.isFresh(for: found.seeds, tmdb: tmdb) { return }
            dlog("foryou", "loading for \(found.seeds.map(\.id).joined(separator: ", "))" + (saved == nil ? "" : " (showing the last row meanwhile)"))
            guard let row = await ForYou.build(found, known: saved?.imdbIDs ?? [:]) else {
                dlog("foryou", "nothing answered; the row keeps \(metas.count) title(s)")
                return
            }
            guard gen == generation else { return }
            metas = row.metas
            ForYou.save(ForYou.Saved(date: Date(), seeds: found.seeds.map(\.id), tmdb: tmdb, metas: row.metas, imdbIDs: row.imdbIDs))
        }
    }
}
