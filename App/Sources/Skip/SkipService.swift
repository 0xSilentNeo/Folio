import Foundation
import UIKit

struct SkipSegment: Identifiable, Hashable {
    enum Kind: String { case recap, intro, outro, preview

        var label: String {
            switch self {
            case .recap: return "Skip Recap"
            case .intro: return "Skip Intro"
            case .outro: return "Skip Outro"
            case .preview: return "Skip Preview"
            }
        }
        var chapterTitle: String {
            switch self {
            case .recap: return "Recap"
            case .intro: return "Opening"
            case .outro: return "Ending"
            case .preview: return "Preview"
            }
        }
    }
    var id: String { "\(kind.rawValue)-\(start)" }
    var kind: Kind
    var start: Double
    var end: Double
    let source: String
    /// What the pill calls it: the file's own chapter name when it has a real
    /// one ("Opening", "Next Episode Preview"), else set by `SkipService.tidy`.
    var name: String? = nil

    var label: String {
        if let name { return "Skip " + name }
        if kind == .outro, source == "IntroDB" || source == "TheIntroDB" { return "Skip Credits" }
        return kind.label
    }
}

/// What the online lookup found for one file.
struct SkipLookup {
    var segments: [SkipSegment] = []
    /// A scene follows the credits (IntroDB `post_credits`): Up Next must not auto-play.
    var postCredits = false
}

