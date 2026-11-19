import XCTest
@testable import Folio

/// (0.90.0) "Notifications a Day" set to 5 gave about 2, with whole days of
/// none: the week's eight or nine all went out on the first evening and
/// night. The planner now deals them out a day at a time, spreads a day's
/// over the waking hours, lets a group's week grow with the daily number,
/// and keeps or moves a planned one that used to be lost without a word.
@MainActor
final class Fixes0900NotifyTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        return c
    }()

    private func date(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
    }

    /// Mon 16 Nov 2026, 14:21: the planning run in the user's log.
    private var monday: Date { date(16, 14, 21) }

    private func day(_ t: Date) -> Int { cal.component(.day, from: t) }
    private func minute(_ t: Date) -> Int { cal.component(.hour, from: t) * 60 + cal.component(.minute, from: t) }

    /// The user's settings: quiet hours off, the usual time 17:30, the
    /// library group off, and the weekly limits NotifyCenter gives for `max`.
    private func rules(max: Int, now: Date? = nil, sent: [NotifySent] = []) -> NotifyPlanner.Rules {
        var r = NotifyPlanner.Rules(now: now ?? monday, calendar: cal)
        r.quiet = QuietHours(start: 0, end: 0)
        r.maxPerDay = max
        r.preferredMinute = 17 * 60 + 30
        r.sent = sent
        r.allowed = { $0.group != .library && !$0.group.essential }
        r.weeklyMax = { $0.weeklyMax(perDay: max) }
        return r
    }

    private func flex(_ k: NotifyKind, _ key: String? = nil, days: Double, from: Date? = nil, show: String? = nil) -> NotifyCandidate {
        let start = from ?? monday
        return NotifyCandidate(kind: k, key: key ?? k.rawValue, window: start...start.addingTimeInterval(days * 86400), showKey: show, reason: "test")
    }

    private func fixed(_ k: NotifyKind, _ at: Date, _ key: String? = nil) -> NotifyCandidate {
        NotifyCandidate(kind: k, key: key ?? "\(k.rawValue).\(day(at))", fire: at, reason: "test")
    }

    /// The candidates of the log's run: three from the charts (four days),
    /// two picks (five days), Friday's briefing, the thriller before bed on
    /// Friday and Saturday, and Saturday's forecast.
    private var week: [NotifyCandidate] {
        [flex(.risingFast, days: 4), flex(.viral, days: 4), flex(.topRated, days: 4),
         flex(.forYouPick, days: 5), flex(.hiddenGem, days: 5),
         fixed(.weeklyBriefing, date(20, 17, 30)),
         fixed(.lateNightThriller, date(20, 22, 30)), fixed(.lateNightThriller, date(21, 22, 30)),
         fixed(.weekendForecast, date(21, 10, 30))]
    }

    private func table(_ name: String, _ out: [NotifyChosen]) -> String {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        var lines = ["WEEK \(name)"]
        for d in 16...22 {
            f.dateFormat = "EEE d"
            let label = f.string(from: date(d, 12))
            f.dateFormat = "HH:mm"
            let those = out.filter { day($0.fire) == d }.map { "\($0.candidate.kind.rawValue) \(f.string(from: $0.fire))" }
            lines.append("WEEK   \(label): " + (those.isEmpty ? "-" : those.joined(separator: ", ")))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: The user's week

    func testTheWeekFromTheLogIsSpreadOverItsDays() {
        // What 1.30.6 did with it (the planner as it was, below): five on
        // Monday evening and night, one of them at 01:30, and nothing from
        // Tuesday to Thursday. This is the log's line.
        let before = Self.firstFit(week, rules(max: 5), weeklyMax: { $0.weeklyMax })
        print(table("before (1.30.6)", before))
        XCTAssertEqual(before.prefix(5).map(\.candidate.kind), [.risingFast, .viral, .topRated, .forYouPick, .hiddenGem])
        XCTAssertEqual(before.prefix(5).map { minute($0.fire) }, [17 * 60 + 30, 19 * 60 + 30, 21 * 60 + 30, 23 * 60 + 30, 60 + 30])
        XCTAssertEqual(before.count, 8)
        for d in 18...19 { XCTAssertTrue(before.filter { day($0.fire) == d }.isEmpty) }

        let plan = NotifyPlanner.plan(week, rules(max: 5))
        let out = plan.chosen
        print(table("after (0.90.0)", out))
        print("WEEK " + NotifyPlanner.summary(plan, candidates: week.count, calendar: cal))
        // Everything there was to say is planned, and no day of the next
        // five (Monday to Friday) is empty.
        XCTAssertEqual(out.count, week.count)
        for d in 16...20 { XCTAssertFalse(out.filter { day($0.fire) == d }.isEmpty, "nothing on the \(d)th") }
        // Monday no longer takes the week: one at the usual time, and the
        // one that was left over once every day had its first.
        let mondays = out.filter { day($0.fire) == 16 }
        XCTAssertEqual(mondays.map { minute($0.fire) }, [17 * 60 + 30, 20 * 60])
        XCTAssertLessThan(mondays.count, 5)
        for d in 17...19 {
            let those = out.filter { day($0.fire) == d }
            XCTAssertEqual(those.map { minute($0.fire) }, [17 * 60 + 30], "the \(d)th has its one at the usual time")
        }
        check(out, max: 5)
        // Friday's and Saturday's own moments are where they were.
        XCTAssertEqual(out.first { $0.candidate.kind == .weeklyBriefing }?.fire, date(20, 17, 30))
        XCTAssertEqual(out.first { $0.candidate.kind == .weekendForecast }?.fire, date(21, 10, 30))
    }

    /// The rules every plan keeps: at most `max` a day, nothing after 22:30
    /// or before 08:00, two hours between any two of a day.
    private func check(_ out: [NotifyChosen], max: Int, file: StaticString = #filePath, line: UInt = #line) {
        for (d, those) in Dictionary(grouping: out, by: { day($0.fire) }) {
            XCTAssertLessThanOrEqual(those.count, max, "\(those.count) on the \(d)th", file: file, line: line)
            let t = those.map(\.fire).sorted()
            for (a, b) in zip(t, t.dropFirst()) {
                XCTAssertGreaterThanOrEqual(b.timeIntervalSince(a), 2 * 3600, "under two hours apart on the \(d)th", file: file, line: line)
            }
        }
        for c in out {
            let m = minute(c.fire)
            XCTAssertFalse(m > 22 * 60 + 30 || m < 8 * 60, "\(c.candidate.kind.rawValue) at night (\(m / 60):\(m % 60))", file: file, line: line)
        }
    }

    /// A fuller week (every chart kind, three picks, the briefing's two, a
    /// rainy Wednesday, yesterday's joke): up to five a day, never more,
    /// and still dealt out evenly.
    func testAFullWeekFillsDaysEvenlyUpToFive() {
        let charts: [NotifyKind] = [.trendingMovie, .trendingSeries, .risingFast, .viral, .topRated, .highlyRatedSeries,
                                    .lowRatedPopular, .comeback, .ratingMilestone, .popularGenre]
        var c = charts.map { flex($0, days: 4) } + week.filter { $0.fire != nil }
        c += [flex(.forYouPick, days: 5), flex(.hiddenGem, days: 5), flex(.genreStreak, days: 3), flex(.freshTitles, days: 3),
              flex(.unfinishedPile, days: 4), flex(.forgotten, days: 7)]
        c.append(NotifyCandidate(kind: .rainy, key: "rain", window: date(18, 0)...date(18, 23, 59), reason: "test"))
        c.append(NotifyCandidate(kind: .openedNoWatch, key: "opened", window: date(17, 0)...date(17, 23, 59), reason: "test"))
        let plan = NotifyPlanner.plan(c, rules(max: 5))
        let out = plan.chosen
        print(table("full, up to 5", out))
        print("WEEK " + NotifyPlanner.summary(plan, candidates: c.count, calendar: cal))
        check(out, max: 5)
        // Trending's week is 8 at five a day (3 at one or two): two of its
        // ten wait. Just for fun's is 5: the three with their own moment,
        // the rain and yesterday's joke; the pile of unfinished ones waits.
        XCTAssertEqual(out.filter { $0.candidate.kind.group == .trending }.count, 8)
        XCTAssertEqual(out.filter { $0.candidate.kind.group == .fun }.count, 5)
        XCTAssertEqual(plan.held[.weekly], 3)
        // The library group is off.
        XCTAssertFalse(out.contains { $0.candidate.kind == .forgotten })
        XCTAssertEqual(plan.held[.off], 1)
        // The day-bound ones got their day.
        XCTAssertEqual(out.first { $0.candidate.kind == .rainy }.map { day($0.fire) }, 18)
        XCTAssertEqual(out.first { $0.candidate.kind == .openedNoWatch }.map { day($0.fire) }, 17)
        // Dealt out evenly: among the days the flexible ones can reach
        // (Monday to Thursday), no day has two more than another.
        let counts = (16...19).map { d in out.filter { day($0.fire) == d }.count }
        XCTAssertLessThanOrEqual(counts.max()! - counts.min()!, 1, "\(counts)")
        XCTAssertGreaterThanOrEqual(counts.min()!, 3, "\(counts)")
    }

    // MARK: One and two a day, about as before

    func testOneADayIsAsBefore() {
        let r = rules(max: 1)
        let out = NotifyPlanner.choose(week, r)
        print(table("up to 1", out))
        check(out, max: 1)
        // One a day at the usual time, Monday to Thursday, as 1.30.6 planned it.
        let before = Self.firstFit(week, r, weeklyMax: { $0.weeklyMax })
        XCTAssertEqual(out.filter { day($0.fire) <= 19 }.map(\.fire), (16...19).map { date($0, 17, 30) })
        XCTAssertEqual(out.filter { day($0.fire) <= 19 }.map(\.fire), before.filter { day($0.fire) <= 19 }.map(\.fire))
        // The limits of one a day are the old ones.
        for g in NotifyGroup.allCases { XCTAssertEqual(g.weeklyMax(perDay: 1), g.weeklyMax) }
        // Friday keeps the briefing; Saturday one of its two.
        XCTAssertEqual(out.filter { day($0.fire) == 20 }.map(\.candidate.kind), [.weeklyBriefing])
        XCTAssertEqual(out.filter { day($0.fire) == 21 }.count, 1)
    }

    func testTwoADayIsAboutAsBefore() {
        let r = rules(max: 2)
        let out = NotifyPlanner.choose(week, r)
        print(table("up to 2", out))
        check(out, max: 2)
        for g in NotifyGroup.allCases { XCTAssertEqual(g.weeklyMax(perDay: 2), g.weeklyMax) }
        // 1.30.6 put two on Monday (17:30, 19:30), two on Tuesday and one on
        // Wednesday. Now Monday to Thursday have one each at 17:30 first,
        // and only the fifth is a day's second, three hours after its first.
        let early = out.filter { day($0.fire) <= 19 }
        XCTAssertEqual(early.count, 5)
        for d in 16...19 { XCTAssertEqual(early.first { day($0.fire) == d }.map { minute($0.fire) }, 17 * 60 + 30) }
        XCTAssertEqual(early.filter { day($0.fire) == 16 }.map { minute($0.fire) }, [17 * 60 + 30, 20 * 60 + 30])
        // Just for fun's week is still two.
        XCTAssertEqual(out.filter { $0.candidate.kind.group == .fun }.count, 2)
    }

    // MARK: A day's times

    func testADaysTimes() {
        // Quiet hours off, 17:30: 09:00–22:00, 2½ h apart at five a day.
        XCTAssertEqual(NotifyPlanner.slotMinutes(rules(max: 5)), [1050, 1200, 900, 750, 600])
        // Up to four a day: three hours apart, the evening first.
        XCTAssertEqual(NotifyPlanner.slotMinutes(rules(max: 2)), [1050, 1230, 870, 690])
        XCTAssertEqual(NotifyPlanner.slotMinutes(rules(max: 1)), [1050, 1230, 870, 690])
        // Quiet hours 22:00–09:00: 10:00–21:00, two hours apart at five.
        var r = rules(max: 5)
        r.quiet = .standard
        r.preferredMinute = 19 * 60
        XCTAssertEqual(NotifyPlanner.wakingWindow(.standard), 600...1260)
        XCTAssertEqual(NotifyPlanner.slotMinutes(r), [1140, 1260, 1020, 900, 780, 660])
        for max in 1...5 {
            r.maxPerDay = max
            let s = NotifyPlanner.slotMinutes(r).sorted()
            XCTAssertGreaterThanOrEqual(s.count, min(max, 4))
            for (a, b) in zip(s, s.dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, 120) }
            for m in s { XCTAssertFalse(QuietHours.standard.contains(cal.date(byAdding: .minute, value: m, to: date(17, 0))!, calendar: cal)) }
        }
        // Quiet hours that aren't overnight, or leave no day: the plain day.
        XCTAssertEqual(NotifyPlanner.wakingWindow(QuietHours(start: 0, end: 8 * 60)), 540...1320)
        XCTAssertEqual(NotifyPlanner.wakingWindow(QuietHours(start: 12 * 60, end: 11 * 60)), NotifyPlanner.plainDay)
    }

    func testFiveOnOneDayAreSpreadOverIt() {
        // Five that can only come on Wednesday.
        let c = (0..<6).map { NotifyCandidate(kind: .freshTitles, key: "f\($0)", window: date(18, 0)...date(18, 23, 59), reason: "test") }
        let plan = NotifyPlanner.plan(c, rules(max: 5))
        XCTAssertEqual(plan.chosen.map { minute($0.fire) }, [600, 750, 900, 1050, 1200])
        XCTAssertEqual(plan.held[.dayFull], 1)
        check(plan.chosen, max: 5)
    }

    func testTodayUsesTheNextTimeAQuarterHourOff() {
        // 18:00: the usual time has passed; 1.30.6 waited for tomorrow.
        var out = NotifyPlanner.choose([flex(.viral, days: 4, from: date(16, 18))], rules(max: 5, now: date(16, 18)))
        XCTAssertEqual(out.map(\.fire), [date(16, 20)])
        // 17:20: 17:30 is under a quarter of an hour off.
        out = NotifyPlanner.choose([flex(.viral, days: 4, from: date(16, 17, 20))], rules(max: 5, now: date(16, 17, 20)))
        XCTAssertEqual(out.map(\.fire), [date(16, 20)])
        // 17:10: the usual time.
        out = NotifyPlanner.choose([flex(.viral, days: 4, from: date(16, 17, 10))], rules(max: 5, now: date(16, 17, 10)))
        XCTAssertEqual(out.map(\.fire), [date(16, 17, 30)])
        // 21:00: nothing left today; tomorrow at the usual time, not 23:00 or 01:00.
        out = NotifyPlanner.choose([flex(.viral, days: 4, from: date(16, 21))], rules(max: 5, now: date(16, 21)))
        XCTAssertEqual(out.map(\.fire), [date(17, 17, 30)])
        // One a day: a later time today too (20:30).
        out = NotifyPlanner.choose([flex(.viral, days: 4, from: date(16, 18))], rules(max: 1, now: date(16, 18)))
        XCTAssertEqual(out.map(\.fire), [date(16, 20, 30)])
    }

    func testPlanningAgainInTheEveningDoesntTopTodayUp() {
        // Monday 18:05, after the 17:30 one went out: the rest go to the
        // days that have none, not to tonight.
        let sent = [NotifySent(key: "risingFast", kind: .risingFast, at: date(16, 17, 30), showKey: nil)]
        let out = NotifyPlanner.choose(week, rules(max: 5, now: date(16, 18, 5), sent: sent))
        XCTAssertFalse(out.contains { $0.candidate.kind == .risingFast })
        for d in 17...19 { XCTAssertEqual(out.filter { day($0.fire) == d }.count, 1) }
        // The fourth flexible one is tonight's second (20:00): every other day has one.
        XCTAssertEqual(out.filter { day($0.fire) == 16 }.map(\.fire), [date(16, 20)])
        check(out, max: 5)
    }

    func testNoNightWithQuietHoursOff() {
        let c = [fixed(.paused, date(17, 1, 30)), fixed(.cliffhanger, date(17, 23)), fixed(.lateNightThriller, date(20, 22, 30)),
                 fixed(.binge, date(18, 8))]
        let plan = NotifyPlanner.plan(c, rules(max: 5))
        XCTAssertEqual(plan.chosen.map(\.candidate.kind), [.binge, .lateNightThriller])
        XCTAssertEqual(plan.held[.quiet], 2)
        // With quiet hours on, they're the night.
        var r = rules(max: 5)
        r.quiet = QuietHours(start: 23 * 60 + 30, end: 7 * 60)
        XCTAssertEqual(NotifyPlanner.choose(c, r).map(\.candidate.kind), [.cliffhanger, .binge, .lateNightThriller])
    }

    // MARK: A group's week

    func testAGroupsWeekGrowsWithTheDailyNumber() {
        XCTAssertEqual((1...5).map { NotifyGroup.trending.weeklyMax(perDay: $0) }, [3, 3, 5, 6, 8])
        for g: NotifyGroup in [.recommendations, .library, .fun] {
            XCTAssertEqual((1...5).map { g.weeklyMax(perDay: $0) }, [2, 2, 3, 4, 5])
        }
        for g: NotifyGroup in [.watching, .newReleases, .briefing, .downloads] { XCTAssertNil(g.weeklyMax(perDay: 5)) }
        // Sun 15 – Sat 21 Nov is one week here: six from the charts, in four days.
        let c = (0..<6).map { flex(.risingFast, "r\($0)", days: 4) }
        XCTAssertEqual(NotifyPlanner.choose(c, rules(max: 5)).count, 6)
        XCTAssertEqual(NotifyPlanner.choose(c, rules(max: 3)).count, 5)
        XCTAssertEqual(NotifyPlanner.choose(c, rules(max: 2)).count, 3)
        XCTAssertEqual(NotifyPlanner.choose(c, rules(max: 1)).count, 3)
    }

    func testFridaysAndSaturdaysJokesLeaveRoomEarlierInTheWeek() {
        // Up to two a day, Just for fun's week is two. 1.30.6 gave both to
        // Friday and Saturday before Wednesday's rain was looked at.
        let rain = NotifyCandidate(kind: .rainy, key: "rain", window: date(18, 0)...date(18, 23, 59), reason: "test")
        let c = [fixed(.movieNight, date(20, 18, 30)), fixed(.weekendForecast, date(21, 10, 30)), rain]
        let r = rules(max: 2)
        XCTAssertEqual(Self.firstFit(c, r, weeklyMax: { $0.weeklyMax }).map(\.candidate.kind), [.movieNight, .weekendForecast])
        let plan = NotifyPlanner.plan(c, r)
        XCTAssertEqual(plan.chosen.map(\.candidate.kind), [.rainy, .movieNight])
        XCTAssertEqual(plan.held[.weekly], 1)
        // With no rain, both jokes come as before.
        XCTAssertEqual(NotifyPlanner.choose(Array(c.prefix(2)), r).map(\.candidate.kind), [.movieNight, .weekendForecast])
    }

    // MARK: What prevents spam is kept

    func testTheSpamRulesHold() {
        // One send per key; a kind that's off or resting; the same show three days apart.
        let sent = [NotifySent(key: "viral", kind: .viral, at: date(15, 19), showKey: nil)]
        var r = rules(max: 5, sent: sent)
        r.allowed = { $0 != .topRated }
        let plan = NotifyPlanner.plan([flex(.viral, days: 4), flex(.topRated, days: 4),
                                       flex(.forYouPick, days: 5, show: "s"), flex(.hiddenGem, days: 5, show: "s"), flex(.genreStreak, days: 1, show: "s")], r)
        XCTAssertEqual(plan.chosen.map(\.candidate.kind), [.genreStreak, .forYouPick])
        XCTAssertEqual(plan.chosen.map(\.fire), [date(16, 17, 30), date(19, 17, 30)])
        XCTAssertEqual(plan.held, [.sent: 1, .off: 1, .sameShow: 1])
        // Quiet hours: a moment of its own inside them is dropped, and the day's times stay outside.
        var q = rules(max: 5)
        q.quiet = .standard
        let out = NotifyPlanner.choose([fixed(.lateNightThriller, date(20, 22, 30))] + (0..<5).map { flex(.viral, "v\($0)", days: 0.4) }, q)
        XCTAssertFalse(out.contains { $0.candidate.kind == .lateNightThriller })
        XCTAssertFalse(out.isEmpty)
        for c in out { XCTAssertFalse(QuietHours.standard.contains(c.fire, calendar: cal)) }
    }

    // MARK: A planned one that would have been lost

    private func earlier(_ k: NotifyKind, _ key: String, at: Date, held: Bool = false, saved: Bool = true) -> NotifyPlanner.Earlier {
        .init(key: key, kind: k, at: at, facts: ["list": "A, B, C", "n": "3"], link: "folio://title?id=tt1", reason: "New on the charts this week",
              saved: saved, held: held)
    }

    func testAPlannedOneWhoseFactsWentIsKeptForADay() {
        // The log: freshTitles planned at 04:02 for Tue 17:30, gone at 10:02.
        let now = date(17, 10, 2)
        let fresh = [flex(.viral, days: 4, from: now)]
        let was = earlier(.freshTitles, "fresh.2026w47", at: date(17, 17, 30))
        var got = NotifyPlanner.recover(fresh, earlier: [was], now: now)
        XCTAssertEqual(got.candidates.count, 2)
        let kept = got.candidates.first { $0.kind == .freshTitles }
        XCTAssertEqual(kept?.fire, date(17, 17, 30))
        XCTAssertEqual(kept?.facts["list"], "A, B, C")
        XCTAssertEqual(kept?.link, "folio://title?id=tt1")
        XCTAssertEqual(got.notes.count, 1)
        XCTAssertTrue(got.notes[0].hasPrefix("freshTitles kept at its time"), got.notes[0])
        // It keeps its time in the plan, and the day's other one goes around it.
        let out = NotifyPlanner.choose(got.candidates, rules(max: 5, now: now))
        XCTAssertEqual(out.filter { day($0.fire) == 17 }.map(\.candidate.kind), [.freshTitles])
        XCTAssertEqual(out.first?.fire, date(17, 17, 30))

        // Still there in the new data: nothing to do.
        got = NotifyPlanner.recover([flex(.freshTitles, "fresh.2026w47", days: 3, from: now)], earlier: [was], now: now)
        XCTAssertEqual(got.candidates.count, 1)
        XCTAssertTrue(got.notes.isEmpty)
        // Already sent.
        got = NotifyPlanner.recover(fresh, earlier: [was], now: now, sentKeys: ["fresh.2026w47"])
        XCTAssertEqual(got.candidates.count, 1)
        // Over a day off: let go, and the log says why.
        got = NotifyPlanner.recover(fresh, earlier: [earlier(.freshTitles, "fresh.2026w47", at: date(18, 17, 30))], now: now)
        XCTAssertEqual(got.candidates.count, 1)
        XCTAssertEqual(got.notes, ["freshTitles let go: its facts are gone, and it was over a day off"])
        // "The most popular film" isn't true of it any more; the weather changed.
        got = NotifyPlanner.recover(fresh, earlier: [earlier(.trendingMovie, "trendMovie.tt1", at: date(17, 17, 30)),
                                                     earlier(.rainy, "rain.2026-11-17", at: date(17, 17, 30))], now: now)
        XCTAssertEqual(got.candidates.count, 1)
        XCTAssertEqual(got.notes, ["trendingMovie let go: its facts are gone", "rainy let go: its facts are gone"])
        // A newer one of its kind; a title you've watched since; a plan saved without its text.
        got = NotifyPlanner.recover(fresh, earlier: [earlier(.viral, "viral.tt9", at: date(17, 17, 30))], now: now)
        XCTAssertEqual(got.notes, ["viral let go: a newer one of its kind took its place"])
        got = NotifyPlanner.recover([], earlier: [earlier(.risingFast, "rising.tt9.2026w47", at: date(17, 17, 30))], now: now, watched: ["tt9"])
        XCTAssertEqual(got.notes, ["risingFast let go: you've watched it since"])
        got = NotifyPlanner.recover([], earlier: [earlier(.risingFast, "rising.tt9.2026w47", at: date(17, 17, 30))], now: now, watched: ["tt90"])
        XCTAssertEqual(got.candidates.count, 1)
        got = NotifyPlanner.recover([], earlier: [earlier(.risingFast, "rising.tt9.2026w47", at: date(17, 17, 30), saved: false)], now: now)
        XCTAssertTrue(got.candidates.isEmpty)
    }

    func testAMomentThatCameWhileFolioWasOpenMovesOn() {
        // "An episode left paused" was due at 19:00; Folio was in front
        // from 18:50 to 19:10, so it had been taken back. Folio still has
        // it (the episode is still paused): it comes at the next time.
        let now = date(17, 19, 10)
        let paused = NotifyCandidate(kind: .paused, key: "paused.x", fire: date(17, 19), facts: ["show": "Harbor Lights"], showKey: "s", reason: "From what you watched")
        var got = NotifyPlanner.recover([paused], earlier: [earlier(.paused, "paused.x", at: date(17, 19), held: true)], now: now)
        XCTAssertNil(got.candidates[0].fire)
        XCTAssertEqual(got.candidates[0].window, now...date(18, 19))
        XCTAssertEqual(got.candidates[0].facts["show"], "Harbor Lights")
        XCTAssertEqual(NotifyPlanner.choose(got.candidates, rules(max: 5, now: now)).map(\.fire), [date(17, 20)])
        // 1.30.6 lost it: its moment had passed.
        XCTAssertTrue(NotifyPlanner.choose([paused], rules(max: 5, now: now)).isEmpty)
        // Not held (it went out, or was never planned): left as it is.
        got = NotifyPlanner.recover([paused], earlier: [earlier(.paused, "paused.x", at: date(17, 19))], now: now)
        XCTAssertEqual(got.candidates[0].fire, date(17, 19))
        // You carried on watching, so Folio no longer has it: let go.
        got = NotifyPlanner.recover([], earlier: [earlier(.paused, "paused.x", at: date(17, 19), held: true)], now: now)
        XCTAssertTrue(got.candidates.isEmpty)
        XCTAssertEqual(got.notes, ["paused let go: its moment came while Folio was open, and it's no longer true"])
        // The thriller before bed and "a week away" are no use later.
        let thriller = fixed(.lateNightThriller, date(20, 22, 30), "thriller")
        got = NotifyPlanner.recover([], earlier: [earlier(.lateNightThriller, "thriller", at: date(20, 22, 30), held: true)], now: date(20, 22, 40))
        XCTAssertTrue(got.candidates.isEmpty)
        XCTAssertEqual(got.notes, ["lateNightThriller let go: its moment came while Folio was open, and it's no use later"])
        XCTAssertNil(NotifyKind.weekAway.holdsFor)
        XCTAssertNil(NotifyKind.houseplants.holdsFor)
        // Held, but its moment is still ahead: planned as usual.
        got = NotifyPlanner.recover([thriller], earlier: [earlier(.lateNightThriller, "thriller", at: date(20, 22, 30), held: true)], now: date(20, 21))
        XCTAssertEqual(got.candidates, [thriller])
        XCTAssertTrue(got.notes.isEmpty)
        // The month's recap (the 1st, 18:00): Folio makes next month's by
        // then, so this one comes with the text it had, within a day.
        let first = cal.date(from: DateComponents(year: 2026, month: 12, day: 1, hour: 18))!
        got = NotifyPlanner.recover([], earlier: [earlier(.monthlyRecap, "recap.2026-11", at: first, held: true)], now: first.addingTimeInterval(1200))
        XCTAssertEqual(got.candidates.map(\.key), ["recap.2026-11"])
        XCTAssertEqual(got.candidates[0].window, first.addingTimeInterval(1200)...first.addingTimeInterval(86400))
        XCTAssertEqual(NotifyPlanner.choose(got.candidates, rules(max: 5, now: first.addingTimeInterval(1200))).map(\.fire),
                       [cal.date(from: DateComponents(year: 2026, month: 12, day: 1, hour: 20))!])
        // Two days on it's let go.
        got = NotifyPlanner.recover([], earlier: [earlier(.monthlyRecap, "recap.2026-11", at: first, held: true)], now: first.addingTimeInterval(2 * 86400))
        XCTAssertTrue(got.candidates.isEmpty)
        // Friday's "it's Friday" isn't moved on (review): past 18:00 Folio's
        // candidate is next week's, under another key, so nothing of today's
        // is left, and its saved text isn't sent later.
        got = NotifyPlanner.recover([], earlier: [earlier(.friday, "friday.x", at: date(20, 18), held: true)], now: date(20, 19, 30))
        XCTAssertTrue(got.candidates.isEmpty)
        // A pick held while Folio was open and watched there isn't sent
        // after; nor beside a newer pick.
        let pick = earlier(.forYouPick, "foryou.tt1234567", at: date(17, 17, 30), held: true)
        got = NotifyPlanner.recover([], earlier: [pick], now: date(17, 19, 30), watched: ["tt1234567"])
        XCTAssertTrue(got.candidates.isEmpty)
        let newer = NotifyCandidate(kind: .forYouPick, key: "foryou.tt7654321", fire: nil, reason: "t")
        got = NotifyPlanner.recover([newer], earlier: [pick], now: date(17, 19, 30))
        XCTAssertEqual(got.candidates.map(\.key), ["foryou.tt7654321"])
        got = NotifyPlanner.recover([], earlier: [pick], now: date(17, 19, 30))
        XCTAssertEqual(got.candidates.map(\.key), ["foryou.tt1234567"], "still good: moved on")
    }

    /// The saved plan gained what each one says; a plan saved by 1.30.6 still reads.
    func testTheSavedPlanReadsWithAndWithoutItsText() throws {
        let old = #"[{"request":"folio.notify.fresh.w47","key":"fresh.w47","kind":"freshTitles","at":800000000,"test":false}]"#
        let a = try JSONDecoder().decode([NotifyCenter.Scheduled].self, from: Data(old.utf8))
        XCTAssertFalse(a[0].earlier.saved)
        XCTAssertFalse(a[0].earlier.held)
        var s = a[0]
        s.facts = ["n": "3"]
        s.reason = "New on the charts this week"
        s.image = .url("https://m.media-amazon.com/x.jpg")
        s.held = true
        let b = try JSONDecoder().decode(NotifyCenter.Scheduled.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(b.earlier, NotifyPlanner.Earlier(key: "fresh.w47", kind: .freshTitles, at: a[0].at, facts: ["n": "3"],
                                                        image: .url("https://m.media-amazon.com/x.jpg"), reason: "New on the charts this week", saved: true, held: true))
    }

    // MARK: Settings' line and the log's

    func testThePlannedLine() {
        XCTAssertEqual(NotifyPlanner.plannedLine(sentToday: 0, today: 2, tomorrow: 1), "Today: 2 planned. Tomorrow: 1 planned.")
        XCTAssertEqual(NotifyPlanner.plannedLine(sentToday: 1, today: 1, tomorrow: 0), "Today: 1 sent, 1 planned. Tomorrow: none planned.")
        XCTAssertEqual(NotifyPlanner.plannedLine(sentToday: 0, today: 0, tomorrow: 3), "Today: none planned. Tomorrow: 3 planned.")
        XCTAssertEqual(NotifyPlanner.plannedLine(sentToday: 0, today: 0, tomorrow: 0), "Nothing planned for today or tomorrow.")
    }

    func testTheLogsLineSaysWhatHeldTheRestBack() {
        let c = week + [flex(.forgotten, days: 7), flex(.genreStreak, days: 5), flex(.viral, days: 4)]
        let plan = NotifyPlanner.plan(c, rules(max: 5, sent: [NotifySent(key: "genreStreak", kind: .genreStreak, at: date(15, 19), showKey: nil)]))
        XCTAssertEqual(NotifyPlanner.summary(plan, candidates: c.count, calendar: cal),
                       "9 of 12 candidates planned (Mon 16: 2, Tue 17: 1, Wed 18: 1, Thu 19: 1, Fri 20: 2, Sat 21: 2); held back: 1 switched off or resting, 1 already sent")
        XCTAssertEqual(NotifyPlanner.summary(.init(), candidates: 0, calendar: cal), "0 of 0 candidates planned")
    }

    // MARK: The planner as it was in 1.30.6, to compare with

    /// NotifyPlanner.choose from 1.30.6, unchanged: each flexible one takes
    /// the first free day at the usual time, the next that day two hours
    /// after the last.
    static func firstFit(_ candidates: [NotifyCandidate], _ r: NotifyPlanner.Rules, weeklyMax: (NotifyGroup) -> Int?) -> [NotifyChosen] {
        let cal = r.calendar
        let horizon = r.now.addingTimeInterval(TimeInterval(NotifyPlanner.horizonDays) * 86400)
        let sentKeys = Set(r.sent.map(\.key))
        var times: [String: [Date]] = [:]
        var weekly: [String: Int] = [:]
        var shows: [(key: String, at: Date)] = r.sent.compactMap { s in s.showKey.map { ($0, s.at) } }
        for s in r.sent where !s.kind.group.essential {
            times[WatchLog.dayKey(s.at, calendar: cal), default: []].append(s.at)
            weekly[NotifyPlanner.weekKey(s.kind.group, s.at, cal), default: 0] += 1
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
            let taken = times[WatchLog.dayKey(t, calendar: cal)] ?? []
            guard taken.count < r.maxPerDay, taken.allSatisfy({ abs($0.timeIntervalSince(t)) >= NotifyPlanner.sameDayGap }) else { return false }
            if let max = weeklyMax(c.kind.group), weekly[NotifyPlanner.weekKey(c.kind.group, t, cal), default: 0] >= max { return false }
            if let k = c.showKey, shows.contains(where: { $0.key == k && abs($0.at.timeIntervalSince(t)) < NotifyPlanner.sameShowGap }) { return false }
            return true
        }
        func take(_ c: NotifyCandidate, at t: Date) {
            out.append(NotifyChosen(candidate: c, fire: t))
            times[WatchLog.dayKey(t, calendar: cal), default: []].append(t)
            weekly[NotifyPlanner.weekKey(c.kind.group, t, cal), default: 0] += 1
            if let k = c.showKey { shows.append((k, t)) }
        }
        for c in fixed where fits(c, at: c.fire!) { take(c, at: c.fire!) }
        for c in flexible {
            guard let w = c.window else { continue }
            var day = cal.startOfDay(for: max(w.lowerBound, r.now))
            let last = min(w.upperBound, horizon)
            while day <= last {
                var t = cal.date(byAdding: .minute, value: r.preferredMinute, to: day) ?? day
                if let latest = times[WatchLog.dayKey(day, calendar: cal)]?.max(), latest >= t { t = latest.addingTimeInterval(NotifyPlanner.sameDayGap) }
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
}
