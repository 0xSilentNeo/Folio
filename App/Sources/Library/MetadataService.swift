import Foundation
import UIKit

/// Title metadata (poster, backdrop, synopsis, episode art) resolved from a
/// file name, the way Infuse does it: parse the release name, look the
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
        if let d = try? Data(contentsOf: file), let c = try? JSONDecoder().decode([String: Entry].self, from: d) { cache = c }
    }

    func lookup(filename: String) async -> MediaMeta? {
        let p = TitleParser.parse(filename)
        guard p.title.count >= 2 else { return nil }
        let key = [p.title.lowercased(), p.year.map(String.init) ?? "", p.season.map(String.init) ?? "", p.episode.map(String.init) ?? ""].joined(separator: "|")
        if let e = cache[key], e.meta != nil || Date().timeIntervalSince(e.date) < 86400 * 3 { return e.meta }
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
        let wantsSeries = p.episode != nil
        let order = wantsSeries ? ["series", "movie"] : ["movie", "series"]
        for type in order {
            guard let item = await search(title: p.title, year: p.year, type: type) else { continue }
            var meta = MediaMeta(id: item.id, type: item.type, name: item.name, poster: item.poster, background: item.background,
                                 logo: item.logo, description: item.description, year: item.releaseInfo, rating: item.imdbRating, genres: item.genres)
            if type == "series", let ep = p.episode, let video = await episode(of: item.id, season: p.season, episode: ep) {
                meta.episodeTitle = video.title
                meta.episodeThumb = video.thumbnail
                meta.episodeOverview = video.overview
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
        }
        return best
    }

    private func episode(of id: String, season: Int?, episode: Int) async -> MetaVideo? {
        let s = season ?? 1
        let eps = await IMDbSource.episodes(id: id, season: s)
        return eps.first { $0.episode == episode }
    }

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