/// Finds intro/credits/recap/preview ranges:
///   1. chapters already in the file (named Opening/OP/Ending/ED/Credits...)
///   2. TV & films: IntroDB.app, then TheIntroDB.org — community databases
///      keyed by IMDb id + season/episode
///   3. Anime: AniSkip (start AND end; MyAnimeList id), then Open Anime
///      Timestamps (start times only; AniDB id). IDs come from the item's
///      hint or an AniList search, never for titles that aren't animation.
actor SkipService {
    static let shared = SkipService()

    private var oatCache: [String: Any]?
    private var oatFetched: Date?
    private var oatFailed: Date?
    private var idCache: [String: (hint: AnimeHint, at: Date)] = [:]
    /// An empty answer may just mean a service was offline: it is asked
    /// again after this long. Real answers are kept for the session.
    private let missTTL: TimeInterval = 600
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()

    // MARK: Chapters

    static func segments(fromChapters chapters: [(title: String, time: Double)], duration: Double) -> [SkipSegment] {
        var out: [SkipSegment] = []
        for (i, ch) in chapters.enumerated() {
            let t = ch.title.lowercased().trimmingCharacters(in: .whitespaces)
            let end = i + 1 < chapters.count ? chapters[i + 1].time : duration
            guard end > ch.time else { continue }
            let kind: SkipSegment.Kind?
            // A post-, mid- or after-credits scene is the film, not its
            // credits: never an outro to skip (review, 5 Nov).
            if t.range(of: #"\b(post|mid|after)[- ]?credits?\b"#, options: .regularExpression) != nil {
                kind = nil
            } else if t.range(of: #"^(op|opening|intro|oped)\b|^opening|\bopening\b|^op\s?\d|^intro"#, options: .regularExpression) != nil {
                kind = .intro
            } else if t.range(of: #"^(ed|ending|outro|credits)\b|^ending|\bending\b|^ed\s?\d|credits"#, options: .regularExpression) != nil {
                kind = .outro
            } else if t.range(of: #"recap|previously"#, options: .regularExpression) != nil {
                kind = .recap
            } else if t.range(of: #"preview|next episode|^pv\b"#, options: .regularExpression) != nil {
                kind = .preview
            } else {
                kind = nil
            }
            if let kind { out.append(SkipSegment(kind: kind, start: ch.time, end: end, source: "Chapters")) }
        }
        return out
    }

    /// Makes the segments from any source agree with where they sit and with
    /// the file's chapters, and names each one for the Skip pill.
    ///
    /// - An "intro" in the last 40% is the ending (anime episode 1s often
    ///   play the opening song over the end credits; IntroDB then reports
    ///   intro 1345–1435 AND outro 1345–1438 for Classroom of the Elite S1E1,
    ///   and the pill said "Skip Intro" over the credits).
    /// - Segments covering the same stretch are merged into one.
    /// - Name: the file's chapter starting at the same moment, if its title
    ///   says what it is ("Opening", "Ending", "Preview"…); generic titles
    ///   ("Chapter 4") don't count. Otherwise Opening/Ending for anime,
    ///   Intro/Credits for everything else.
    static func tidy(_ input: [SkipSegment], duration: Double, chapters: [(title: String, time: Double)], anime: Bool) -> [SkipSegment] {
        guard duration > 0 else { return input }
        var segs = input.map { seg -> SkipSegment in
            var s = seg
            if s.kind == .intro, s.start >= duration * 0.6 { s.kind = .outro }
            if s.kind == .outro, s.end <= duration * 0.35 { s.kind = .intro }
            return s
        }.sorted { $0.start < $1.start }
        // Merge overlapping segments of the same kind (or any two that mostly overlap).
        var merged: [SkipSegment] = []
        for s in segs {
            if var last = merged.last {
                let overlap = min(last.end, s.end) - max(last.start, s.start)
                let shorter = min(last.end - last.start, s.end - s.start)
                if overlap > 0, last.kind == s.kind || overlap > shorter * 0.5 {
                    last.end = max(last.end, s.end)
                    if s.kind == .outro { last.kind = .outro }
                    merged[merged.count - 1] = last
                    continue
                }
            }
            merged.append(s)
        }
        segs = merged
        for i in segs.indices {
            if let ch = chapters.first(where: { abs($0.time - segs[i].start) < 4 }), let n = meaningfulName(ch.title) {
                segs[i].name = n
            } else {
                switch segs[i].kind {
                case .intro: segs[i].name = anime ? "Opening" : "Intro"
                case .outro: segs[i].name = anime ? "Ending" : "Credits"
                case .recap: segs[i].name = "Recap"
                case .preview: segs[i].name = "Preview"
                }
            }
        }
        return segs
    }

    /// A chapter title worth showing on the pill: one that names a skippable
    /// part. "OP"/"ED" are spelled out; "Chapter 4", "Part B", "00:22:26" are not names.
    static func meaningfulName(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 32 else { return nil }
        let low = t.lowercased()
        if low.range(of: #"^(chapter|chap\.?|ch\.?|kapitel|chapitre|cap[ií]tulo|episode|part|teil)\s*[0-9a-z]?\d*$"#, options: .regularExpression) != nil { return nil }
        if low.range(of: #"^[\d:.\s]+$"#, options: .regularExpression) != nil { return nil }
        let segs = segments(fromChapters: [(t, 0), ("x", 10)], duration: 20)
        guard let kind = segs.first?.kind else { return nil }
        if low.range(of: #"^(op|ed|oped|pv)\s?\d*$"#, options: .regularExpression) != nil { return kind.chapterTitle }
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    // MARK: TV & films (IntroDB, TheIntroDB)

    /// `complete`: both services answered (an answer of "nothing" counts);
    /// a lookup one of them failed is asked again sooner (1.30.4).
    private var tvCache: [String: (lookup: SkipLookup, at: Date, complete: Bool)] = [:]
    /// How long a lookup one service failed is kept before both are asked again.
    private let partialTTL: TimeInterval = 60

    /// Both services are asked at once. They used to be asked one after the
    /// other, and IntroDB running into its 15 s timeout held the Skip button
    /// back until 15.5 s into each episode (29 Oct log: four episodes in a
    /// row, the segments 15.5 s after the file loaded). IntroDB is preferred
    /// (merge): each kind of segment it has is its own.
    ///
    /// 1.30.4: the slower one is no longer cut off. Until then the lookup
    /// ended 2 s after TheIntroDB's answer and cancelled IntroDB's request,
    /// without a word in the log; 14 Nov, Tulsa King S01E07: TheIntroDB had
    /// only the credits, and the recap and intro IntroDB had for every other
    /// episode never came (and that answer was kept for the session). Now
    /// the first usable answer goes to `early` (IntroDB's at once, or
    /// TheIntroDB's when IntroDB hasn't answered 2 s later), and the result
    /// returned is both merged, once both have answered or failed.
    func lookupTV(imdbId: String, season: Int?, episode: Int?, duration: Double,
                  early: (@Sendable (SkipLookup) async -> Void)? = nil) async -> SkipLookup {
        let key = "\(imdbId)|\(season ?? -1)|\(episode ?? -1)"
        if let c = tvCache[key] {
            let age = Date().timeIntervalSince(c.at)
            let keep = c.complete ? (!c.lookup.segments.isEmpty || c.lookup.postCredits || age < missTTL) : age < partialTTL
            if keep { return c.lookup }
        }
        let label = "\(imdbId) s\(season ?? 0)e\(episode ?? 0)"
        // nil: the service didn't answer (logged by fetch with the reason).
        enum Answer { case introDB(SkipLookup?), theIntroDB(SkipLookup?), graceOver }
        let r: (lookup: SkipLookup, complete: Bool) = await withTaskGroup(of: Answer.self) { g in
            g.addTask { .introDB(await self.introDB(imdbId: imdbId, season: season, episode: episode, duration: duration)) }
            g.addTask { .theIntroDB(await self.theIntroDB(imdbId: imdbId, season: season, episode: episode, duration: duration)) }
            var intro: SkipLookup?, the: SkipLookup?
            var introDone = false, theDone = false, shown = false
            while let answer = await g.next() {
                switch answer {
                case .introDB(let res):
                    introDone = true
                    intro = res
                    if let res, !res.segments.isEmpty, !theDone, !shown, let early {
                        shown = true
                        await early(res)
                    }
                case .theIntroDB(let res):
                    theDone = true
                    the = res
                    if let res, !res.segments.isEmpty, !introDone {
                        g.addTask { try? await Task.sleep(nanoseconds: 2_000_000_000); return .graceOver }
                    }
                case .graceOver:
                    if !introDone, !shown, let t = the, !t.segments.isEmpty, let early {
                        shown = true
                        dlog("skip", "IntroDB hasn't answered for \(label) 2 s after TheIntroDB: TheIntroDB's segments for now, IntroDB's added when it answers")
                        await early(t)
                    }
                }
                // Both in: only the grace timer may be left, and it ends now.
                if introDone && theDone { g.cancelAll() }
            }
            if intro == nil || the == nil {
                dlog("skip", "\(intro == nil ? "IntroDB" : "TheIntroDB") gave no answer for \(label)\(intro == nil && the == nil ? ", nor did TheIntroDB" : ""): asked again in \(Int(partialTTL)) s")
            }
            return (Self.merge(preferred: intro ?? SkipLookup(), other: the ?? SkipLookup()), intro != nil && the != nil)
        }
        tvCache[key] = (r.lookup, Date(), r.complete)
        return r.lookup
    }

    /// Two databases' answers for one episode as one (1.30.4): `preferred`
    /// gives every kind of segment it has, and its post-credits scene; the
    /// other adds the kinds it lacks, unless one overlaps a preferred
    /// segment (they disagree on where the credits and a preview sit: S01E02,
    /// TheIntroDB "preview 2174-2205", IntroDB "outro 2190-2223").
    static func merge(preferred: SkipLookup, other: SkipLookup) -> SkipLookup {
        var out = preferred
        let kinds = Set(preferred.segments.map(\.kind))
        for s in other.segments where !kinds.contains(s.kind) {
            let overlaps = preferred.segments.contains { min($0.end, s.end) - max($0.start, s.start) > 0 }
            if !overlaps { out.segments.append(s) }
        }
        out.segments.sort { $0.start < $1.start }
        out.postCredits = preferred.postCredits
        return out
    }

    /// nil when IntroDB didn't answer; an empty lookup when it has nothing.
    private func introDB(imdbId: String, season: Int?, episode: Int?, duration: Double) async -> SkipLookup? {
        var c = URLComponents(string: "https://api.introdb.app/segments")!
        c.queryItems = [URLQueryItem(name: "imdb_id", value: imdbId)]
        if let episode {
            c.queryItems! += [URLQueryItem(name: "season", value: String(season ?? 1)), URLQueryItem(name: "episode", value: String(episode))]
        } else {
            c.queryItems!.append(URLQueryItem(name: "is_movie", value: "true"))
        }
        guard let url = c.url else { return nil }
        let obj: [String: Any]
        switch await fetch(url) {
        case .failed: return nil
        case .missing:
            dlog("skip", "IntroDB \(imdbId) s\(season ?? 0)e\(episode ?? 0): nothing for it")
            return SkipLookup()
        case .object(let o): obj = o as? [String: Any] ?? [:]
        }
        func seg(_ k: String) -> (Double, Double?)? {
            guard let o = obj[k] as? [String: Any] else { return nil }
            let s = (o["start_sec"] as? NSNumber)?.doubleValue ?? (o["start_ms"] as? NSNumber).map { $0.doubleValue / 1000 }
            let e = (o["end_sec"] as? NSNumber)?.doubleValue ?? (o["end_ms"] as? NSNumber).map { $0.doubleValue / 1000 }
            guard let s else { return nil }
            return (s, e)
        }
        var out = SkipLookup()
        let map: [(String, SkipSegment.Kind)] = [("recap", .recap), ("intro", .intro), ("outro", .outro)]
        for (k, kind) in map {
            guard let (s, e) = seg(k) else { continue }
            let end = min(e ?? duration, duration > 0 ? duration : .greatestFiniteMagnitude)
            if end > s { out.segments.append(SkipSegment(kind: kind, start: s, end: end, source: "IntroDB")) }
        }
        out.postCredits = seg("post_credits") != nil
        out.segments.sort { $0.start < $1.start }
        dlog("skip", "IntroDB \(imdbId) s\(season ?? 0)e\(episode ?? 0): \(out.segments.map { "\($0.kind.rawValue) \(Int($0.start))-\(Int($0.end))" }) postCredits=\(out.postCredits)")
        return out
    }

    /// nil when TheIntroDB didn't answer; an empty lookup when it has nothing.
    private func theIntroDB(imdbId: String, season: Int?, episode: Int?, duration: Double) async -> SkipLookup? {
        var c = URLComponents(string: "https://api.theintrodb.org/v3/media")!
        c.queryItems = [URLQueryItem(name: "imdb_id", value: imdbId)]
        if let episode { c.queryItems! += [URLQueryItem(name: "season", value: String(season ?? 1)), URLQueryItem(name: "episode", value: String(episode))] }
        if duration > 0 { c.queryItems!.append(URLQueryItem(name: "duration_ms", value: String(Int(duration * 1000)))) }
        guard let url = c.url else { return nil }
        let obj: [String: Any]
        switch await fetch(url) {
        case .failed: return nil
        case .missing:
            dlog("skip", "TheIntroDB \(imdbId) s\(season ?? 0)e\(episode ?? 0): nothing for it")
            return SkipLookup()
        case .object(let o): obj = o as? [String: Any] ?? [:]
        }
        var out = SkipLookup()
        let map: [(String, SkipSegment.Kind)] = [("recap", .recap), ("intro", .intro), ("credits", .outro), ("preview", .preview)]
        for (k, kind) in map {
            for o in (obj[k] as? [[String: Any]]) ?? [] {
                let sMs = (o["start_ms"] as? NSNumber)?.doubleValue ?? 0
                let eMs = (o["end_ms"] as? NSNumber)?.doubleValue ?? 0
                if sMs == 0 && eMs == 0 { continue }                    // "no segment"
                let start = sMs / 1000
                var end = eMs > 0 ? eMs / 1000 : duration               // null end = end of the file
                if duration > 0 { end = min(end, duration) }
                if end > start { out.segments.append(SkipSegment(kind: kind, start: start, end: end, source: "TheIntroDB")) }
            }
        }
        out.segments.sort { $0.start < $1.start }
        dlog("skip", "TheIntroDB \(imdbId) s\(season ?? 0)e\(episode ?? 0): \(out.segments.map { "\($0.kind.rawValue) \(Int($0.start))-\(Int($0.end))" })")
        return out
    }

    // MARK: Anime (AniSkip, Open Anime Timestamps)

    func lookup(hint: AnimeHint, season: Int? = nil, duration: Double, oatLength: Double) async -> [SkipSegment] {
        guard let episode = hint.episode, episode > 0 else { return [] }
        var h = hint
        // Later seasons are separate MyAnimeList entries: search for that
        // season's entry and refuse a match that isn't clearly it (season 1's
        // times on a season 2 episode would be wrong).
        if let season, season > 1, h.malId == nil, h.anilistId == nil, h.kitsuId == nil, let t = h.title {
            let found = await aniListSearch("\(t) Season \(season)", requireSeason: season)
            guard case .match(let al, let mal) = found else { return [] }
            h.anilistId = al; h.malId = mal
        }
        let ids = await resolveIDs(h).ids
        if let mal = ids.malId {
            let s = await aniSkip(malId: mal, episode: episode, duration: duration)
            if !s.isEmpty { return s }
        }
        if let anidb = ids.anidbId {
            let s = await oat(anidbId: anidb, episode: episode, duration: duration, length: oatLength)
            if !s.isEmpty { return s }
        }
        return []
    }

    /// What the sync services get from the id lookup (1.30.4): ids, an
    /// answer of none, or no answer at all (offline, AniList's rate limit,
    /// ids.moe down). Until then both of the last were nil, and a scrobble
    /// whose lookup wasn't answered was skipped as "not found".
    enum AnimeIDLookup: Sendable, Equatable { case found(AnimeHint), notFound, unreachable }

    /// An anime's AniList and MyAnimeList ids for its season, as the skip
    /// lookup finds them (1.26.0: the sync services use the same answer,
    /// from the same cache). A later season must be found as itself.
    func animeIDLookup(_ hint: AnimeHint, season: Int?) async -> AnimeIDLookup {
        var h = hint
        if let season, season > 1, h.malId == nil, h.anilistId == nil, h.kitsuId == nil, let t = h.title {
            switch await aniListSearch("\(t) Season \(season)", requireSeason: season) {
            case .match(let al, let mal): h.anilistId = al; h.malId = mal
            case .noMatch: return .notFound
            case .noAnswer: return .unreachable
            }
        }
        let r = await resolveIDs(h)
        return Self.idLookup(r.ids, failed: r.failed)
    }

    /// The ids only, nil for "not found" and "not reached" alike.
    func animeIDs(_ hint: AnimeHint, season: Int?) async -> AnimeHint? {
        let r = await animeIDLookup(hint, season: season)
        if case .found(let ids) = r { return ids }
        return nil
    }

    /// The lookups' answers as one (1.30.4): an AniList or MyAnimeList id is
    /// found however the rest went; none, with a service unanswered, is
    /// "not reached", not "not found".
    static func idLookup(_ ids: AnimeHint, failed: Bool) -> AnimeIDLookup {
        if ids.anilistId != nil || ids.malId != nil { return .found(ids) }
        return failed ? .unreachable : .notFound
    }

    /// `failed`: AniList or ids.moe gave no answer (offline, 429, 5xx).
    private func resolveIDs(_ hint: AnimeHint) async -> (ids: AnimeHint, failed: Bool) {
        var h = hint
        if h.malId != nil && h.anidbId != nil { return (h, false) }
        let key = "\(h.anilistId ?? 0)|\(h.kitsuId ?? 0)|\(h.malId ?? 0)|\(h.title ?? "")"
        if let c = idCache[key], c.hint.malId != nil || c.hint.anidbId != nil || Date().timeIntervalSince(c.at) < missTTL {
            return (c.hint, false)
        }

        var failed = false
        if h.anilistId == nil && h.kitsuId == nil && h.malId == nil, let title = h.title, !title.isEmpty {
            switch await aniListSearch(title) {
            case .match(let al, let mal):
                h.anilistId = al
                h.malId = h.malId ?? mal
            case .noMatch: break
            case .noAnswer: failed = true
            }
        }
        // ids.moe fills in AniDB (and MAL if missing).
        var path: String?
        if let al = h.anilistId { path = "anilist/\(al)" }
        else if let k = h.kitsuId { path = "kitsu/\(k)" }
        else if let m = h.malId { path = "myanimelist/\(m)" }
        if let path, let url = URL(string: "https://ids.moe/\(path)") {
            switch await fetch(url) {
            case .object(let o):
                let obj = o as? [String: Any] ?? [:]
                if h.anidbId == nil { h.anidbId = obj["anidb"] as? Int }
                if h.malId == nil { h.malId = obj["myanimelist"] as? Int }
                if h.anilistId == nil { h.anilistId = obj["anilist"] as? Int }
            case .missing: dlog("skip", "ids.moe has nothing for \(path) (HTTP 404)")
            case .failed(let transient): if transient { failed = true }
            }
        }
        // Not kept when a service didn't answer (1.30.4): a miss was kept
        // 10 minutes, and the scrobble asking again in that time was skipped.
        if !failed { idCache[key] = (h, Date()) }
        return (h, failed)
    }

    /// AniList's answer to a search (1.30.4): no answer (offline, 429, 5xx) isn't "no match".
    private enum AniListMatch { case match(Int, Int?), noMatch, noAnswer }

    private func aniListSearch(_ title: String, requireSeason: Int? = nil) async -> AniListMatch {
        guard let url = URL(string: "https://graphql.anilist.co") else { return .noMatch }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "query": "query($s:String){Media(search:$s,type:ANIME){id idMal title{romaji english}}}",
            "variables": ["s": title],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        // Through fetch (1.30.4): a 429 or no network was an empty answer.
        let obj: [String: Any]
        switch await fetch(req) {
        case .object(let o): obj = o as? [String: Any] ?? [:]
        case .missing: return .noMatch          // AniList's "Not Found." is HTTP 404
        case .failed(let transient): return transient ? .noAnswer : .noMatch
        }
        guard let media = (obj["data"] as? [String: Any])?["Media"] as? [String: Any],
              let id = media["id"] as? Int else { return .noMatch }
        if let n = requireSeason {
            let titles = ((media["title"] as? [String: Any]) ?? [:]).values.compactMap { ($0 as? String)?.lowercased() }
            let roman = ["", "", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix"]
            let ordinal = "\(n)" + ((11...13).contains(n % 100) ? "th" : ["th", "st", "nd", "rd", "th", "th", "th", "th", "th", "th"][n % 10])
            let marks = ["season \(n)", "\(ordinal) season", ordinal, n < roman.count ? roman[n] : "", "\(n)"].filter { !$0.isEmpty }
            // Whole words only: "ii" is not "iii", "season 2" is not "season 20".
            func has(_ t: String, _ mark: String) -> Bool {
                t.range(of: "(?<![a-z0-9])" + NSRegularExpression.escapedPattern(for: mark) + "(?![a-z0-9])", options: .regularExpression) != nil
            }
            guard titles.contains(where: { t in marks.contains { has(t, $0) } }) else {
                dlog("skip", "AniList: no confident match for \(title)")
                return .noMatch
            }
        }
        return .match(id, media["idMal"] as? Int)
    }

    private func aniSkip(malId: Int, episode: Int, duration: Double) async -> [SkipSegment] {
        var comps = URLComponents(string: "https://api.aniskip.com/v2/skip-times/\(malId)/\(episode)")!
        comps.queryItems = ["op", "ed", "recap", "mixed-op", "mixed-ed"].map { URLQueryItem(name: "types[]", value: $0) }
            + [URLQueryItem(name: "episodeLength", value: String(Int(duration.rounded())))]
        guard let url = comps.url, let obj = await json(url) as? [String: Any],
              (obj["found"] as? Bool) == true,
              let results = obj["results"] as? [[String: Any]] else { return [] }
        var out: [SkipSegment] = []
        for r in results {
            guard let iv = r["interval"] as? [String: Any],
                  let s = (iv["startTime"] as? NSNumber)?.doubleValue,
                  let e = (iv["endTime"] as? NSNumber)?.doubleValue,
                  let type = r["skipType"] as? String else { continue }
            var start = s, end = e
            // Rescale if AniSkip's episode length differs noticeably.
            if let len = (r["episodeLength"] as? NSNumber)?.doubleValue, len > 0, duration > 0, abs(len - duration) > 3 {
                let k = duration / len
                start *= k; end *= k
            }
            let kind: SkipSegment.Kind
            switch type {
            case "op", "mixed-op": kind = .intro
            case "ed", "mixed-ed": kind = .outro
            case "recap": kind = .recap
            default: continue
            }
            out.append(SkipSegment(kind: kind, start: start, end: end, source: "AniSkip"))
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Open Anime Timestamps' whole file, parsed, stays in memory for a day
    /// (1.30.2): given back when iOS says memory is short, and downloaded
    /// again by the next anime episode that needs it.
    private static let watchMemory: Void = {
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in
            Task { await SkipService.shared.releaseTimestamps() }
        }
    }()

    private func releaseTimestamps() {
        guard oatCache != nil else { return }
        oatCache = nil
        oatFetched = nil
        dlog("skip", "memory warning: Open Anime Timestamps' list let go")
    }

    private func oat(anidbId: Int, episode: Int, duration: Double, length: Double) async -> [SkipSegment] {
        _ = Self.watchMemory
        if oatCache == nil || (oatFetched.map { Date().timeIntervalSince($0) > 86400 } ?? true) {
            // The file is large: after a failed download it's tried again in
            // 10 minutes, not for every episode (an older copy is still used).
            if let failed = oatFailed, Date().timeIntervalSince(failed) < missTTL {
                if oatCache == nil { return [] }
            } else if let url = URL(string: "https://raw.githubusercontent.com/jonbarrow/open-anime-timestamps/master/timestamps.json"),
                      let obj = await json(url, timeout: 60) as? [String: Any] {
                oatCache = obj
                oatFetched = Date()
                oatFailed = nil
            } else {
                oatFailed = Date()
                if oatCache == nil { return [] }
            }
        }
        guard let entries = oatCache?[String(anidbId)] as? [[String: Any]] else { return [] }
        // Merge all sources for this episode, first valid value wins.
        var recap = -1.0, op = -1.0, ed = -1.0, pv = -1.0
        for e in entries where (e["episode_number"] as? NSNumber)?.intValue == episode {
            func v(_ k: String) -> Double { (e[k] as? NSNumber)?.doubleValue ?? -1 }
            if recap < 0 { recap = v("recap_start") }
            if op < 0 { op = v("opening_start") }
            if ed < 0 { ed = v("ending_start") }
            if pv < 0 { pv = v("preview_start") }
        }
        let marks = [recap, op, ed, pv].filter { $0 >= 0 }.sorted()
        func next(after t: Double) -> Double { marks.first { $0 > t } ?? (duration > 0 ? duration : t + length) }
        var out: [SkipSegment] = []
        if recap >= 0 { out.append(SkipSegment(kind: .recap, start: recap, end: next(after: recap), source: "OAT")) }
        if op >= 0 { out.append(SkipSegment(kind: .intro, start: op, end: min(op + length, next(after: op)), source: "OAT")) }
        if ed >= 0 { out.append(SkipSegment(kind: .outro, start: ed, end: min(ed + length, next(after: ed)), source: "OAT")) }
        if pv >= 0, duration > pv { out.append(SkipSegment(kind: .preview, start: pv, end: duration, source: "OAT")) }
        return out.filter { $0.end > $0.start }
    }

    private func json(_ url: URL, timeout: TimeInterval = 15) async -> Any? {
        switch await fetch(url, timeout: timeout) {
        case .object(let o): return o
        case .missing: dlog("skip", "\(url.host ?? "?") has nothing for it (HTTP 404)"); return nil
        case .failed: return nil
        }
    }

    /// What a service said (1.30.4): its JSON; "nothing for that" (HTTP 404);
    /// or no answer, logged with why. `transient`: worth asking again (no
    /// network, a timeout, 429, 5xx, a page that isn't JSON), not a refusal (400, 403).
    private enum Fetched { case object(Any), missing, failed(transient: Bool) }

    /// An HTTP status that says "not now" rather than "no" (1.30.4); 0 is no answer.
    static func failedForNow(status: Int) -> Bool {
        status == 0 || status == 408 || status == 429 || (500...599).contains(status)
    }

    private func fetch(_ url: URL, timeout: TimeInterval = 15) async -> Fetched {
        await fetch(URLRequest(url: url), timeout: timeout)
    }

    /// Any request (1.30.4: AniList's search is a POST).
    private func fetch(_ request: URLRequest, timeout: TimeInterval = 15) async -> Fetched {
        var req = request
        req.timeoutInterval = timeout
        req.setValue("Folio/1.0", forHTTPHeaderField: "User-Agent")
        let host = req.url?.host ?? "?"
        let t0 = CFAbsoluteTimeGetCurrent()
        func took() -> Int { Int((CFAbsoluteTimeGetCurrent() - t0) * 1000) }
        let result: (Data, URLResponse)
        do { result = try await session.data(for: req) } catch {
            // Said whatever it was (1.30.4): a cancelled request was left out
            // of the log, and that is how IntroDB's answers went missing.
            let why = (error as? URLError)?.code == .cancelled || error is CancellationError ? "cancelled" : error.localizedDescription
            dlog("skip", "\(host) didn't answer in \(took()) ms: \(why)")
            return .failed(transient: true)
        }
        let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return .missing }
        guard (200..<300).contains(status) else {
            dlog("skip", "\(host) answered HTTP \(status) in \(took()) ms")
            return .failed(transient: Self.failedForNow(status: status))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: result.0) else {
            dlog("skip", "\(host) answered in \(took()) ms with \(result.0.count) bytes that aren't JSON")
            return .failed(transient: true)
        }
        return .object(obj)
    }
}
