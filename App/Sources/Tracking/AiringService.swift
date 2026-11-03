import Foundation

/// Asks TVmaze or AniList for a tracked show's schedule (off the main actor).
///
/// - TVmaze (series, and anime AniList doesn't know): the show by IMDb id
///   (`/lookup/shows?imdb=` answers with a redirect to it) or by name and
///   premiere year (`/search/shows`), once; after that by its TVmaze id with
///   the next and previous episodes embedded. At least 20 calls per 10 s.
/// - AniList (anime): one GraphQL query by AniList or MyAnimeList id, or a
///   search by name. About 90 calls a minute.
///
/// A source that can't be reached or is busy is `.unreachable`: the caller
/// keeps the schedule it had (EpisodeTitles caches no failure either).
actor AiringService {
    static let shared = AiringService()

    enum Outcome: Sendable {
        case found(AiringFetch)
        /// The source answered and doesn't know the show.
        case notFound
        case unreachable
    }

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 10
        return URLSession(configuration: c)
    }()

    /// The next moment each host may be asked, and until when a host that
    /// answered 429 is left alone.
    private var nextSlot: [String: Date] = [:]
    private var pausedUntil: [String: Date] = [:]

    /// Where a show's schedule is asked, in order: the source that has it
    /// once one has; else AniList then TVmaze for anime, TVmaze for the rest.
    static func sources(for show: TrackedShow) -> [TrackedShow.Source] {
        if show.source == .tvmaze, show.tvmaze != nil { return [.tvmaze] }
        if show.source == .anilist, show.anilist != nil { return [.anilist] }
        return show.anime == true ? [.anilist, .tvmaze] : [.tvmaze]
    }

    func fetch(_ show: TrackedShow) async -> Outcome {
        var outcome = Outcome.notFound
        for source in Self.sources(for: show) {
            if source == .anilist { outcome = await aniList(show) } else { outcome = await tvmaze(show) }
            // Only "not there" moves on: a source that couldn't be reached is asked again later.
            guard case .notFound = outcome else { return outcome }
            dlog("tracking", "\(show.name): not on \(source.title)")
        }
        return outcome
    }

    // MARK: TVmaze

    private func tvmaze(_ show: TrackedShow) async -> Outcome {
        var id = show.tvmaze
        if id == nil, let imdb = show.imdb, let url = URL(string: "https://api.tvmaze.com/lookup/shows?imdb=\(imdb)") {
            guard let r = await get(url) else { return .unreachable }       // URLSession follows the 301 to the show
            if r.status == 200 { id = AiringParse.tvmazeID(r.data) }
        }
        if id == nil {
            var c = URLComponents(string: "https://api.tvmaze.com/search/shows")!
            c.queryItems = [URLQueryItem(name: "q", value: show.name)]
            guard let url = c.url, let r = await get(url) else { return .unreachable }
            if r.status == 200 { id = AiringParse.tvmazeSearch(r.data, name: show.name, year: show.year) }
        }
        guard let id else { return .notFound }
        guard let url = URL(string: "https://api.tvmaze.com/shows/\(id)?embed%5B%5D=nextepisode&embed%5B%5D=previousepisode"),
              let r = await get(url) else { return .unreachable }
        if r.status == 404 { return .notFound }
        guard r.status == 200, let f = AiringParse.tvmazeShow(r.data) else {
            dlog("tracking", "\(show.name): TVmaze answered \(r.status) with nothing Folio could read")
            return .unreachable
        }
        return .found(f)
    }

    // MARK: AniList

    private func aniList(_ show: TrackedShow) async -> Outcome {
        var outcome: Outcome
        if let id = show.anilist {
            outcome = await aniListMedia(["id": id])
        } else if let mal = show.mal {
            outcome = await aniListMedia(["mal": mal])
        } else {
            outcome = .notFound
            // A later season is its own entry: that season's first.
            if let s = show.season, s > 1 { outcome = await aniListSearch("\(show.name) Season \(s)") }
            if case .notFound = outcome { outcome = await aniListSearch(show.name) }
        }
        // A finished season with a sequel: the newest season's schedule is the
        // one you want (season 1 → 2 → 3, a few hops at most).
        var hops = 0
        while case .found(let f) = outcome, f.status == .ended, let sequel = f.sequel, hops < 3 {
            hops += 1
            let next = await aniListMedia(["id": sequel])
            guard case .found = next else { break }
            dlog("tracking", "\(show.name): AniList \(f.anilist.map(String.init) ?? "?") has ended, following its sequel \(sequel)")
            outcome = next
        }
        return outcome
    }

    private static let mediaFields = "id idMal title{romaji english} status episodes siteUrl nextAiringEpisode{airingAt episode} "
        + "airingSchedule(notYetAired:true,perPage:6){nodes{airingAt episode}} coverImage{large} externalLinks{site type} "
        + "relations{edges{relationType node{id type status}}}"

    private func aniListMedia(_ vars: [String: Any]) async -> Outcome {
        let query = "query($id:Int,$mal:Int){Media(id:$id,idMal:$mal,type:ANIME){\(Self.mediaFields)}}"
        guard let r = await aniListPost(query, vars) else { return .unreachable }
        if r.status == 404 { return .notFound }
        guard r.status == 200 else { return .unreachable }
        return AiringParse.aniListMedia(r.data).map(Outcome.found) ?? .notFound
    }

    private func aniListSearch(_ name: String) async -> Outcome {
        let query = "query($s:String){Page(perPage:6){media(search:$s,type:ANIME,sort:SEARCH_MATCH){\(Self.mediaFields)}}}"
        guard let r = await aniListPost(query, ["s": name]) else { return .unreachable }
        if r.status == 404 { return .notFound }
        guard r.status == 200 else { return .unreachable }
        return AiringParse.aniListSearch(r.data, name: name).map(Outcome.found) ?? .notFound
    }

    /// The same request style as SkipService.aniListSearch.
    private func aniListPost(_ query: String, _ vars: [String: Any]) async -> (data: Data, status: Int)? {
        guard let url = URL(string: "https://graphql.anilist.co") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query, "variables": vars])
        return await send(req, host: "anilist", gap: 1.0)
    }

    // MARK: Requests

    private func get(_ url: URL) async -> (data: Data, status: Int)? {
        var req = URLRequest(url: url)
        req.setValue("Folio/1.0", forHTTPHeaderField: "User-Agent")
        return await send(req, host: "tvmaze", gap: 0.55)
    }

    /// A response, or nil when the host couldn't be reached or was busy
    /// (5xx, 429). Requests to one host are spaced `gap` seconds apart.
    private func send(_ req: URLRequest, host: String, gap: TimeInterval) async -> (data: Data, status: Int)? {
        if let until = pausedUntil[host], until > Date() { return nil }
        let now = Date()
        let at = max(now, nextSlot[host] ?? now)
        nextSlot[host] = at.addingTimeInterval(gap)       // taken before waiting: another call may come in meanwhile
        let wait = at.timeIntervalSince(now)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        guard !Task.isCancelled else { return nil }
        guard let (data, resp) = try? await session.data(for: req) else {
            dlog("tracking", "\(host) not reached")
            return nil
        }
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 429 {
            let retry = (http?.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init) ?? 60
            pausedUntil[host] = Date().addingTimeInterval(min(max(retry, 10), 300))
            dlog("tracking", "\(host) is busy (429): left alone for \(Int(retry)) s")
            return nil
        }
        if status >= 500 { dlog("tracking", "\(host) answered \(status)"); return nil }
        return (data, status)
    }
}

