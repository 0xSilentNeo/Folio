import Foundation

/// The engagement notifications (1.24.0): now and then a line about what
/// you're watching, cheeky and sometimes a little dark, to bring you back to
/// it. Local only: planned on the phone from its own history, never sent
/// anywhere. The texts are the ones you picked on 6 Nov.
///
/// Rules:
/// - At most one a day, counting the tracker's new-episode notifications.
/// - None at night: only between 9:00 and 22:00 (`quietStart`, `quietEnd`).
/// - The same show at most once in three days.
/// - Each one only once (by its id): a paused episode nudges once, and again
///   only after you've played it again and left it again.
/// - Nothing is guessed: "episodes left" counts only a show whose files are
///   in your library (a server or a Discover show can have more than Folio
///   knows of), and a moment whose facts aren't known isn't planned.
///
/// This file is the plan alone (state in, notifications out), so it can be
/// tested; EngagementNotifications gathers the state and schedules it.
enum EngagePlanner {
    /// Quiet from 22:00 to 9:00, the phone's time.
    static let quietStart = 22
    static let quietEnd = 9
    static let sameShowGap: TimeInterval = 3 * 86400
    /// Planned this far ahead: Folio may not run for days, and a chain is
    /// needed for "a week away" and later.
    static let horizonDays = 14
    /// Episodes in a day that make a binge.
    static let bingeEpisodes = 4

    enum Moment: String, CaseIterable {
        case lateNight, binge, cliffhanger, paused, filmNearlyDone, showNearlyDone, friday, weekAway, houseplants

        /// Which goes first when two would come the same day.
        var priority: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    }

    /// A Continue Watching card (or the episode finished last) as the plan needs it.
    struct Entry: Equatable {
        /// The history id: what a tap plays.
        var id: String
        /// The show's name for an episode, the film's for a film.
        var name: String
        /// The show (HistoryStore.showKey) for an episode; nil for a film.
        var showKey: String?
        var position: Double
        var duration: Double
        var updated: Date
        var finished: Bool
        /// Episodes still to watch in your library, this one included when
        /// it isn't finished; nil when the files aren't in the library.
        var episodesLeft: Int?
    }

    struct State {
        /// Continue Watching, latest first.
        var continueWatching: [Entry] = []
        /// The last thing watched, when it was an episode watched to its end.
        var lastFinished: Entry?
        /// When anything was last watched.
        var lastWatched: Date?
        /// The watch log's days (WatchLog).
        var days: [WatchDay] = []
        /// The latest night past midnight: until when, and what.
        var lateNight: (until: Date, name: String, showKey: String?)?
        /// Days (WatchLog.dayKey) with another notification of Folio's already.
        var busyDays: Set<String> = []
        /// What was sent already.
        var sent: [Sent] = []
    }

    /// A notification that went out (or was due while Folio wasn't running).
    struct Sent: Codable, Equatable {
        var id: String
        var at: Date
        var showKey: String?
    }

    struct Planned: Equatable {
        var id: String
        var moment: Moment
        var fire: Date
        var body: String
        /// folio://continue?id=… (with &next=1 for the episode after), or nil: Folio opens.
        var link: String?
        /// For the three-days rule.
        var showKey: String?
        /// What the wording fills in (1.25.0, NotifyWording).
        var facts: [String: String] = [:]
    }

    static func isQuiet(_ date: Date, calendar: Calendar) -> Bool {
        let h = calendar.component(.hour, from: date)
        return h >= quietStart || h < quietEnd
    }

    // MARK: Plan

