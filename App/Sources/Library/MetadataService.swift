import Foundation
import UIKit

/// Title metadata (poster, backdrop, synopsis, episode art) resolved from a
/// file name: parse the release name, look the
/// title up on IMDb (built-in source, no key), cache forever.
struct MediaMeta: Codable, Hashable {
    var id: String
    var type: String
    var name: String
    var poster: String?
    var background: String?
    var logo: String?
    var description: String?
    var year: String?
    var rating: String?
    var genres: [String]?
    var episodeTitle: String?
    var episodeThumb: String?
    var episodeOverview: String?
    /// The season and episode IMDb numbers the episode with, when the file
    /// used an absolute number ("Show - 26" → S2 E1).
    var episodeSeason: Int?
    var episodeNumber: Int?
    /// The show's title in its own language (romaji for anime), if different.
    var originalName: String?
    var credits: [CastMember]?
    var contentRating: String?
    /// How this entry was made: older entries are looked up again on their
    /// next use (1.13.1 fixed the cast photos and the original title).
    var version: Int?
    var titleLanguage: String?
    static let currentVersion = 4   // 3: absolute episode numbers mapped to seasons; OAD/Movie files. 4: original title kept (it was lost in IMDb's saved copy)

    /// Best 16:9 art for a tile; poster as a last resort.
    var wideArt: String? { episodeThumb ?? background ?? poster }
    var synopsis: String? { episodeOverview ?? description }
}

