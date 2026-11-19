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

/// The rules (1.25.0), as pure functions so they can be tested:
/// - only kinds that are on, and not resting after being dismissed;
/// - each moment once;
/// - nothing in quiet hours, and with quiet hours off nothing at night;
/// - at most `maxPerDay` a day, two hours apart, and a group's weekly limit;
/// - the same show at most once in three days;
/// - a moment of its own keeps it; the others are dealt out over the days
///   of their range, each day getting its first before any gets its second.
///
/// (0.90.0) Until now the others took the first free day at your usual
/// time, and the next one that day two hours later: with five a day
/// allowed, the week's eight or nine went out on the first evening and
/// night, and the next three days had none. Now the days are filled in
/// turn, nearest first, and a day's times are spread over the waking hours.
enum NotifyPlanner {
    static let horizonDays = 14
    static let sameShowGap: TimeInterval = 3 * 86400
    static let sameDayGap: TimeInterval = 2 * 3600
    /// (0.90.0) A time today is used when it's at least this far off.
    static let todayLead: TimeInterval = 15 * 60
    /// (0.90.0) With quiet hours off, nothing after 22:30 or before 08:00,
    /// and a day's times run from 09:00 to 22:00.
    static let nightStart = 22 * 60 + 30
    static let nightEnd = 8 * 60
    static let plainDay = 9 * 60...22 * 60

    struct Rules {
        var now: Date
        var calendar: Calendar = .autoupdatingCurrent
        var quiet: QuietHours = .standard
        var maxPerDay = 1
        /// Minutes from midnight: when flexible ones come.
        var preferredMinute = 19 * 60
        var sent: [NotifySent] = []
        var allowed: (NotifyKind) -> Bool = { _ in true }
        /// (0.90.0) A group's weekly limit. NotifyCenter gives the one that
        /// grows with the daily setting (`NotifyGroup.weeklyMax(perDay:)`).
        var weeklyMax: (NotifyGroup) -> Int? = { $0.weeklyMax }
    }

    /// (0.90.0) Why a candidate wasn't planned, for the log's one line.
    enum Held: String, CaseIterable {
        case off, sent, past, beyond, quiet, dayFull, tooClose, weekly, sameShow, noSlot

        var words: String {
            switch self {
            case .off: return "switched off or resting"
            case .sent: return "already sent"
            case .past: return "moment passed"
            case .beyond: return "over two weeks off"
            case .quiet: return "quiet hours or night"
            case .dayFull: return "day full"
            case .tooClose: return "under two hours from another"
            case .weekly: return "group's weekly limit"
            case .sameShow: return "same show within three days"
            case .noSlot: return "no free time in its days"
            }
        }
    }

    /// (0.90.0) What `plan` decided: the chosen ones in time order, and how
    /// many of the rest each reason held back.
    struct Plan {
        var chosen: [NotifyChosen] = []
        var held: [Held: Int] = [:]
    }

    static func choose(_ candidates: [NotifyCandidate], _ r: Rules) -> [NotifyChosen] {
        plan(candidates, r).chosen
    }