// MARK: - Reading the answers

/// TVmaze's and AniList's JSON, read leniently: an odd episode is left out,
/// not the whole show. Pure functions (TrackingTests feeds them fixtures).
enum AiringParse {
    // TVmaze

    private struct TVShow: Decodable {
        struct Channel: Decodable { var name: String? }
        struct Image: Decodable { var medium: String?; var original: String? }
        struct Externals: Decodable { var imdb: String? }
        struct Embedded: Decodable {
            var next: TVEpisode?
            var previous: TVEpisode?
            enum CodingKeys: String, CodingKey { case next = "nextepisode", previous = "previousepisode" }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                next = try? c.decodeIfPresent(TVEpisode.self, forKey: .next)
                previous = try? c.decodeIfPresent(TVEpisode.self, forKey: .previous)
            }
        }
        var id: Int
        var name: String?
        var status: String?
        var premiered: String?
        var url: String?
        var network: Channel?
        var webChannel: Channel?
        var image: Image?
        var externals: Externals?
        var embedded: Embedded?
        enum CodingKeys: String, CodingKey { case id, name, status, premiered, url, network, webChannel, image, externals, embedded = "_embedded" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id)
            name = try? c.decodeIfPresent(String.self, forKey: .name)
            status = try? c.decodeIfPresent(String.self, forKey: .status)
            premiered = try? c.decodeIfPresent(String.self, forKey: .premiered)
            url = try? c.decodeIfPresent(String.self, forKey: .url)
            network = try? c.decodeIfPresent(Channel.self, forKey: .network)
            webChannel = try? c.decodeIfPresent(Channel.self, forKey: .webChannel)
            image = try? c.decodeIfPresent(Image.self, forKey: .image)
            externals = try? c.decodeIfPresent(Externals.self, forKey: .externals)
            embedded = try? c.decodeIfPresent(Embedded.self, forKey: .embedded)
        }
    }

    private struct TVEpisode: Decodable {
        var name: String?
        var season: Int?
        var number: Int?
        var airstamp: String?
    }

    private struct TVHit: Decodable { var show: TVShow }

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = stamp.date(from: s) { return d }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    private static func episode(_ e: TVEpisode?) -> AiringEpisode? {
        guard let e else { return nil }
        let title = e.name?.trimmingCharacters(in: .whitespaces)
        return AiringEpisode(season: e.season, number: e.number, title: title?.isEmpty == false ? title : nil, airDate: date(e.airstamp))
    }

    /// `/lookup/shows?imdb=`: the show it redirected to.
    static func tvmazeID(_ data: Data) -> Int? { (try? JSONDecoder().decode(TVShow.self, from: data))?.id }

    /// `/search/shows?q=`: the first show whose name matches and whose
    /// premiere is within a year of Folio's (EpisodeTitles' rule).
    static func tvmazeSearch(_ data: Data, name: String, year: Int?) -> Int? {
        guard let hits = JSONDecoder().decodeLossy(TVHit.self, from: data) else { return nil }
        let want = TrackedShow.normalized(name)
        return hits.first { h in
            guard TrackedShow.normalized(h.show.name ?? "") == want else { return false }
            guard let year, let p = h.show.premiered.flatMap({ Int($0.prefix(4)) }) else { return true }
            return abs(p - year) <= 1
        }?.show.id
    }

    /// `/shows/:id?embed[]=nextepisode&embed[]=previousepisode`.
    static func tvmazeShow(_ data: Data, now: Date = Date()) -> AiringFetch? {
        guard let s = try? JSONDecoder().decode(TVShow.self, from: data) else { return nil }
        let next = episode(s.embedded?.next), previous = episode(s.embedded?.previous)
        let status: TrackedShow.Status
        switch s.status {
        case "Running": status = previous == nil && next != nil ? .upcoming : .airing
        case "In Development": status = .upcoming
        case "Ended": status = .ended
        default: status = next != nil ? .upcoming : .unknown      // "To Be Determined"
        }
        let imdb = s.externals?.imdb.flatMap { $0.hasPrefix("tt") ? $0 : nil }
        return AiringFetch(source: .tvmaze, tvmaze: s.id, imdb: imdb, name: s.name, status: status,
                           network: s.network?.name ?? s.webChannel?.name, poster: s.image?.medium ?? s.image?.original,
                           page: s.url, next: next, lastAired: previous)
    }

    // AniList

    private struct ALMedia: Decodable {
        struct Title: Decodable { var romaji: String?; var english: String? }
        struct Airing: Decodable { var airingAt: Int?; var episode: Int? }
        struct Schedule: Decodable {
            var nodes: [Airing]
            init(from decoder: Decoder) throws {
                nodes = (try? decoder.container(keyedBy: CodingKeys.self).lossy(Airing.self, .nodes)) ?? []
            }
            enum CodingKeys: String, CodingKey { case nodes }
        }
        struct Cover: Decodable { var large: String? }
        struct Link: Decodable { var site: String?; var type: String? }
        struct Relations: Decodable {
            struct Edge: Decodable {
                struct Node: Decodable { var id: Int; var type: String?; var status: String? }
                var relationType: String?
                var node: Node?
            }
            var edges: [Edge]
            init(from decoder: Decoder) throws {
                edges = (try? decoder.container(keyedBy: CodingKeys.self).lossy(Edge.self, .edges)) ?? []
            }
            enum CodingKeys: String, CodingKey { case edges }
        }
        var id: Int
        var idMal: Int?
        var title: Title?
        var status: String?
        var episodes: Int?
        var siteUrl: String?
        var nextAiringEpisode: Airing?
        var airingSchedule: Schedule?
        var coverImage: Cover?
        var externalLinks: [Link]?
        var relations: Relations?

        enum CodingKeys: String, CodingKey {
            case id, idMal, title, status, episodes, siteUrl, nextAiringEpisode, airingSchedule, coverImage, externalLinks, relations
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id)
            idMal = try? c.decodeIfPresent(Int.self, forKey: .idMal)
            title = try? c.decodeIfPresent(Title.self, forKey: .title)
            status = try? c.decodeIfPresent(String.self, forKey: .status)
            episodes = try? c.decodeIfPresent(Int.self, forKey: .episodes)
            siteUrl = try? c.decodeIfPresent(String.self, forKey: .siteUrl)
            nextAiringEpisode = try? c.decodeIfPresent(Airing.self, forKey: .nextAiringEpisode)
            airingSchedule = try? c.decodeIfPresent(Schedule.self, forKey: .airingSchedule)
            coverImage = try? c.decodeIfPresent(Cover.self, forKey: .coverImage)
            externalLinks = c.lossy(Link.self, .externalLinks)
            relations = try? c.decodeIfPresent(Relations.self, forKey: .relations)
        }

        var titles: [String] { [title?.english, title?.romaji].compactMap { $0 } }
    }

    private struct ALMediaAnswer: Decodable {
        struct D: Decodable { var Media: ALMedia? }
        var data: D?
    }

    private struct ALPageAnswer: Decodable {
        struct D: Decodable {
            struct P: Decodable {
                var media: [ALMedia]
                init(from decoder: Decoder) throws {
                    media = (try? decoder.container(keyedBy: CodingKeys.self).lossy(ALMedia.self, .media)) ?? []
                }
                enum CodingKeys: String, CodingKey { case media }
            }
            var Page: P?
        }
        var data: D?
    }

    /// `Media(id:|idMal:)`.
    static func aniListMedia(_ data: Data) -> AiringFetch? {
        (try? JSONDecoder().decode(ALMediaAnswer.self, from: data))?.data?.Media.map(fetch)
    }

    /// `Page { media(search:) }`: of the entries whose title matches the
    /// name, one airing or announced first (you track what's on), else
    /// AniList's best match.
    static func aniListSearch(_ data: Data, name: String) -> AiringFetch? {
        guard let list = (try? JSONDecoder().decode(ALPageAnswer.self, from: data))?.data?.Page?.media, !list.isEmpty else { return nil }
        let want = TrackedShow.normalized(name)
        let close = list.filter { m in
            m.titles.contains { t in
                let n = TrackedShow.normalized(t)
                return !n.isEmpty && (n == want || n.hasPrefix(want) || want.hasPrefix(n))
            }
        }
        let active: (ALMedia) -> Bool = { ["RELEASING", "NOT_YET_RELEASED"].contains($0.status ?? "") }
        return (close.first(where: active) ?? close.first ?? list.first).map(fetch)
    }

    private static func fetch(_ m: ALMedia) -> AiringFetch {
        func ep(_ a: ALMedia.Airing) -> AiringEpisode? {
            guard let at = a.airingAt else { return nil }
            return AiringEpisode(number: a.episode, airDate: Date(timeIntervalSince1970: TimeInterval(at)))
        }
        let scheduled = (m.airingSchedule?.nodes ?? []).compactMap(ep).sorted { $0.airDate! < $1.airDate! }
        let next = m.nextAiringEpisode.flatMap(ep) ?? scheduled.first
        let later = scheduled.filter { e in next.map { e.airDate! > $0.airDate! } ?? true }
        let status: TrackedShow.Status
        switch m.status {
        case "RELEASING": status = .airing
        case "NOT_YET_RELEASED": status = .upcoming
        case "FINISHED", "CANCELLED": status = .ended
        default: status = .unknown                                    // HIATUS
        }
        // The episode before the next one (AniList gives no time for it here),
        // or a finished show's last.
        var last: AiringEpisode?
        if let n = next?.number, n > 1 { last = AiringEpisode(number: n - 1) }
        else if status == .ended, let n = m.episodes { last = AiringEpisode(number: n) }
        let streaming = m.externalLinks?.first { $0.type == "STREAMING" }?.site
        // A season's sequel, an airing or announced one first. Seasons chain
        // (Frieren: season 1 → 2 → 3), so a finished sequel is followed too.
        let sequels = (m.relations?.edges ?? []).filter { $0.relationType == "SEQUEL" && ($0.node?.type ?? "ANIME") == "ANIME" }
        let sequel = (sequels.first { ["RELEASING", "NOT_YET_RELEASED"].contains($0.node?.status ?? "") } ?? sequels.first)?.node?.id
        return AiringFetch(source: .anilist, anilist: m.id, mal: m.idMal, name: m.title?.english ?? m.title?.romaji,
                           status: status, network: streaming, poster: m.coverImage?.large,
                           page: m.idMal.map { "https://myanimelist.net/anime/\($0)" } ?? m.siteUrl ?? "https://anilist.co/anime/\(m.id)",
                           next: next, later: later, lastAired: last, sequel: sequel)
    }
}
