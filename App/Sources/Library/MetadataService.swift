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
    private var inflight: [String: Task<MediaMeta?, Never>] = [:]
    private let file: URL
    private var dirty = false

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        file = dir.appendingPathComponent("metadata.json")
        if let d = try? Data(contentsOf: file), let c = try? JSONDecoder().decode([String: Entry].self, from: d) {
            // Saved before 1.19.0, some text still has HTML character references ("O&#39;Hara"): decoded once here.
            cache = c.mapValues { e in Entry(meta: e.meta.map(Self.decodingEntities), date: e.date) }
        }
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

    func lookup(filename: String) async -> MediaMeta? {
        guard UserDefaults.standard.bool(forKey: SettingsKey.metadataFetching) else { return nil }
        let p = TitleParser.parse(filename)
        guard p.title.count >= 2 else { return nil }
        var key = [p.title.lowercased(), p.year.map(String.init) ?? "", p.season.map(String.init) ?? "", p.episode.map(String.init) ?? ""].joined(separator: "|")
        if let x = p.extra { key += "|" + x.lowercased() + (p.part.map { String($0) } ?? "") + "|" + (p.subtitle?.lowercased() ?? "") }
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
        if let t = inflight[key] { return await t.value }
        let task = Task<MediaMeta?, Never> { await resolve(p) }
        inflight[key] = task
        let meta = await task.value
        inflight[key] = nil
        cache[key] = Entry(meta: meta, date: Date())
        save()
        return meta
    }

    private func resolve(_ p: TitleParser.Parsed) async -> MediaMeta? {
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
        for (title, type) in attempts {
            guard let item = await search(title: title, year: p.year, type: type) else { continue }
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
        return nil
    }

    private func search(title: String, year: Int?, type: String) async -> MetaItem? {
        let metas = await IMDbSource.search(title).filter { $0.type == type }
        guard !metas.isEmpty else { return nil }
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
        guard var best, score(best) >= 30 else { return nil }
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
        return best
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
            if let fresh = await resolve(parsed) {
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

    static func fetch(_ host: String) async -> UIImage? {
        if let c = cached(host) { return c }
        let d = domain(for: host)
        // Private hosts / IPs have no public logo.
        if d.range(of: #"^\d+\.\d+\.\d+\.\d+$"#, options: .regularExpression) != nil || d.hasSuffix(".local") || !d.contains(".") { return nil }
        let candidates = [
            "https://\(d)/apple-touch-icon.png",
            "https://www.\(d)/apple-touch-icon.png",
            "https://icons.duckduckgo.com/ip3/\(d).ico",
            "https://www.google.com/s2/favicons?domain=\(d)&sz=128",
        ]
        for c in candidates {
            guard let url = URL(string: c) else { continue }
            var req = URLRequest(url: url); req.timeoutInterval = 8
            guard let r = try? await URLSession.shared.data(for: req),
                  (r.1 as? HTTPURLResponse)?.statusCode == 200,
                  let img = UIImage(data: r.0), img.size.width >= 32 else { continue }
            if let png = img.pngData() { try? png.write(to: dir.appendingPathComponent(d + ".png")) }
            return img
        }
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
