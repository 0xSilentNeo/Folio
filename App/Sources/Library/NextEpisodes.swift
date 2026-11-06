import Foundation

/// The episodes that come after one, wherever they are on its server
/// (1.23.2). A queue is the files of the episode's own folder, but a debrid
/// service keeps every torrent in a folder of its own: a show added episode
/// by episode is one folder per episode, so the queue held the one file and
/// the player closed at its end instead of going on (5 Nov report: The
/// Gentlemen S02E01, E02, E03 and E06 in four folders on Real-Debrid,
/// "continue: 1 item(s) in queue" each time it was played).
enum NextEpisodes {
    /// What makes two files the same show: the parsed title, letters and
    /// digits only ("The.Gentlemen" and "The Gentlemen" are one).
    static func showKey(_ title: String) -> String {
        String(title.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// The release group, what follows the name's last "-": "…H.265-FLUX" → "flux".
    static func group(_ name: String) -> String? {
        let base = (name as NSString).deletingPathExtension
        guard let r = base.range(of: "-", options: .backwards) else { return nil }
        let g = base[r.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !g.isEmpty, g.count <= 24, !g.contains(" "), !g.contains(".") else { return nil }
        return g.lowercased()
    }

    private static let sample = try! NSRegularExpression(pattern: #"(?i)\bsample\b"#)

    /// The episodes after `url` (`name` is its file name) among `files`, in
    /// season and episode order, one file each, `limit` at most. An episode
    /// with copies in several releases gets the one most like this file:
    /// the same release group, then the same resolution, then the same folder.
    /// Seasons have to agree: an episode numbered without a season ("Show -
    /// 04") goes on only to others numbered without one.
    static func after(_ name: String, url: URL, in files: [LibraryIndex.File], limit: Int = 40) -> [LibraryIndex.File] {
        let p = TitleParser.parse(name)
        guard let episode = p.episode, p.extra == nil else { return [] }
        let key = showKey(p.title)
        guard !key.isEmpty else { return [] }
        let season = p.season ?? 0
        let myGroup = group(name)
        let me = url.standardized, myFolder = url.deletingLastPathComponent().standardized
        struct Pick { let file: LibraryIndex.File; let score: Int; let season: Int; let episode: Int }
        var best: [String: Pick] = [:]
        for f in files where TitleParser.isMedia(f.name) && f.url.standardized != me {
            let q = TitleParser.parse(f.name)
            guard let e = q.episode, q.extra == nil, (q.season == nil) == (p.season == nil),
                  showKey(q.title) == key else { continue }
            let s = q.season ?? 0
            guard s > season || (s == season && e > episode) else { continue }
            let path = f.url.path
            guard sample.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) == nil else { continue }
            var score = 0
            if let myGroup, group(f.name) == myGroup { score += 4 }
            if let r = p.resolution, q.resolution == r { score += 2 }
            if f.url.deletingLastPathComponent().standardized == myFolder { score += 1 }
            let k = "\(s):\(e)"
            if let b = best[k], b.score > score || (b.score == score && b.file.name.localizedStandardCompare(f.name) != .orderedDescending) { continue }
            best[k] = Pick(file: f, score: score, season: s, episode: e)
        }
        return best.values
            .sorted { $0.season != $1.season ? $0.season < $1.season : $0.episode < $1.episode }
            .prefix(limit).map(\.file)
    }
}