    static func plan(_ s: State, now: Date, calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> [Planned] {
        choose(candidates(s, now: now, calendar: calendar, locale: locale), s, now: now, calendar: calendar)
    }

    /// Every moment the state has, before the rules (1.25.0: the engine
    /// applies its own rules to these, NotifyPlanner).
    static func candidates(_ s: State, now: Date, calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> [Planned] {
        var c: [Planned] = []

        // Paused mid-episode, two days on, 19:00.
        if let e = s.continueWatching.first(where: { $0.showKey != nil && !$0.finished && $0.position >= 60 }),
           let fire = at(19, 0, daysAfter: 2, e.updated, calendar) {
            c.append(Planned(id: "paused.\(key(e.id)).\(Int(e.updated.timeIntervalSince1970))", moment: .paused, fire: fire,
                             body: Text.paused(e.name, at: e.position),
                             link: continueLink(e.id), showKey: e.showKey, facts: ["show": e.name, "time": clock(e.position)]))
        }

        // An episode watched to its end, the next one in the library, the next day at 19:00.
        if let e = s.lastFinished, (e.episodesLeft ?? 0) > 0,
           s.continueWatching.allSatisfy({ $0.updated <= e.updated }),
           let fire = at(19, 0, daysAfter: 1, e.updated, calendar) {
            c.append(Planned(id: "cliff.\(key(e.id)).\(Int(e.updated.timeIntervalSince1970))", moment: .cliffhanger, fire: fire,
                             body: Text.cliffhanger(e.name),
                             link: continueLink(e.id, next: true), showKey: e.showKey, facts: ["show": e.name]))
        }

        // A film more than half watched, the next day at 20:00.
        if let e = s.continueWatching.first(where: { $0.showKey == nil && !$0.finished && $0.duration > 0 && $0.position / $0.duration >= 0.5 }) {
            let minutes = Int(((e.duration - e.position) / 60).rounded())
            if minutes >= 5, let fire = at(20, 0, daysAfter: 1, e.updated, calendar) {
                c.append(Planned(id: "film.\(key(e.id)).\(Int(e.updated.timeIntervalSince1970))", moment: .filmNearlyDone, fire: fire,
                                 body: Text.filmNearlyDone(e.name, minutes: minutes),
                                 link: continueLink(e.id), showKey: "film|" + e.id, facts: ["film": e.name, "minutes": "\(minutes)"]))
            }
        }

        // Two or three episodes left in the library, three days on at 19:00.
        if let e = s.continueWatching.first(where: { $0.showKey != nil && (2...3).contains($0.episodesLeft ?? 0) }),
           let left = e.episodesLeft, let fire = at(19, 0, daysAfter: 3, e.updated, calendar) {
            c.append(Planned(id: "left.\(key(e.id)).\(left).\(Int(e.updated.timeIntervalSince1970))", moment: .showNearlyDone, fire: fire,
                             body: Text.showNearlyDone(e.name, left: left),
                             link: continueLink(e.id), showKey: e.showKey, facts: ["show": e.name, "left": "\(left)"]))
        }

        // Friday at 18:00, for a show watched in the last three weeks with episodes left in the library.
        if let e = s.continueWatching.first(where: { $0.showKey != nil && ($0.episodesLeft ?? 0) >= 2 && now.timeIntervalSince($0.updated) < 21 * 86400 }),
           let left = e.episodesLeft, let friday = nextWeekday(6, hour: 18, after: now, calendar) {
            c.append(Planned(id: "friday.\(WatchLog.dayKey(friday, calendar: calendar)).\(key(e.id))", moment: .friday, fire: friday,
                             body: Text.friday(e.name, left: left),
                             link: continueLink(e.id), showKey: e.showKey, facts: ["show": e.name, "left": "\(left)"]))
        }

        // A late night: the same day at 12:30.
        if let late = s.lateNight, now.timeIntervalSince(late.until) < 12 * 3600, calendar.component(.hour, from: late.until) < 5,
           let fire = at(12, 30, daysAfter: 0, late.until, calendar) {
            c.append(Planned(id: "late.\(WatchLog.dayKey(late.until, calendar: calendar))", moment: .lateNight, fire: fire,
                             body: Text.lateNight(late.name, until: timeOfDay(late.until, calendar: calendar, locale: locale)),
                             link: nil, showKey: late.showKey,
                             facts: ["show": late.name, "time": timeOfDay(late.until, calendar: calendar, locale: locale)]))
        }

        // A binge (today's or yesterday's), the day after at 18:00.
        for d in s.days.suffix(2) where d.episodes.count >= bingeEpisodes {
            guard let day = date(of: d.day, calendar), let fire = at(18, 0, daysAfter: 1, day, calendar) else { continue }
            c.append(Planned(id: "binge.\(d.day)", moment: .binge, fire: fire,
                             body: Text.binge(d.episodes.count),
                             link: nil, showKey: nil, facts: ["n": "\(d.episodes.count)"]))
        }

        // Away a week, then (darker) twelve days, at 19:00. Only with something to come back to.
        if let last = s.lastWatched, let top = s.continueWatching.first {
            if let fire = at(19, 0, daysAfter: 7, last, calendar) {
                c.append(Planned(id: "away.\(Int(last.timeIntervalSince1970))", moment: .weekAway, fire: fire,
                                 body: Text.weekAway,
                                 link: nil, showKey: nil))
            }
            if let fire = at(19, 0, daysAfter: 12, last, calendar) {
                c.append(Planned(id: "plants.\(Int(last.timeIntervalSince1970))", moment: .houseplants, fire: fire,
                                 body: Text.houseplants(top.name),
                                 link: continueLink(top.id), showKey: top.showKey, facts: ["show": top.name]))
            }
        }

        return c
    }

    /// The rules: in the future and within the horizon, not quiet, not sent,
    /// one a day, the same show three days apart. A day's earlier slot loses
    /// to a higher priority only when both fall on that day.
    static func choose(_ candidates: [Planned], _ s: State, now: Date, calendar: Calendar) -> [Planned] {
        let horizon = now.addingTimeInterval(TimeInterval(horizonDays) * 86400)
        var usedDays = s.busyDays.union(s.sent.map { WatchLog.dayKey($0.at, calendar: calendar) })
        let sentIDs = Set(s.sent.map(\.id))
        var shows: [(key: String, at: Date)] = s.sent.compactMap { x in x.showKey.map { ($0, x.at) } }
        let ordered = candidates.sorted {
            let a = WatchLog.dayKey($0.fire, calendar: calendar), b = WatchLog.dayKey($1.fire, calendar: calendar)
            return a != b ? a < b : $0.moment.priority < $1.moment.priority
        }
        var out: [Planned] = []
        for p in ordered {
            guard p.fire > now.addingTimeInterval(60), p.fire <= horizon, !isQuiet(p.fire, calendar: calendar),
                  !sentIDs.contains(p.id), !out.contains(where: { $0.id == p.id }) else { continue }
            let day = WatchLog.dayKey(p.fire, calendar: calendar)
            guard !usedDays.contains(day) else { continue }
            if let k = p.showKey, shows.contains(where: { $0.key == k && abs($0.at.timeIntervalSince(p.fire)) < sameShowGap }) { continue }
            out.append(p)
            usedDays.insert(day)
            if let k = p.showKey { shows.append((k, p.fire)) }
        }
        return out.sorted { $0.fire < $1.fire }
    }

    // MARK: Pieces

    static func continueLink(_ id: String, next: Bool = false) -> String {
        ContinueLink.url(id: id).absoluteString + (next ? "&next=1" : "")
    }

    /// Quick timing (1.24.1, for trying them): the planned reminders, in
    /// their order, 20 seconds after `now` and then a minute apart.
    static func quickTimes(_ count: Int, from now: Date) -> [Date] {
        (0..<count).map { now.addingTimeInterval(20 + Double($0) * 60) }
    }

    /// `hour`:`minute` on the day `days` after `date`'s day.
    static func at(_ hour: Int, _ minute: Int, daysAfter days: Int, _ date: Date, _ calendar: Calendar) -> Date? {
        guard let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: date)) else { return nil }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }

    /// The next `weekday` (1 Sunday … 7 Saturday) at `hour`, today included while it's before then.
    static func nextWeekday(_ weekday: Int, hour: Int, after now: Date, _ calendar: Calendar) -> Date? {
        for d in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: d, to: calendar.startOfDay(for: now)),
                  calendar.component(.weekday, from: day) == weekday,
                  let t = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day), t > now else { continue }
            return t
        }
        return nil
    }

    static func date(of dayKey: String, _ calendar: Calendar) -> Date? {
        let p = dayKey.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    /// "31:04", "1:02:09".
    static func clock(_ seconds: Double) -> String {
        let t = max(0, Int(seconds))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    /// "3:12 AM" in the phone's own style.
    static func timeOfDay(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// A short stable name for an id (history ids are paths and links).
    static func key(_ id: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in id.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 36)
    }

    /// Of a show's library files in episode order, the episodes left from
    /// the `i`th: it (unless finished) and each later episode number once.
    static func episodesLeft(_ names: [String], at i: Int, finished: Bool) -> Int {
        guard names.indices.contains(i) else { return 0 }
        func number(_ n: String) -> String? {
            let p = TitleParser.parse(n)
            return p.episode.map { "\(p.season ?? 1).\($0)" }
        }
        let current = number(names[i])
        var later = Set<String>()
        for n in names[(i + 1)...] { if let k = number(n), k != current { later.insert(k) } }
        return later.count + (finished ? 0 : 1)
    }

    // MARK: Texts (the ones picked on 6 Nov)

    enum Text {
        static func paused(_ show: String, at position: Double) -> String {
            "\(show) is paused at \(clock(position)). Everyone's frozen mid-sentence. They'd like to finish it."
        }
        static func cliffhanger(_ show: String) -> String {
            "You left \(show) hanging off a cliff. The cliff is getting impatient."
        }
        static let weekAway = "7 days. Your Continue Watching row is gathering dust. And small spiders."
        static func houseplants(_ show: String) -> String {
            "\(show) is still waiting. Unlike your houseplants, it can't die of neglect. Probably."
        }
        static func lateNight(_ show: String, until time: String) -> String {
            "Up until \(time) with \(show). We're not judging. Your eyes are."
        }
        static func binge(_ episodes: Int) -> String {
            "\(episodes) episodes yesterday. That's not a binge, that's a lifestyle."
        }
        static func showNearlyDone(_ show: String, left: Int) -> String {
            "\(left) episodes left of \(show). Finish it, or we'll tell everyone you quit."
        }
        static func filmNearlyDone(_ film: String, minutes: Int) -> String {
            "\(film) has \(minutes) minutes left. The credits miss you."
        }
        static func friday(_ show: String, left: Int) -> String {
            "It's Friday. \(show) has \(left) episodes left. Coincidence? No."
        }
    }

    /// Every text once, with sample names (`-labEngage`).
    static func labSamples() -> [(title: String?, body: String)] {
        let late = Calendar.current.date(bySettingHour: 3, minute: 12, second: 0, of: Date()) ?? Date()
        let out = airingWording(show: "Harbor Lights", episode: AiringEpisode(season: 2, number: 4, title: nil, airDate: Date(), day: nil))
        let season = airingWording(show: "Harbor Lights", episode: AiringEpisode(season: 3, number: 1, title: nil, airDate: Date(), day: nil))
        let download = downloadWording(fileName: "Harbor.Lights.S02E06.1080p.WEB.mkv")!
        return [
            (nil, Text.paused("Harbor Lights", at: 31 * 60 + 4)),
            (nil, Text.cliffhanger("Harbor Lights")),
            (out.title, out.body),
            (nil, Text.weekAway),
            (nil, Text.houseplants("Harbor Lights")),
            (nil, Text.lateNight("Harbor Lights", until: timeOfDay(late, calendar: .current, locale: .current))),
            (nil, Text.binge(4)),
            (download.title, download.body),
            (nil, Text.showNearlyDone("Harbor Lights", left: 3)),
            (nil, Text.filmNearlyDone("The Quiet Orchard", minutes: 38)),
            (nil, Text.friday("Harbor Lights", left: 4)),
            (season.title, season.body),
        ]
    }

    // MARK: The other moments' wording

    /// The tracker's "is out" notification in Folio's voice (when these are
    /// on and it comes in the day): a new season's first episode, or any other.
    static func airingWording(show: String, episode: AiringEpisode) -> (title: String, body: String) {
        if episode.number == 1, let season = episode.season, season >= 2 {
            return ("\(show) S\(season) is out", "Good news: something to watch. Bad news: there goes sleep.")
        }
        let what = episode.number == nil && episode.season == nil ? "A new episode of \(show)" : "\(show) \(episode.label)"
        return ("\(what) is out", "Your evening plans just changed.")
    }

    /// Downloads' "finished" for one episode: "Harbor Lights S2 · E6 is downloaded".
    /// Nil for anything else (a film, several files), which keep the plain wording.
    static func downloadWording(fileName: String) -> (title: String, body: String)? {
        let p = TitleParser.parse(fileName)
        guard let ep = p.episode, !p.title.isEmpty else { return nil }
        let label = p.season.map { "S\($0) · E\(ep)" } ?? "E\(ep)"
        return ("\(p.title) \(label) is downloaded", "The internet can't stop you now.")
    }
}