    static func plan(_ candidates: [NotifyCandidate], _ r: Rules) -> Plan {
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
        var plan = Plan()
        let order = Dictionary(uniqueKeysWithValues: NotifyKind.allCases.enumerated().map { ($1, $0) })
        var seen = Set<String>()
        var unique: [NotifyCandidate] = []
        for c in candidates {
            if !r.allowed(c.kind) { plan.held[.off, default: 0] += 1 }
            else if sentKeys.contains(c.key) { plan.held[.sent, default: 0] += 1 }
            else if seen.insert(c.key).inserted { unique.append(c) }
        }
        let fixed = unique.filter { $0.fire != nil }.sorted {
            let a = WatchLog.dayKey($0.fire!, calendar: cal), b = WatchLog.dayKey($1.fire!, calendar: cal)
            return a != b ? a < b : order[$0.kind]! < order[$1.kind]!
        }
        // The ones with the least time left choose first, so a rainy day's
        // or yesterday's joke isn't crowded out by one with all week (0.90.0).
        var flexible = unique.filter { $0.fire == nil && $0.window != nil }.sorted {
            let a = $0.window!.upperBound, b = $1.window!.upperBound
            return a != b ? a < b : order[$0.kind]! < order[$1.kind]!
        }

        // (0.90.0) The ones with a moment of their own that are in the plan
        // only until another of their group needs their place in its week.
        var spare: [String: [NotifyChosen]] = [:]  // group|week → in date order

        /// Why `c` can't come at `t`; nil when it can. `lead`: how far off
        /// `t` has to be. `overSpare`: the spare ones of its group's week don't count.
        func block(_ c: NotifyCandidate, at t: Date, lead: TimeInterval, overSpare: Bool = false) -> Held? {
            if t <= r.now.addingTimeInterval(lead) { return .past }
            if t > horizon { return .beyond }
            if r.quiet.contains(t, calendar: cal) || night(t, r) { return .quiet }
            let taken = times[WatchLog.dayKey(t, calendar: cal)] ?? []
            if taken.count >= r.maxPerDay { return .dayFull }
            if !taken.allSatisfy({ abs($0.timeIntervalSince(t)) >= sameDayGap }) { return .tooClose }
            if let max = r.weeklyMax(c.kind.group) {
                let week = weekKey(c.kind.group, t, cal)
                if weekly[week, default: 0] - (overSpare ? spare[week]?.count ?? 0 : 0) >= max { return .weekly }
            }
            if let k = c.showKey, shows.contains(where: { $0.key == k && abs($0.at.timeIntervalSince(t)) < sameShowGap }) { return .sameShow }
            return nil
        }
        func take(_ c: NotifyCandidate, at t: Date) {
            plan.chosen.append(NotifyChosen(candidate: c, fire: t))
            times[WatchLog.dayKey(t, calendar: cal), default: []].append(t)
            weekly[weekKey(c.kind.group, t, cal), default: 0] += 1
            if let k = c.showKey { shows.append((k, t)) }
        }

        // The ones with a moment of their own come first, in date order.
        // (0.90.0) Of a group with a weekly limit, the first half of the
        // limit (rounded up) is theirs; any more of them are spare, and
        // give way, latest first, when one of the others needs the place.
        // Friday's and Saturday's jokes used to take the whole of Just for
        // fun's week, and Tuesday's rain got nothing.
        var own: [String: Int] = [:]
        for c in fixed {
            let t = c.fire!
            if let why = block(c, at: t, lead: 60) {
                plan.held[why, default: 0] += 1
                continue
            }
            take(c, at: t)
            guard let max = r.weeklyMax(c.kind.group) else { continue }
            let week = weekKey(c.kind.group, t, cal)
            if own[week, default: 0] < (max + 1) / 2 { own[week, default: 0] += 1 } else { spare[week, default: []].append(plan.chosen[plan.chosen.count - 1]) }
        }
        /// A flexible one was taken over the spare ones: the latest of them goes.
        func giveWay(for c: NotifyCandidate, at t: Date) {
            let week = weekKey(c.kind.group, t, cal)
            guard let max = r.weeklyMax(c.kind.group), weekly[week, default: 0] > max, let gone = spare[week]?.popLast() else { return }
            plan.chosen.removeAll { $0.candidate.key == gone.candidate.key }
            times[WatchLog.dayKey(gone.fire, calendar: cal)]?.removeAll { $0 == gone.fire }
            weekly[week, default: 0] -= 1
            if let k = gone.candidate.showKey, let i = shows.firstIndex(where: { $0.key == k && $0.at == gone.fire }) { shows.remove(at: i) }
            plan.held[.weekly, default: 0] += 1
        }

        // (0.90.0) The others, dealt out a day at a time: every day (nearest
        // first) gets its first before any day gets its second, and so on
        // up to the daily maximum. What was already sent today counts, so
        // planning again in the evening doesn't top today up first.
        let slots = slotMinutes(r)
        let today = cal.startOfDay(for: r.now)
        let days = (0...horizonDays).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
        /// The first of the day's times that `c` can take, in the order they're filled.
        func slot(_ c: NotifyCandidate, on day: Date) -> Date? {
            guard let w = c.window else { return nil }
            for m in slots {
                guard let t = cal.date(byAdding: .minute, value: m, to: day), w.contains(t) else { continue }
                if block(c, at: t, lead: todayLead, overSpare: true) == nil { return t }
            }
            return nil
        }
        if !flexible.isEmpty {
            for level in 1...max(1, r.maxPerDay) {
                for day in days where (times[WatchLog.dayKey(day, calendar: cal)]?.count ?? 0) < level {
                    for (i, c) in flexible.enumerated() {
                        guard let t = slot(c, on: day) else { continue }
                        take(c, at: t)
                        giveWay(for: c, at: t)
                        flexible.remove(at: i)
                        break
                    }
                }
                if flexible.isEmpty { break }
            }
        }

        // What held each of the others back: the reason that covers all its
        // days if there is one (its group's week, its show), else the
        // commonest thing in the way.
        for c in flexible {
            guard let w = c.window else { continue }
            var why: [Held: Int] = [:]
            for day in days {
                for m in slots {
                    guard let t = cal.date(byAdding: .minute, value: m, to: day), w.contains(t) else { continue }
                    if let b = block(c, at: t, lead: todayLead, overSpare: true) { why[b, default: 0] += 1 }
                }
            }
            let ranked: [Held] = [.weekly, .sameShow, .dayFull, .tooClose, .quiet, .beyond]
            plan.held[ranked.first { why[$0] != nil } ?? .noSlot, default: 0] += 1
        }
        plan.chosen.sort { $0.fire < $1.fire }
        return plan
    }

