import UIKit

/// `-shots` (CI screenshot run, UITests/ShotsUITests): a library with a
/// series and a film, Continue Watching, title metadata and the Discover
/// cache, all with generated artwork — one dark picture and one very bright
/// one, so text over pictures is checked against both extremes in both
/// appearances. Runs from the app's init, before any view or service reads
/// the files it writes. No network needed.
@MainActor
enum ShotsSeed {
    static var enabled: Bool { CommandLine.arguments.contains("-shots") }

    struct Art { let posterDark, backdropDark, posterBright, backdropBright, still, face: String }

    static func run() {
        let art = makeArt()
        UserDefaults.standard.set(false, forKey: SettingsKey.resumePlayback)
        UserDefaults.standard.set(true, forKey: SettingsKey.metadataFetching)

        // Library: three episodes and a film (copies of the bundled clip).
        // `-shotsLibrary=N` (Home grid checks): N entries on Home — the series,
        // the film and the folder first, then films with short and long names.
        let homeEntries = CommandLine.arguments.first(where: { $0.hasPrefix("-shotsLibrary=") }).flatMap { Int($0.dropFirst("-shotsLibrary=".count)) } ?? 3
        guard let src = Bundle.main.url(forResource: "lab", withExtension: "mp4", subdirectory: "lab") ?? Bundle.main.url(forResource: "lab", withExtension: "mp4") else { return }
        let dir = MPVFiles.mediaDir
        // A set number of entries starts from an empty library (each test launch).
        if CommandLine.arguments.contains(where: { $0.hasPrefix("-shotsLibrary=") }) { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = (homeEntries >= 1 ? ["Lab Show S01E01.mp4", "Lab Show S01E02.mp4", "Lab Show S01E03.mp4"] : []) + (homeEntries >= 2 ? ["Bright Movie 2024.mp4"] : [])
        let extras = (0..<max(0, homeEntries - 3)).map { i in
            i % 3 == 1 ? "A Film With A Very Long Name That Keeps Going Well Past The Tile \(2001 + i).mp4" : "Extra Film \(i + 1) \(2001 + i).mp4"
        }
        for n in files + extras {
            let d = dir.appendingPathComponent(n)
            if !FileManager.default.fileExists(atPath: d.path) { try? FileManager.default.copyItem(at: src, to: d) }
        }

        // Title metadata, written where MetadataService reads it at start-up.
        let cast = [CastMember(id: "nm0000001", name: "Lab Actor One", character: "Hero", photo: art.face),
                    CastMember(id: "nm0000002", name: "Lab Actor Two", character: "Rival", photo: nil),
                    CastMember(id: "nm0000003", name: "Lab Actor Three", character: nil, photo: nil)]
        var show = MediaMeta(id: "tt9000002", type: "series", name: "Lab Show", poster: art.posterDark, background: art.backdropDark,
                             logo: nil, description: String(repeating: "Students compare their test results while the points arrive late. ", count: 4),
                             year: "2017", rating: "7.7", genres: ["Animation", "Drama", "Thriller", "Anime"])
        show.originalName = "Rabo Shō: jitsuryoku shijō shugi no kyōshitsu e"
        // `-shotsTitle=<name>`: the show under another (long) name, for the
        // title-page header checks; `-shotsNoOriginal`: without a romaji title.
        if let t = CommandLine.arguments.first(where: { $0.hasPrefix("-shotsTitle=") }) { show.name = String(t.dropFirst("-shotsTitle=".count)) }
        if CommandLine.arguments.contains("-shotsNoOriginal") { show.originalName = nil }
        // `-shotsNotAnime`: a show that isn't anime (the line under the title is
        // the episode name); `-shotsEpisodeTitle=<text>`: that episode name.
        if CommandLine.arguments.contains("-shotsNotAnime") { show.genres = ["Drama", "Thriller"] }
        let episodeTitle = CommandLine.arguments.first(where: { $0.hasPrefix("-shotsEpisodeTitle=") }).map { String($0.dropFirst("-shotsEpisodeTitle=".count)) }
        show.credits = cast
        show.contentRating = "M"
        show.version = MediaMeta.currentVersion
        show.titleLanguage = EpisodeTitles.language
        var movie = MediaMeta(id: "tt9000003", type: "movie", name: "Bright Movie", poster: art.posterBright, background: art.backdropBright,
                              logo: nil, description: "A sunny comedy on a very bright beach, to check text over light pictures.",
                              year: "2024", rating: "6.9", genres: ["Comedy", "Family"])
        movie.credits = cast
        movie.contentRating = "PG"
        movie.version = MediaMeta.currentVersion
        movie.titleLanguage = EpisodeTitles.language
        var entries: [String: SeedEntry] = [:]
        for (i, n) in files.enumerated() {
            var m = n.hasPrefix("Bright") ? movie : show
            if !n.hasPrefix("Bright") {
                m.episodeTitle = episodeTitle ?? "Episode title \(i + 1)"
                m.episodeThumb = art.still
                m.episodeOverview = "What happens in episode \(i + 1): a longer line so the details view wraps."
            }
            entries[metadataKey(n)] = SeedEntry(meta: m, date: Date())
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(entries) { try? d.write(to: support.appendingPathComponent("metadata.json"), options: .atomic) }
        // A folder of different titles (1.15.0 folder tile).
        if homeEntries >= 3 {
            let mixed = dir.appendingPathComponent("Weekend picks", isDirectory: true)
            try? FileManager.default.createDirectory(at: mixed, withIntermediateDirectories: true)
            for n in ["Lab Show S01E04.mp4", "Bright Movie 2024.mp4", "Another Film 2019.mp4"] {
                let d = mixed.appendingPathComponent(n)
                if !FileManager.default.fileExists(atPath: d.path) { try? FileManager.default.copyItem(at: src, to: d) }
            }
        }
        LocalMediaStore.shared.refresh()

        // Downloads screen: finished, paused and failed files (nothing that
        // would start a real transfer).
        let remote = URL(string: "https://dav.example.com/Lab%20Show/")!
        func dl(_ name: String, _ state: DownloadItem.State, _ got: Int64, _ size: Int64, _ err: String? = nil) -> DownloadItem {
            var d = DownloadItem(url: remote.appendingPathComponent(name), serverID: nil, fileName: name, package: "[Lab] Lab Show",
                                 expected: size, destination: DownloadManager.destination(fileName: name, package: "[Lab] Lab Show"))
            d.state = state; d.received = got; d.error = err
            if state == .done { d.finished = Date() }
            return d
        }
        let mb: Int64 = 1_048_576
        let seeded = [dl("[Lab] Lab Show - 05.mkv", .done, 543 * mb, 543 * mb), dl("[Lab] Lab Show - 06.mkv", .paused, 212 * mb, 497 * mb),
                      dl("[Lab] Lab Show - 07.mkv", .paused, 0, 512 * mb), dl("[Lab] Lab Show - 08.mkv", .failed, 88 * mb, 530 * mb, "The network connection was lost.")]
        if let d = try? JSONEncoder().encode(seeded) {
            try? d.write(to: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("downloads.json"), options: .atomic)
        }

        // Continue Watching: episode 1, a third of the way in.
        if homeEntries >= 1 {
            var item = MediaItem(url: dir.appendingPathComponent(files[0]).path, title: "Lab Show S01E01", source: .local)
            item.historyKey = item.url
            HistoryStore.shared.record(item, position: 410, duration: 1420)
        }

        // Discover: the IMDb cache, with the same pictures.
        IMDbSource.seedForLab(art: (art.posterDark, art.backdropDark, art.posterBright, art.backdropBright))
        dlog("lab", "shots seeded")
    }

    /// MetadataService's on-disk entry (same field names, same date encoding).
    private struct SeedEntry: Codable { var meta: MediaMeta?; var date: Date }

    /// The key MetadataService.lookup derives from a file name.
    private static func metadataKey(_ filename: String) -> String {
        let p = TitleParser.parse(filename)
        return [p.title.lowercased(), p.year.map(String.init) ?? "", p.season.map(String.init) ?? "", p.episode.map(String.init) ?? ""].joined(separator: "|")
    }

    // MARK: Artwork

    private static func makeArt() -> Art {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func save(_ name: String, _ size: CGSize, _ draw: (CGContext, CGSize) -> Void) -> String {
            let url = dir.appendingPathComponent(name + ".png")
            let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
            let img = UIGraphicsImageRenderer(size: size, format: fmt).image { draw($0.cgContext, size) }
            try? img.pngData()?.write(to: url)
            return url.absoluteString
        }
        func gradient(_ c: CGContext, _ s: CGSize, _ colors: [UInt32], vertical: Bool = true) {
            let cg = colors.map { UIColor(hex: $0).cgColor } as CFArray
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cg, locations: nil)!
            c.drawLinearGradient(g, start: .zero, end: vertical ? CGPoint(x: 0, y: s.height) : CGPoint(x: s.width, y: s.height), options: [])
        }
        func glow(_ c: CGContext, _ center: CGPoint, _ r: CGFloat, _ color: UInt32, _ alpha: CGFloat) {
            let cg = [UIColor(hex: color, alpha: alpha).cgColor, UIColor(hex: color, alpha: 0).cgColor] as CFArray
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cg, locations: [0, 1])!
            c.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: r, options: [])
        }
        func hills(_ c: CGContext, _ s: CGSize, _ color: UInt32, _ y: CGFloat) {
            c.setFillColor(UIColor(hex: color).cgColor)
            c.move(to: CGPoint(x: 0, y: s.height))
            c.addLine(to: CGPoint(x: 0, y: s.height * y))
            c.addCurve(to: CGPoint(x: s.width, y: s.height * (y - 0.06)), control1: CGPoint(x: s.width * 0.3, y: s.height * (y - 0.18)), control2: CGPoint(x: s.width * 0.6, y: s.height * (y + 0.1)))
            c.addLine(to: CGPoint(x: s.width, y: s.height))
            c.fillPath()
        }
        func label(_ text: String, _ s: CGSize, _ color: UInt32) {
            let p = NSMutableParagraphStyle(); p.alignment = .center
            let a: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: s.width * 0.11, weight: .heavy), .foregroundColor: UIColor(hex: color), .paragraphStyle: p]
            (text as NSString).draw(in: CGRect(x: 0, y: s.height * 0.08, width: s.width, height: s.height * 0.3), withAttributes: a)
        }
        let backDark = save("backdrop-dark", CGSize(width: 1280, height: 720)) { c, s in
            gradient(c, s, [0x0B1A2E, 0x1E3B57, 0xD98E5A])
            glow(c, CGPoint(x: s.width * 0.72, y: s.height * 0.62), 260, 0xFFC27A, 0.8)
            for (x, y, r) in [(0.15, 0.3, 60.0), (0.3, 0.2, 40.0), (0.85, 0.25, 50.0)] { glow(c, CGPoint(x: s.width * x, y: s.height * y), r, 0x7FD1E8, 0.5) }
            hills(c, s, 0x0A0F18, 0.78)
        }
        let backBright = save("backdrop-bright", CGSize(width: 1280, height: 720)) { c, s in
            gradient(c, s, [0x9ED3F5, 0xE9F5FB, 0xFFFDF4])
            glow(c, CGPoint(x: s.width * 0.25, y: s.height * 0.3), 220, 0xFFFFFF, 1)
            hills(c, s, 0xB8DE8E, 0.8)
        }
        let posterDark = save("poster-dark", CGSize(width: 600, height: 900)) { c, s in
            gradient(c, s, [0x2B1D3A, 0x0E0F1A])
            glow(c, CGPoint(x: s.width * 0.5, y: s.height * 0.55), 220, 0xE0455A, 0.9)
            label("LAB SHOW", s, 0xFFFFFF)
        }
        let posterBright = save("poster-bright", CGSize(width: 600, height: 900)) { c, s in
            gradient(c, s, [0xFFF6DD, 0xF6C98E])
            glow(c, CGPoint(x: s.width * 0.5, y: s.height * 0.6), 240, 0xFFFFFF, 1)
            label("BRIGHT", s, 0x1D1C1A)
        }
        let still = save("still", CGSize(width: 640, height: 360)) { c, s in
            gradient(c, s, [0x123C3A, 0x3E8F7E, 0xD8E8C8], vertical: false)
            hills(c, s, 0x0D2422, 0.75)
        }
        let face = save("face", CGSize(width: 180, height: 180)) { c, s in
            gradient(c, s, [0xC9A27E, 0x6B4E3A])
            glow(c, CGPoint(x: s.width * 0.5, y: s.height * 0.42), 50, 0xF2D2B6, 1)
        }
        return Art(posterDark: posterDark, backdropDark: backDark, posterBright: posterBright, backdropBright: backBright, still: still, face: face)
    }
}