actor MetadataService {
    static let shared = MetadataService()

    private struct Entry: Codable { var meta: MediaMeta?; var date: Date }
    private var cache: [String: Entry] = [:]
    private var inflight: [String: Task<Resolved, Never>] = [:]
    private let file: URL
    private var dirty = false

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        file = dir.appendingPathComponent("metadata.json")
        if let d = try? Data(contentsOf: file), let c = try? JSONDecoder().decode([String: Entry].self, from: d) {
            if UserDefaults.standard.bool(forKey: Self.textDecodedKey) {
                cache = c
            } else {
                // Saved before 1.19.0, some text still has HTML character
                // references ("O&#39;Hara"): decoded once, saved, and marked
                // done only once that's written (1.19.0 decoded at every launch).
                cache = c.mapValues { e in Entry(meta: e.meta.map(Self.decodingEntities), date: e.date) }
                Task { await self.saveDecoded() }
            }
        } else {
            UserDefaults.standard.set(true, forKey: Self.textDecodedKey)
        }
    }

    private static let textDecodedKey = "metadataTextDecoded"

    private func saveDecoded() {
        guard let d = try? JSONEncoder().encode(cache), (try? d.write(to: file, options: .atomic)) != nil else { return }
        UserDefaults.standard.set(true, forKey: Self.textDecodedKey)
        dlog("meta", "saved library metadata with its text decoded (once)")
    }

    private static func decodingEntities(_ m: MediaMeta) -> MediaMeta {
        var m = m
        m.name = m.name.decodingHTMLEntities
        m.description = m.description?.decodingHTMLEntities
        m.episodeTitle = m.episodeTitle?.decodingHTMLEntities
        m.episodeOverview = m.episodeOverview?.decodingHTMLEntities
        m.originalName = m.originalName?.decodingHTMLEntities
        return m
    }

    // MARK: Fix Match (1.29.0)

    /// The IMDb title a library title was matched to by hand. Kept by the
    /// title parsed from the file's name, so every episode of a show (and
    /// every file of a film) follows it.
    struct Pin: Codable, Equatable, Sendable {
        var id: String
        var type: String
    }

    private var pins: [String: Pin]?
    private static var pinsFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("metadata-pins.json")
    }

    static func pinKey(_ p: TitleParser.Parsed) -> String { TitleParser.baseTitle(p).lowercased() }

    private func loadedPins() -> [String: Pin] {
        if let pins { return pins }
        let read = (try? Data(contentsOf: Self.pinsFile)).flatMap { try? JSONDecoder().decode([String: Pin].self, from: $0) } ?? [:]
        pins = read
        return read
    }

    func pin(forFile filename: String) -> Pin? {
        loadedPins()[Self.pinKey(TitleParser.parse(filename))]
    }

    /// Pins the title `filename` belongs to (nil: back to the automatic
    /// match), and forgets what was kept for it, so it's looked up again.
    func setPin(_ pin: Pin?, forFile filename: String) {
        let p = TitleParser.parse(filename)
        var all = loadedPins()
        all[Self.pinKey(p)] = pin
        pins = all
        if let d = try? JSONEncoder().encode(all) { try? d.write(to: Self.pinsFile, options: .atomic) }
        let prefix = p.title.lowercased() + "|"
        for k in cache.keys where k.hasPrefix(prefix) { cache[k] = nil }
        save()
        dlog("meta", "fix match: \(p.title) \(pin.map { "pinned to \($0.id)" } ?? "back to the automatic match")")
    }

    private static func cacheKey(_ p: TitleParser.Parsed) -> String {
        var key = [p.title.lowercased(), p.year.map(String.init) ?? "", p.season.map(String.init) ?? "", p.episode.map(String.init) ?? ""].joined(separator: "|")
        if let x = p.extra { key += "|" + x.lowercased() + (p.part.map { String($0) } ?? "") + "|" + (p.subtitle?.lowercased() ?? "") }
        return key
    }

    /// What's kept for a file already, without asking IMDb (1.30.0: the
    /// shared watched state reads a file's season and episode from it).
    func known(filename: String) -> MediaMeta? {
        cache[Self.cacheKey(TitleParser.parse(filename))]?.meta
    }

    func lookup(filename: String) async -> MediaMeta? {
        guard UserDefaults.standard.bool(forKey: SettingsKey.metadataFetching) else { return nil }
        let p = TitleParser.parse(filename)
        guard p.title.count >= 2 else { return nil }
        let key = Self.cacheKey(p)
        if let e = cache[key], e.meta != nil || Date().timeIntervalSince(e.date) < 86400 * 3 {
            if let m = e.meta, (m.version ?? 0) < MediaMeta.currentVersion || m.titleLanguage != EpisodeTitles.language {
                refresh(key: key, parsed: p)
            } else if let m = e.meta, m.type == "series", m.episodeTitle == nil, p.episode != nil, p.extra == nil,
                      Date().timeIntervalSince(e.date) > 3600 * 6 {
                // The show was found but not the episode: often a failed
                // episode-list request (IMDb's bot check), not a missing
                // episode. Try again now and then instead of never.
                refresh(key: key, parsed: p)
            }
            return e.meta
        }
        if let t = inflight[key] { return await t.value.meta }
        let task = Task<Resolved, Never> { await resolve(p) }
        inflight[key] = task
        let found = await task.value
        inflight[key] = nil
        // IMDb out of reach (offline, a timeout) isn't "no such title": until
        // 1.20.3 that was kept for 3 days, so a library browsed offline lost
        // its posters and names for days after (review, 2 Nov).
        if found.unreachable && found.meta == nil {
            dlog("meta", "IMDb not reachable for \(p.title); not remembered")
            return cache[key]?.meta
        }
        cache[key] = Entry(meta: found.meta, date: Date())
        save()
        return found.meta
    }

    /// A lookup's result, and whether IMDb couldn't be reached on the way.
    private struct Resolved: Sendable { var meta: MediaMeta?; var unreachable = false }
    private enum Searched { case found(MetaItem), noMatch, unreachable }

    private func resolve(_ p: TitleParser.Parsed) async -> Resolved {
        // Matched by hand (Fix Match): that title, no search.
        if let pin = loadedPins()[Self.pinKey(p)] {
            guard let item = await IMDbSource.details(id: pin.id, type: pin.type) else { return Resolved(meta: nil, unreachable: true) }
            return Resolved(meta: await meta(from: item, type: pin.type, parsed: p))
        }
        let wantsSeries = p.episode != nil && p.extra != "Movie"
        // A film of a series: its own title first ("Show Name Subtitle"), then
        // the series (art only). An OAD / OVA: the show it belongs to, but
        // never the show's episode of the same number.
        var attempts: [(title: String, type: String)]
        if p.extra == "Movie" {
            attempts = []
            if let sub = p.subtitle { attempts.append(("\(p.title) \(sub)", "movie")) }
            attempts += [(p.title, "movie"), (p.title, "series")]
        } else {
            let t = TitleParser.baseTitle(p)
            attempts = (wantsSeries ? ["series", "movie"] : ["movie", "series"]).map { (t, $0) }
        }
        var unreachable = false
        for (title, type) in attempts {
            let item: MetaItem
            switch await search(title: title, year: p.year, type: type) {
            case .found(let m): item = m
            case .noMatch: continue
            case .unreachable: unreachable = true; continue
            }
            return Resolved(meta: await meta(from: item, type: type, parsed: p))
        }
        return Resolved(meta: nil, unreachable: unreachable)
    }

    /// A found title as the library keeps it, with the file's episode when it's one.
    private func meta(from item: MetaItem, type: String, parsed p: TitleParser.Parsed) async -> MediaMeta {
        var meta = MediaMeta(id: item.id, type: item.type, name: item.name, poster: item.poster, background: item.background,
                             logo: item.logo, description: item.description, year: item.releaseInfo, rating: item.imdbRating, genres: item.genres)
        meta.originalName = item.originalName
        meta.credits = item.credits
        meta.contentRating = item.contentRating
        meta.version = MediaMeta.currentVersion
        meta.titleLanguage = EpisodeTitles.language
        if type == "series", p.extra == nil, let ep = p.episode, let video = await episode(of: item.id, season: p.season, episode: ep) {
            meta.episodeTitle = video.title
            meta.episodeThumb = video.thumbnail
            meta.episodeOverview = video.overview
            meta.episodeSeason = video.season
            meta.episodeNumber = video.episode
        }
        return meta
    }

    private func search(title: String, year: Int?, type: String) async -> Searched {
        let metas: [MetaItem]
        do { metas = try await IMDbSource.suggest(title).filter { $0.type == type } } catch {
            if !IMDbSource.isCancellation(error) { dlog("imdb/error", "suggestion failed for \(title): \(error.localizedDescription)") }
            return .unreachable
        }
        guard !metas.isEmpty else { return .noMatch }
        let norm = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let want = norm(title)
        func score(_ m: MetaItem) -> Int {
            var s = 0
            let n = norm(m.name)
            if n == want { s += 100 } else if n.hasPrefix(want) || want.hasPrefix(n) { s += 60 } else if n.contains(want) || want.contains(n) { s += 30 }
            if let year, let y = m.releaseInfo, y.hasPrefix(String(year)) { s += 40 }
            return s
        }
        let best = metas.max { score($0) < score($1) }
        guard var best, score(best) >= 30 else { return .noMatch }
        // Suggestion results carry no synopsis or rating; the title page does.
        if let full = await IMDbSource.details(id: best.id, type: type) {
            best.description = full.description
            best.imdbRating = full.imdbRating
            best.genres = full.genres
            best.background = full.background ?? best.background
            best.poster = full.poster ?? best.poster
            best.originalName = full.originalName
            best.credits = full.credits
            best.contentRating = full.contentRating
        }
        return .found(best)
    }

    /// The episode; with no season in the file name and a number past the
    /// end of season 1, the number counts on through the next seasons
    /// ("Attack on Titan - 26" is S2 E1 when season 1 has 25).
    private func episode(of id: String, season: Int?, episode: Int) async -> MetaVideo? {
        let s = season ?? 1
        let eps = await IMDbSource.episodes(id: id, season: s)
        if let v = eps.first(where: { $0.episode == episode }) { return v }
        guard season == nil, !eps.isEmpty else { return nil }
        var remaining = episode - (eps.map { $0.episode ?? 0 }.max() ?? eps.count)
        var next = 2
        while remaining > 0, next <= 12 {
            let list = await IMDbSource.episodes(id: id, season: next)
            // IMDb shows another season for one it doesn't have: stop there.
            guard !list.isEmpty, list.allSatisfy({ $0.season == next }) else { return nil }
            let count = list.map { $0.episode ?? 0 }.max() ?? list.count
            if remaining <= count {
                if let v = list.first(where: { $0.episode == remaining }) {
                    dlog("meta", "absolute episode \(episode) → S\(next) E\(remaining)")
                    return v
                }
                return nil
            }
            remaining -= count
            next += 1
        }
        return nil
    }

    private var refreshing = Set<String>()

    /// Looks an outdated entry up again in the background (two at a time);
    /// the page shows the new one next time it reads it.
    private func refresh(key: String, parsed: TitleParser.Parsed) {
        guard refreshing.count < 2, refreshing.insert(key).inserted else { return }
        Task {
            if let fresh = await resolve(parsed).meta {
                cache[key] = Entry(meta: fresh, date: Date())
                save()
                dlog("meta", "refreshed \(fresh.name)\(fresh.episodeTitle.map { " · " + $0 } ?? "") (original: \(fresh.originalName ?? "-"), cast \(fresh.credits?.count ?? 0))")
            }
            refreshing.remove(key)
        }
    }

    /// Forget everything looked up (Settings → Library → Refresh Metadata).
    func clear() {
        cache = [:]
        try? FileManager.default.removeItem(at: file)
    }

    var fileSize: Int64 { Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }

    private func save() {
        guard !dirty else { return }
        dirty = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let d = try? JSONEncoder().encode(cache) { try? d.write(to: file, options: .atomic) }
            dirty = false
        }
    }
}