    /// (0.90.0) With quiet hours off there's still a night: nothing after
    /// 22:30 or before 08:00 (a 01:30 one went out on 17 Nov). 22:30 itself
    /// is allowed: it's when the thriller before bed comes.
    static func night(_ t: Date, _ r: Rules) -> Bool {
        guard r.quiet.isOff else { return false }
        let c = r.calendar.dateComponents([.hour, .minute], from: t)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return m > nightStart || m < nightEnd
    }

    /// (0.90.0) The hours a day's times are spread over, in minutes from
    /// midnight: from an hour after quiet hours end to an hour before they
    /// start; 09:00 to 22:00 with quiet hours off, or when they aren't
    /// overnight and leave no clear day.
    static func wakingWindow(_ q: QuietHours) -> ClosedRange<Int> {
        guard !q.isOff else { return plainDay }
        if q.start > q.end, q.start - 60 - (q.end + 60) >= 120 { return q.end + 60...q.start - 60 }
        // Quiet hours inside one day (midnight to 8, say): the day after them.
        if q.start < q.end, q.end + 60 <= 20 * 60 { return q.end + 60...22 * 60 }
        return plainDay
    }

    /// (0.90.0) A day's times, in the order they're filled: the usual time
    /// first, then one step after it, one before, two after, two before…
    /// as far as the waking hours go. The step is the waking hours shared
    /// among the daily maximum, in half hours, at least two hours and at
    /// most three: 3 h up to four a day, 2½ h at five (09:00–22:00).
    static func slotMinutes(_ r: Rules) -> [Int] {
        let w = wakingWindow(r.quiet)
        let p = r.preferredMinute
        let lo = min(w.lowerBound, p), hi = max(w.upperBound, p)
        let share = (w.upperBound - w.lowerBound) / max(1, r.maxPerDay) / 30 * 30
        let step = min(180, max(Int(sameDayGap) / 60, share))
        var out = [p]
        var k = 1
        while p + k * step <= hi || p - k * step >= lo {
            if p + k * step <= hi { out.append(p + k * step) }
            if p - k * step >= lo { out.append(p - k * step) }
            k += 1
        }
        return out
    }

    // MARK: What was planned before

    /// (0.90.0) One that was planned earlier, with what it said, as
    /// NotifyCenter saved it.
    struct Earlier: Equatable {
        var key: String
        var kind: NotifyKind
        var at: Date
        var showKey: String?
        var facts: [String: String] = [:]
        var link: String?
        var image: NotifyImage?
        var reason = ""
        /// Its text was saved with it (plans made before 0.90.0 have none).
        var saved = true
        /// Taken back because Folio came to the front (not sent, not replaced).
        var held = false
    }

    struct Recovered {
        var candidates: [NotifyCandidate]
        /// One per earlier one kept or let go, for the log.
        var notes: [String] = []
    }

