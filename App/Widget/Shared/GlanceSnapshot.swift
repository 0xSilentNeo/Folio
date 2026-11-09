import Foundation

// Built into both Folio and FolioWidget (1.24.0): what the newer widgets
// show, written by the app (GlanceWriter) next to the other snapshots.
// Foundation only. Nothing in here is an address, a token or a password: a
// tap carries an id or a name, and Folio looks the rest up.

/// The widgets' kinds, the same in the app (which reloads them) and the extension.
enum WidgetKind {
    static let continueWatching = ContinueSnapshot.widgetKind
    static let continueRing = "ContinueRing"
    static let continueEpisode = "ContinueEpisode"
    static let continueShelf = "ContinueShelf"
    static let airing = AiringSnapshot.widgetKind
    static let airingDay = "AiringDay"
    static let airingOutNow = "AiringOutNow"
    static let downloads = "Downloads"
    static let yourWeek = "YourWeek"
    static let newOnServers = "NewOnServers"
    static let pickTonight = "PickTonight"

    /// Every widget that reads Continue Watching's snapshot.
    static let continueKinds = [continueWatching, continueRing, continueEpisode, continueShelf]
    static let airingKinds = [airing, airingDay, airingOutNow]
}

/// One small file per widget, each written only when it changes.
protocol GlanceFile: Codable, Equatable {
    static var fileName: String { get }
}

extension GlanceFile {
    static func read(from store: WidgetStore?) -> Self? {
        guard let data = store?.read(fileName) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try? d.decode(Self.self, from: data)
    }

    func write(to store: WidgetStore) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        try store.write(try e.encode(self), Self.fileName)
    }
}

/// The Downloads widget: the run in progress, as the downloads Live
/// Activity has it (its timer range moves the bar and the time left without
/// the app), and what's ready to watch offline.
struct DownloadsGlance: GlanceFile {
    static let fileName = "downloads.json"
    /// Nil when nothing downloads.
    var run: DownloadActivityAttributes.ContentState?
    /// How connected: "Wi-Fi", "Cellular" (nil when unknown).
    var network: String?
    /// Files downloaded in the last week, newest first (names only).
    var ready: [String]
    var readyCount: Int
    var written: Date

    /// How long a written speed stands for the speed now (1.27.0).
    static let speedFresh: TimeInterval = 90
}

/// The Your week widget, from WatchLog.
struct WeekGlance: GlanceFile {
    static let fileName = "week.json"
    var seconds: Double
    var shows: Int
    var films: Int
    var episodes: Int
    /// Seconds on each of the last seven days, today last.
    var perDay: [Double]
    /// The day the counting began, when that's inside the week.
    var countingSince: Date?
    /// The day this is about: the widget says "this week" only until it changes.
    var day: Date

    /// Days since this was written (0 the same day).
    func daysOld(at now: Date, calendar: Calendar = .current) -> Int {
        max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: day), to: calendar.startOfDay(for: now)).day ?? 0)
    }

    /// The last seven days' time at `now` (1.25.0): each midnight without
    /// Folio the oldest day leaves the week, from `perDay`. Until 1.25.0 the
    /// widget kept the week it was given until Folio wrote again.
    func seconds(at now: Date, calendar: Calendar = .current) -> Double {
        let k = daysOld(at: now, calendar: calendar)
        guard k > 0 else { return seconds }
        guard k < perDay.count else { return 0 }
        return perDay.dropFirst(k).reduce(0, +)
    }

    /// "4 h 20", "35 min", "0 min".
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : String(format: "%d h %02d", h, m)
    }
}

/// The New on your servers widget: the newest releases of a server's saved
/// library (no network: from the summary Home's row uses).
struct ServersGlance: GlanceFile {
    static let fileName = "servers.json"
    struct Release: Codable, Equatable, Identifiable {
        /// The folder's name on the server: what folio://release opens.
        var folder: String
        var title: String
        /// "S01 · 2160p", "2024 · 1080p".
        var detail: String?
        var added: Date?
        var id: String { folder }
    }
    /// The server's id (a UUID) and name ("Real-Debrid").
    var server: String
    var serverName: String
    /// Releases added in the last seven days.
    var thisWeek: Int
    var releases: [Release]
}

/// The Pick for tonight widget: titles from your library you haven't
/// started, in the order the widget shows them; Shuffle moves to the next.
struct PicksGlance: GlanceFile {
    static let fileName = "picks.json"
    struct Pick: Codable, Equatable, Identifiable {
        /// The file's place inside the library (Media/…): what folio://library plays.
        var file: String
        var title: String
        /// "Film · 1 h 48 · 2024", "Series · 8 episodes".
        var line: String
        var picture: String?
        var id: String { file }
    }
    var picks: [Pick]
}

/// The newer widgets' links (1.24.0).
enum GlanceLink {
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    private static func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }

    /// folio://library?file=<place in Media>: plays a library file.
    static func library(file: String) -> URL { URL(string: "folio://library?file=" + enc(file)) ?? downloads }
    /// folio://release?server=<id>&name=<folder>: a release's folder on a server.
    static func release(server: String, folder: String) -> URL {
        URL(string: "folio://release?server=\(enc(server))&name=\(enc(folder))") ?? downloads
    }
    /// folio://release?server=<id>: the server's library.
    static func server(_ id: String) -> URL { URL(string: "folio://release?server=\(enc(id))") ?? downloads }
    static let downloads = URL(string: "folio://downloads")!
    /// Opens Folio on Home.
    static let home = URL(string: "folio://home")!

    static func value(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}