/// Logo for a server host (Real-Debrid, TorBox, a NAS…), cached on disk.
enum BrandIcon {
    private static var dir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("brand", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func domain(for host: String) -> String {
        var h = host.lowercased()
        for p in ["dav.", "webdav.", "www.", "cloud.", "drive."] where h.hasPrefix(p) { h.removeFirst(p.count) }
        return h
    }

    static func cached(_ host: String) -> UIImage? {
        UIImage(contentsOfFile: dir.appendingPathComponent(domain(for: host) + ".png").path)
    }

    /// Names only a home network knows (a NAS, a router, a tailnet). They
    /// have no public logo, and asking the icon services for one would send
    /// the name to them.
    static func isPrivate(_ d: String) -> Bool {
        if d.range(of: #"^\d+\.\d+\.\d+\.\d+$"#, options: .regularExpression) != nil || d.contains(":") || !d.contains(".") { return true }
        let suffixes = [".local", ".lan", ".home", ".home.arpa", ".internal", ".intranet", ".localdomain", ".localhost",
                        ".corp", ".private", ".test", ".ts.net", ".box", ".router", ".fritz.box"]
        return suffixes.contains { d.hasSuffix($0) }
    }

    static func fetch(_ host: String) async -> UIImage? {
        if let c = cached(host) { return c }
        let d = domain(for: host)
        if isPrivate(d) { return nil }
        // A host with no logo is asked again after a week, not once per row.
        let miss = dir.appendingPathComponent(d + ".miss")
        if let at = (try? miss.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date().timeIntervalSince(at) < 7 * 86400 { return nil }
        let candidates = [
            "https://\(d)/apple-touch-icon.png",
            "https://www.\(d)/apple-touch-icon.png",
            "https://icons.duckduckgo.com/ip3/\(d).ico",
            "https://www.google.com/s2/favicons?domain=\(d)&sz=128",
        ]
        var answered = false
        for c in candidates {
            guard let url = URL(string: c) else { continue }
            var req = URLRequest(url: url); req.timeoutInterval = 8
            guard let r = try? await URLSession.shared.data(for: req) else { continue }
            answered = true
            guard (r.1 as? HTTPURLResponse)?.statusCode == 200,
                  let img = UIImage(data: r.0), img.size.width >= 32 else { continue }
            if let png = img.pngData() { try? png.write(to: dir.appendingPathComponent(d + ".png")) }
            return img
        }
        if answered { try? Data().write(to: miss) }     // offline isn't "no logo"
        return nil
    }
}

@MainActor
final class BrandIconLoader: ObservableObject {
    @Published var image: UIImage?
    func load(host: String?) {
        guard let host, !host.isEmpty else { return }
        if let c = BrandIcon.cached(host) { image = c; return }
        Task { image = await BrandIcon.fetch(host) }
    }
}
