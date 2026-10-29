import Foundation

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
    private var idCache: [String: AnimeHint] = [:]
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
            if t.range(of: #"^(op|opening|intro|oped)\b|^opening|\bopening\b|^op\s?\d|^intro"#, options: .regularExpression) != nil {
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

    private var tvCache: [String: SkipLookup] = [:]

    /// Both services are asked at once. They used to be asked one after the
    /// other, and IntroDB running into its 15 s timeout held the Skip button
    /// back until 15.5 s into each episode (29 Oct log: four episodes in a
    /// row, the segments 15.5 s after the file loaded). IntroDB is still
    /// preferred: its answer wins when it comes within 2 s of TheIntroDB's.
    func lookupTV(imdbId: String, season: Int?, episode: Int?, duration: Double) async -> SkipLookup {
        let key = "\(imdbId)|\(season ?? -1)|\(episode ?? -1)"
        if let c = tvCache[key] { return c }
        enum Answer { case introDB(SkipLookup), theIntroDB(SkipLookup), graceOver }
        let r: SkipLookup = await withTaskGroup(of: Answer.self) { g in
            g.addTask { .introDB(await self.introDB(imdbId: imdbId, season: season, episode: episode, duration: duration)) }
            g.addTask { .theIntroDB(await self.theIntroDB(imdbId: imdbId, season: season, episode: episode, duration: duration)) }
            var fallback: SkipLookup?
            var postCredits = false
            var introDone = false
            var chosen: SkipLookup?
            while chosen == nil, let answer = await g.next() {
                switch answer {
                case .introDB(let res):
                    introDone = true
                    postCredits = res.postCredits
                    if !res.segments.isEmpty { chosen = res } else if let f = fallback { chosen = f }
                case .theIntroDB(let res):
                    guard !res.segments.isEmpty else { continue }
                    if introDone { chosen = res; break }
                    fallback = res
                    g.addTask { try? await Task.sleep(nanoseconds: 2_000_000_000); return .graceOver }
                case .graceOver:
                    chosen = fallback
                }
            }
            g.cancelAll()
            var out = chosen ?? fallback ?? SkipLookup()
            out.postCredits = postCredits
            return out
        }
        tvCache[key] = r
        return r
    }

    private func introDB(imdbId: String, season: Int?, episode: Int?, duration: Double) async -> SkipLookup {
        var c = URLComponents(string: "https://api.introdb.app/segments")!
        c.queryItems = [URLQueryItem(name: "imdb_id", value: imdbId)]
        if let episode {
            c.queryItems! += [URLQueryItem(name: "season", value: String(season ?? 1)), URLQueryItem(name: "episode", value: String(episode))]
        } else {
            c.queryItems!.append(URLQueryItem(name: "is_movie", value: "true"))
        }
        guard let url = c.url, let obj = await json(url) as? [String: Any] else { return SkipLookup() }
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

    private func theIntroDB(imdbId: String, season: Int?, episode: Int?, duration: Double) async -> SkipLookup {
        var c = URLComponents(string: "https://api.theintrodb.org/v3/media")!
        c.queryItems = [URLQueryItem(name: "imdb_id", value: imdbId)]
        if let episode { c.queryItems! += [URLQueryItem(name: "season", value: String(season ?? 1)), URLQueryItem(name: "episode", value: String(episode))] }
        if duration > 0 { c.queryItems!.append(URLQueryItem(name: "duration_ms", value: String(Int(duration * 1000)))) }
        guard let url = c.url, let obj = await json(url) as? [String: Any] else { return SkipLookup() }
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
            guard let found = await aniListSearch("\(t) Season \(season)", requireSeason: season) else { return [] }
            h.anilistId = found.0; h.malId = found.1
        }
        let ids = await resolveIDs(h)
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

    private func resolveIDs(_ hint: AnimeHint) async -> AnimeHint {
        var h = hint
        if h.malId != nil && h.anidbId != nil { return h }
        let key = "\(h.anilistId ?? 0)|\(h.kitsuId ?? 0)|\(h.malId ?? 0)|\(h.title ?? "")"
        if let cached = idCache[key] { return cached }

        if h.anilistId == nil && h.kitsuId == nil && h.malId == nil, let title = h.title, !title.isEmpty {
            if let found = await aniListSearch(title) {
                h.anilistId = found.0
                h.malId = h.malId ?? found.1
            }
        }
        // ids.moe fills in AniDB (and MAL if missing).
        var path: String?
        if let al = h.anilistId { path = "anilist/\(al)" }
        else if let k = h.kitsuId { path = "kitsu/\(k)" }
        else if let m = h.malId { path = "myanimelist/\(m)" }
        if let path, let url = URL(string: "https://ids.moe/\(path)"),
           let obj = await json(url) as? [String: Any] {
            if h.anidbId == nil { h.anidbId = obj["anidb"] as? Int }
            if h.malId == nil { h.malId = obj["myanimelist"] as? Int }
            if h.anilistId == nil { h.anilistId = obj["anilist"] as? Int }
        }
        idCache[key] = h
        return h
    }

    private func aniListSearch(_ title: String, requireSeason: Int? = nil) async -> (Int, Int?)? {
        guard let url = URL(string: "https://graphql.anilist.co") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "query": "query($s:String){Media(search:$s,type:ANIME){id idMal title{romaji english}}}",
            "variables": ["s": title],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let result = try? await session.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
              let media = (obj["data"] as? [String: Any])?["Media"] as? [String: Any],
              let id = media["id"] as? Int else { return nil }
        if let n = requireSeason {
            let titles = ((media["title"] as? [String: Any]) ?? [:]).values.compactMap { ($0 as? String)?.lowercased() }
            let ordinals = ["", "", "2nd", "3rd", "4th", "5th", "6th", "7th", "8th", "9th"]
            let roman = ["", "", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix"]
            let marks = ["season \(n)", "\(n)nd season", "\(n)rd season", "\(n)th season", n < ordinals.count ? ordinals[n] : "\(n)th",
                         n < roman.count ? " \(roman[n])" : "", " \(n)"].filter { !$0.isEmpty }
            guard titles.contains(where: { t in marks.contains { t.contains($0) } }) else {
                dlog("skip", "AniList: no confident match for \(title)")
                return nil
            }
        }
        return (id, media["idMal"] as? Int)
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

    private func oat(anidbId: Int, episode: Int, duration: Double, length: Double) async -> [SkipSegment] {
        if oatCache == nil || (oatFetched.map { Date().timeIntervalSince($0) > 86400 } ?? true) {
            guard let url = URL(string: "https://raw.githubusercontent.com/jonbarrow/open-anime-timestamps/master/timestamps.json"),
                  let obj = await json(url, timeout: 60) as? [String: Any] else { return [] }
            oatCache = obj
            oatFetched = Date()
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
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue("GlassPlayer/1.0", forHTTPHeaderField: "User-Agent")
        let t0 = CFAbsoluteTimeGetCurrent()
        func took() -> Int { Int((CFAbsoluteTimeGetCurrent() - t0) * 1000) }
        let result: (Data, URLResponse)
        do { result = try await session.data(for: req) } catch {
            // A lookup that lost the race is cancelled on purpose: not a failure.
            if (error as? URLError)?.code != .cancelled { dlog("skip", "\(url.host ?? "?") didn't answer in \(took()) ms: \(error.localizedDescription)") }
            return nil
        }
        let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            dlog("skip", "\(url.host ?? "?") answered HTTP \(status) in \(took()) ms")
            return nil
        }
        return try? JSONSerialization.jsonObject(with: result.0)
    }
}