    /// (0.90.0) Two ways a planned notification used to be lost without a word.
    ///
    /// Its facts went on a refresh: "New titles worth knowing" was planned
    /// at 04:02 for 17:30 and gone at 10:02, after new charts had nothing
    /// to compare. One planned for the next 24 hours stays at its time when
    /// its text is still true enough (`outlivesRefresh`), nothing newer of
    /// its kind has come, and it isn't about a title you've since watched.
    ///
    /// Its moment came while Folio was in front, after it had been taken
    /// back: it's planned again for the next free time within `holdsFor`
    /// of its moment, with today's facts if Folio still has them, else
    /// (for the kinds that don't hang on what you do) with the text it had.
    static func recover(_ fresh: [NotifyCandidate], earlier: [Earlier], now: Date, sentKeys: Set<String> = [],
                        watched: Set<String> = []) -> Recovered {
        var out = Recovered(candidates: fresh)
        var done = Set<String>()
        func rebuilt(_ e: Earlier, fire: Date?, window: ClosedRange<Date>?) -> NotifyCandidate {
            NotifyCandidate(kind: e.kind, key: e.key, fire: fire, window: window, facts: e.facts, link: e.link,
                            showKey: e.showKey, image: e.image, reason: e.reason)
        }
        for e in earlier where !sentKeys.contains(e.key) && done.insert(e.key).inserted {
            let name = e.kind.rawValue
            let i = out.candidates.firstIndex { $0.key == e.key }
            if e.at <= now {
                // Not held: it went out. Held: its moment came with Folio in front.
                guard e.held else { continue }
                if let i, out.candidates[i].fire == nil || out.candidates[i].fire! > now { continue }
                guard let keep = e.kind.holdsFor ?? (e.kind.outlivesRefresh ? 86400 : nil), e.at.addingTimeInterval(keep) > now else {
                    out.notes.append("\(name) let go: its moment came while Folio was open, and it's no use later")
                    continue
                }
                let window = now...e.at.addingTimeInterval(keep)
                if let i {
                    out.candidates[i].fire = nil
                    out.candidates[i].window = window
                    out.notes.append("\(name) moved on: its moment came while Folio was open")
                } else if e.saved, e.kind.keptWhileOpen || e.kind.outlivesRefresh {
                    // As below: not beside a newer one of its kind, and not
                    // about a title watched since (a pick held while Folio
                    // was open, watched there, then sent: the review's case).
                    if fresh.contains(where: { $0.kind == e.kind }) {
                        out.notes.append("\(name) let go: its moment came while Folio was open, and a newer one of its kind took its place")
                        continue
                    }
                    if watched.contains(where: { id in e.key.split(separator: ".").contains { $0 == id } }) {
                        out.notes.append("\(name) let go: its moment came while Folio was open, and you've watched it since")
                        continue
                    }
                    out.candidates.append(rebuilt(e, fire: nil, window: window))
                    out.notes.append("\(name) moved on with the text it had: its moment came while Folio was open")
                } else {
                    out.notes.append("\(name) let go: its moment came while Folio was open, and it's no longer true")
                }
            } else if i == nil {
                let why: String?
                if !e.kind.outlivesRefresh { why = "its facts are gone" }
                else if !e.saved { why = "its facts are gone, and its text wasn't saved" }
                else if e.at > now.addingTimeInterval(86400) { why = "its facts are gone, and it was over a day off" }
                else if fresh.contains(where: { $0.kind == e.kind }) { why = "a newer one of its kind took its place" }
                else if watched.contains(where: { id in e.key.split(separator: ".").contains { $0 == id } }) { why = "you've watched it since" }
                else { why = nil }
                if let why {
                    out.notes.append("\(name) let go: \(why)")
                } else {
                    out.candidates.append(rebuilt(e, fire: e.at, window: nil))
                    out.notes.append("\(name) kept at its time: its facts are gone from the new data, but it was true when planned")
                }
            }
        }
        return out
    }

    /// (0.90.0) The line under "Up to … a Day" in Settings.
    static func plannedLine(sentToday: Int, today: Int, tomorrow: Int) -> String {
        if sentToday + today + tomorrow == 0 { return "Nothing planned for today or tomorrow." }
        var first: [String] = []
        if sentToday > 0 { first.append("\(sentToday) sent") }
        if today > 0 { first.append("\(today) planned") }
        return "Today: \(first.isEmpty ? "none planned" : first.joined(separator: ", ")). Tomorrow: \(tomorrow == 0 ? "none planned" : "\(tomorrow) planned")."
    }

    /// (0.90.0) The log's line for one planning run: how many a day, and
    /// what held the rest back.
    static func summary(_ p: Plan, candidates: Int, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE d"
        var perDay: [(day: String, n: Int)] = []
        for c in p.chosen {
            let d = f.string(from: c.fire)
            if perDay.last?.day == d { perDay[perDay.count - 1].n += 1 } else { perDay.append((d, 1)) }
        }
        let held = Held.allCases.compactMap { h in p.held[h].map { "\($0) \(h.words)" } }
        return "\(p.chosen.count) of \(candidates) candidates planned"
            + (perDay.isEmpty ? "" : " (" + perDay.map { "\($0.day): \($0.n)" }.joined(separator: ", ") + ")")
            + (held.isEmpty ? "" : "; held back: " + held.joined(separator: ", "))
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
