import Foundation

/// What a notification shows besides its text: a poster or still.
enum NotifyImage: Equatable, Codable {
    /// An image address (a poster from IMDb or an add-on).
    case url(String)
    /// A history entry's picture (its artwork, else its library title's poster).
    case history(String)
    /// A library file's title poster.
    case file(String)
}

/// Something worth saying, before the rules pick what goes out (1.25.0).
struct NotifyCandidate: Equatable {
    var kind: NotifyKind
    /// Unique per moment: each is sent once (a paused episode nudges once,
    /// a title trends once).
    var key: String
    /// A moment of its own (Friday 18:00, two days after you paused)…
    var fire: Date?
    /// …or any day in this range, at your usual time.
    var window: ClosedRange<Date>?
    var facts: [String: String]
    /// folio:// link a tap opens; nil opens Folio.
    var link: String?
    /// For "the same show at most once in three days".
    var showKey: String?
    var image: NotifyImage?
    /// Why it was planned, for the sent list.
    var reason: String

    init(kind: NotifyKind, key: String, fire: Date? = nil, window: ClosedRange<Date>? = nil, facts: [String: String] = [:],
         link: String? = nil, showKey: String? = nil, image: NotifyImage? = nil, reason: String) {
        self.kind = kind
        self.key = key
        self.fire = fire
        self.window = window
        self.facts = facts
        self.link = link
        self.showKey = showKey
        self.image = image
        self.reason = reason
    }
}

/// A candidate with its moment, chosen by the rules.
struct NotifyChosen: Equatable {
    var candidate: NotifyCandidate
    var fire: Date
}

/// A notification that went out (or was due while Folio wasn't running).
struct NotifySent: Codable, Equatable {
    var key: String
    var kind: NotifyKind
    var at: Date
    var showKey: String?
}

/// The rules (1.25.0), as a pure function so they can be tested:
/// - only kinds that are on, and not resting after being dismissed;
/// - each moment once;
/// - nothing in quiet hours;
/// - at most `maxPerDay` a day, two hours apart, and a group's weekly limit;
/// - the same show at most once in three days;
/// - a moment of its own keeps it; the others take the first free day in
///   their range at your usual time.
enum NotifyPlanner {
    static let horizonDays = 14
    static let sameShowGap: TimeInterval = 3 * 86400
    static let sameDayGap: TimeInterval = 2 * 3600

    struct Rules {
        var now: Date
        var calendar: Calendar = .autoupdatingCurrent
        var quiet: QuietHours = .standard
        var maxPerDay = 1
        /// Minutes from midnight: when flexible ones come.
        var preferredMinute = 19 * 60
        var sent: [NotifySent] = []
        var allowed: (NotifyKind) -> Bool = { _ in true }
    }

    static func choose(_ candidates: [NotifyCandidate], _ r: Rules) -> [NotifyChosen] {
        let cal = r.calendar
        let horizon = r.now.addingTimeInterval(TimeInterval(horizonDays) * 86400)
        let sentKeys = Set(r.sent.map(\.key))
        var times: [String: [Date]] = [:]          // day → moments taken
        var weekly: [String: Int] = [:]            // group|week → count
        var shows: [(key: String, at: Date)] = r.sent.compactMap { s in s.showKey.map { ($0, s.at) } }
        for s in r.sent where !s.kind.group.essential {
            times[WatchLog.dayKey(s.at, calendar: cal), default: []].append(s.at)
            weekly[weekKey(s.kind.group, s.at, cal), default: 0] += 1
        }
        let order = Dictionary(uniqueKeysWithValues: NotifyKind.allCases.enumerated().map { ($1, $0) })
        let usable = candidates.filter { r.allowed($0.kind) && !sentKeys.contains($0.key) }
        var seen = Set<String>()
        let unique = usable.filter { seen.insert($0.key).inserted }
        let fixed = unique.filter { $0.fire != nil }.sorted {
            let a = WatchLog.dayKey($0.fire!, calendar: cal), b = WatchLog.dayKey($1.fire!, calendar: cal)
            return a != b ? a < b : order[$0.kind]! < order[$1.kind]!
        }
        let flexible = unique.filter { $0.fire == nil && $0.window != nil }.sorted { order[$0.kind]! < order[$1.kind]! }

        var out: [NotifyChosen] = []
        func fits(_ c: NotifyCandidate, at t: Date) -> Bool {
            guard t > r.now.addingTimeInterval(60), t <= horizon, !r.quiet.contains(t, calendar: cal) else { return false }
            let day = WatchLog.dayKey(t, calendar: cal)
            let taken = times[day] ?? []
            guard taken.count < r.maxPerDay, taken.allSatisfy({ abs($0.timeIntervalSince(t)) >= sameDayGap }) else { return false }
            if let max = c.kind.group.weeklyMax, weekly[weekKey(c.kind.group, t, cal), default: 0] >= max { return false }
            if let k = c.showKey, shows.contains(where: { $0.key == k && abs($0.at.timeIntervalSince(t)) < sameShowGap }) { return false }
            return true
        }
        func take(_ c: NotifyCandidate, at t: Date) {
            out.append(NotifyChosen(candidate: c, fire: t))
            times[WatchLog.dayKey(t, calendar: cal), default: []].append(t)
            weekly[weekKey(c.kind.group, t, cal), default: 0] += 1
            if let k = c.showKey { shows.append((k, t)) }
        }
        for c in fixed where fits(c, at: c.fire!) { take(c, at: c.fire!) }
        for c in flexible {
            guard let w = c.window else { continue }
            var day = cal.startOfDay(for: max(w.lowerBound, r.now))
            let last = min(w.upperBound, horizon)
            while day <= last {
                // The usual time, or (a second one that day) two hours after the last.
                var t = cal.date(byAdding: .minute, value: r.preferredMinute, to: day) ?? day
                if let latest = times[WatchLog.dayKey(day, calendar: cal)]?.max(), latest >= t { t = latest.addingTimeInterval(sameDayGap) }
                if t >= w.lowerBound, t <= w.upperBound, fits(c, at: t) {
                    take(c, at: t)
                    break
                }
                guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return out.sorted { $0.fire < $1.fire }
    }

    static func weekKey(_ g: NotifyGroup, _ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
        return "\(g.rawValue)|\(c.yearForWeekOfYear ?? 0)-\(c.weekOfYear ?? 0)"
    }

    /// When the flexible ones come: half an hour before you usually start
    /// watching (the median of the last three weeks' first hour watched,
    /// from 5 am on), once there are three days to go by; else 19:00. Never
    /// in quiet hours: then an hour before they start.
    static func preferredMinute(firstHours: [Int], quiet: QuietHours) -> Int {
        var m = 19 * 60
        if firstHours.count >= 3 {
            let s = firstHours.sorted()
            m = s[s.count / 2] * 60 - 30
        }
        m = max(m, 9 * 60)
        let probe = QuietHours(start: quiet.start, end: quiet.end)
        var c = DateComponents()
        c.hour = m / 60
        c.minute = m % 60
        let cal = Calendar(identifier: .gregorian)
        if let d = cal.date(from: c), probe.contains(d, calendar: cal) {
            m = (quiet.start - 60 + 24 * 60) % (24 * 60)
        }
        return m
    }

    /// Test (1.25.0): every kind, 20 seconds apart from 20 seconds on.
    static func testTimes(_ count: Int, from now: Date) -> [Date] {
        (0..<count).map { now.addingTimeInterval(20 + Double($0) * 20) }
    }
}
