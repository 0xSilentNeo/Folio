import Foundation

/// Time spent watching, a day at a time, kept on the phone (1.24.0): the
/// Your week widget and the engagement notifications (a late night, a binge)
/// read it. Only what's needed for those: seconds, which episodes, films and
/// shows, and when. Never sent anywhere. 35 days are kept.
struct WatchDay: Codable, Equatable {
    /// "2026-11-06": the day in the phone's calendar when the time was watched.
    var day: String
    var seconds: Double = 0
    /// Of `seconds`, the time between midnight and 5 am.
    var lateSeconds: Double = 0
    /// The latest moment watched between midnight and 5 am, if any.
    var lateUntil: Date?
    /// History ids of the episodes watched that day.
    var episodes: [String] = []
    /// History ids of the films.
    var films: [String] = []
    /// The episodes' shows (HistoryStore.showKey) and their names.
    var shows: [String: String] = [:]
    /// Episodes of each show that day (show key: ids).
    var showEpisodes: [String: [String]] = [:]
    var last: Date?
    /// Seconds watched in each hour of the day ("20": 1800), for when the
    /// notifications come (1.25.0). Optional: older logs don't have it.
    var hours: [String: Double]?
}

@MainActor
final class WatchLog {
    static let shared = WatchLog()

    private(set) var days: [WatchDay]
    private static let keep = 35
    private var dirty = false
    private let url: URL?

    init(url: URL? = WatchLog.defaultURL, days: [WatchDay]? = nil) {
        self.url = url
        if let days {
            self.days = days
        } else if let url, let data = try? Data(contentsOf: url), let d = try? JSONDecoder().decode([WatchDay].self, from: data) {
            self.days = d
        } else {
            self.days = []
        }
    }

    nonisolated static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("watchlog.json")
    }

    nonisolated static func dayKey(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `seconds` of `id` watched up to `at`. An episode counts for its show.
    func add(seconds: Double, at: Date = Date(), id: String, isEpisode: Bool, showKey: String?, showName: String?, calendar: Calendar = .autoupdatingCurrent) {
        guard seconds > 0, seconds < 3600 else { return }
        let key = Self.dayKey(at, calendar: calendar)
        var d = days.last(where: { $0.day == key }) ?? WatchDay(day: key)
        d.seconds += seconds
        let hour = calendar.component(.hour, from: at)
        d.hours = (d.hours ?? [:]).merging(["\(hour)": seconds], uniquingKeysWith: +)
        if hour < 5 {
            d.lateSeconds += seconds
            d.lateUntil = max(d.lateUntil ?? .distantPast, at)
        }
        if isEpisode {
            if !d.episodes.contains(id) { d.episodes.append(id) }
            if let showKey {
                if let showName { d.shows[showKey] = showName }
                var eps = d.showEpisodes[showKey] ?? []
                if !eps.contains(id) { eps.append(id) }
                d.showEpisodes[showKey] = eps
            }
        } else if !d.films.contains(id) {
            d.films.append(id)
        }
        d.last = at
        if let i = days.lastIndex(where: { $0.day == key }) { days[i] = d } else { days.append(d); days.sort { $0.day < $1.day } }
        if days.count > Self.keep { days.removeFirst(days.count - Self.keep) }
        dirty = true
    }

    func day(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> WatchDay? {
        let key = Self.dayKey(date, calendar: calendar)
        return days.last { $0.day == key }
    }

    struct Week: Equatable {
        var seconds: Double
        var episodes: Int
        var films: Int
        var shows: Int
        /// Seconds on each of the last seven days, oldest first (today last).
        var perDay: [Double]
        /// The first day the log has, when it's inside this week: the week
        /// is counted from then.
        var countingSince: Date?
    }

    /// The last seven days, today included.
    func week(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> Week {
        let today = calendar.startOfDay(for: now)
        let dates = (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        let keys = dates.map { Self.dayKey($0, calendar: calendar) }
        let inWeek = days.filter { keys.contains($0.day) }
        let perDay = keys.map { k in inWeek.first { $0.day == k }?.seconds ?? 0 }
        var since: Date?
        if let first = days.first?.day, let i = keys.firstIndex(of: first), i > 0 { since = dates[i] }
        if days.isEmpty { since = today }
        return Week(seconds: inWeek.reduce(0) { $0 + $1.seconds },
                    episodes: Set(inWeek.flatMap(\.episodes)).count,
                    films: Set(inWeek.flatMap(\.films)).count,
                    shows: Set(inWeek.flatMap { $0.shows.keys }).count,
                    perDay: perDay, countingSince: since)
    }

    /// The last time anything was watched.
    var lastWatched: Date? { days.compactMap(\.last).max() }

    func flush() {
        guard dirty, let url else { return }
        dirty = false
        let data = try? JSONEncoder().encode(days)
        // One after another (1.30.2): as detached tasks, an older log could
        // be written after a newer one.
        Self.writes.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data?.write(to: url, options: .atomic)
        }
    }

    private nonisolated static let writes = DispatchQueue(label: "folio.watchlog.save", qos: .utility)
}
