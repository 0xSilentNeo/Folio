import Foundation

// Built into both Folio and FolioWidget, as ContinueSnapshot is: the tracked
// shows' upcoming episodes, which the app writes and the Airing widget reads.
// Foundation only.

/// When an episode counts as just out, and which one a show is about at a
/// given moment. The same rule in the app (Tracking screen, Home's row) and
/// in the widget, so both say "Out now" for the same six hours.
enum AiringClock {
    /// An episode stays "Out now" this long after it airs.
    static let outNowWindow: TimeInterval = 6 * 3600

    /// Of `dates` (oldest first), the one a show's row is about at `now`: an
    /// episode out in the last six hours, else the next one to come. Nil
    /// when nothing is out now or still to come.
    static func headline(_ dates: [Date], at now: Date) -> Int? {
        if let i = dates.lastIndex(where: { $0 <= now }), now.timeIntervalSince(dates[i]) < outNowWindow { return i }
        return dates.firstIndex { $0 > now }
    }
}

/// The tracked shows with an episode out now or still to come, as the
/// Airing widget shows them.
struct AiringSnapshot: Codable, Equatable {
    struct Episode: Codable, Equatable {
        /// "S1 · E5", "E12".
        var label: String
        var title: String?
        var airDate: Date
        /// The network's date ("2026-11-13") when there's no time for it
        /// (1.23.0, as the app has had since 1.22.6): the widget shows the
        /// day only, not TVmaze's stand-in 12:00 UTC (11 pm in Melbourne).
        var day: String? = nil

        /// The day at the start of `day` in `calendar`, for a day-only episode.
        func localDay(_ calendar: Calendar = .autoupdatingCurrent) -> Date? {
            guard let day else { return nil }
            let p = day.prefix(10).split(separator: "-").compactMap { Int($0) }
            guard p.count == 3 else { return nil }
            return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
        }
    }

    struct Item: Codable, Equatable, Identifiable {
        /// The tracked show's id: what folio://track?id= opens.
        var id: String
        var name: String
        /// The network or streaming service ("HBO", "Crunchyroll").
        var network: String?
        /// Out in the last six hours or still to come, soonest first.
        var episodes: [Episode]
        /// A poster's file name next to the snapshot, if there is one.
        var picture: String?

        /// The episode the widget shows at `date` (AiringClock.headline).
        func headline(at date: Date) -> Episode? {
            AiringClock.headline(episodes.map(\.airDate), at: date).map { episodes[$0] }
        }
    }

    /// One widget row at a moment: the show and the episode it's about.
    struct Row: Identifiable {
        var item: Item
        var episode: Episode
        var isOut: Bool
        var id: String { item.id }
    }

    var items: [Item]
    /// 1.24.0 (nil in older snapshots): how many shows are tracked, and the
    /// episodes out in the last week, newest first, each with where you can
    /// watch it if Folio found it in your library or on a server.
    var tracked: Int? = nil
    var recent: [Recent]? = nil

    /// An episode that's out (the Out now widget).
    struct Recent: Codable, Equatable, Identifiable {
        var showID: String
        var show: String
        var label: String
        var title: String?
        var airDate: Date
        var season: Int?
        var number: Int?
        /// "in your library", "on Real-Debrid"; nil when Folio didn't find it.
        var available: String?
        var picture: String?
        var id: String { showID + "|" + label }
    }

    /// The large widget shows seven; a few more so one that ends doesn't leave a gap.
    static let limit = 12
    static let widgetKind = "Airing"
    /// Posters are kept this big on their long side. 240 (a medium widget's
    /// row at 3x) was stretched three times over the Airing Day widget,
    /// which fills a small widget with it (1.28.4: 600, 400 wide, for its
    /// 510-pixel square on a Pro Max; about 1 MB each drawn, so the large
    /// widget's seven stay well within a widget's memory).
    static let picturePixels: CGFloat = 600

    private static let fileName = "airing.json"

    /// The rows at `date`: episodes out now first (newest first), then the
    /// ones to come, soonest first. Shows with neither are left out.
    func rows(at date: Date) -> [Row] {
        let rows = items.compactMap { item in item.headline(at: date).map { Row(item: item, episode: $0, isOut: $0.airDate <= date) } }
        return rows.sorted { a, b in
            if a.isOut != b.isOut { return a.isOut }
            return a.isOut ? a.episode.airDate > b.episode.airDate : a.episode.airDate < b.episode.airDate
        }
    }

    /// When the widget's picture changes without the app: now, each air
    /// time ("in 2 h" becomes "Out now"), and the end of each "Out now".
    func timelineDates(from now: Date, limit: Int = 60, calendar: Calendar = .autoupdatingCurrent) -> [Date] {
        var dates = Set<Date>([now])
        var last = now
        for e in items.flatMap(\.episodes) {
            if e.airDate > now { dates.insert(e.airDate) }
            let gone = e.airDate.addingTimeInterval(AiringClock.outNowWindow)
            if gone > now { dates.insert(gone) }
            last = max(last, e.airDate)
        }
        // Each midnight up to the last episode too (1.23.0): "Tomorrow"
        // becomes "Today" when the day changes, not at the next air time
        // (review, 5 Nov: "Tomorrow 9:00 PM" all of the day itself).
        var midnight = calendar.startOfDay(for: now)
        for _ in 0..<14 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: midnight), next <= last else { break }
            dates.insert(next)
            midnight = next
        }
        return Array(dates.sorted().prefix(limit))
    }

    /// The last snapshot written; nil when there is none or no group.
    static func read(from dir: URL?) -> AiringSnapshot? {
        guard let dir, let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(AiringSnapshot.self, from: data)
    }

    func write(to dir: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// The same through WidgetStore (1.23.0): the App Group's folder, or the
    /// Keychain when the install has no group.
    static func read(from store: WidgetStore?) -> AiringSnapshot? {
        guard let data = store?.read(fileName) else { return nil }
        return try? JSONDecoder().decode(AiringSnapshot.self, from: data)
    }

    func write(to store: WidgetStore) throws {
        try store.write(try JSONEncoder().encode(self), Self.fileName)
    }
}

/// folio://track?id=<tracked show id>: the widget's and the notifications'
/// link to a show's tracking page. Ids are "tt…", "mal:…" and the like;
/// encoded anyway, as ContinueLink does.
enum TrackLink {
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// The Tracking list (1.24.0): the Airing widgets with nothing tracked.
    static let list = URL(string: "folio://track")!

    /// folio://aired?id=<show>&s=2&e=1 (1.24.0): plays an episode that's out
    /// from wherever Folio finds it then (the Out now widget's Play). The
    /// widget carries the show and the episode's number, never a file's
    /// address; Folio looks the file up when it's tapped.
    static func aired(id: String, season: Int?, episode: Int) -> URL {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        return URL(string: "folio://aired?id=\(encoded)" + (season.map { "&s=\($0)" } ?? "") + "&e=\(episode)") ?? list
    }

    static func url(id: String) -> URL {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        return URL(string: "folio://track?id=" + encoded) ?? URL(string: "folio://track")!
    }

    static func id(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "folio", url.host?.lowercased() == "track",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = comps.queryItems?.first(where: { $0.name == "id" })?.value, !id.isEmpty else { return nil }
        return id
    }
}
