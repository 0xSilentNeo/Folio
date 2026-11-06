import XCTest
@testable import Folio

/// 1.24.0: the engagement notifications' plan (EngagePlanner): when each
/// moment comes, the texts picked on 6 Nov, and the rules (one a day, none
/// at night, a show three days apart, each once).
@MainActor
final class EngagementTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        return c
    }()
    private let us = Locale(identifier: "en_US")

    private func date(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
    }

    /// Mon 2 Nov 2026, 10:00 in Melbourne.
    private var monday: Date { date(2, 10) }

    private func episode(_ name: String = "Harbor Lights", position: Double = 1864, duration: Double = 2700,
                         updated: Date, finished: Bool = false, left: Int? = nil) -> EngagePlanner.Entry {
        EngagePlanner.Entry(id: "/var/mobile/x/Documents/Media/\(name)/E.mkv", name: name, showKey: "s|" + name.lowercased(),
                            position: position, duration: duration, updated: updated, finished: finished, episodesLeft: left)
    }

    private func film(_ name: String = "The Quiet Orchard", position: Double, duration: Double = 6280, updated: Date) -> EngagePlanner.Entry {
        EngagePlanner.Entry(id: "/var/mobile/x/Documents/Media/\(name).mkv", name: name, showKey: nil,
                            position: position, duration: duration, updated: updated, finished: false, episodesLeft: nil)
    }

    private func plan(_ s: EngagePlanner.State, now: Date? = nil) -> [EngagePlanner.Planned] {
        EngagePlanner.plan(s, now: now ?? monday, calendar: cal, locale: us)
    }

    // MARK: Moments

    func testPausedEpisodeTwoDaysOnAtSeven() {
        var s = EngagePlanner.State()
        s.continueWatching = [episode(updated: date(1, 21))]
        let p = plan(s)
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p.first?.moment, .paused)
        XCTAssertEqual(p.first?.fire, date(3, 19))
        XCTAssertEqual(p.first?.body, "Harbor Lights is paused at 31:04. Everyone's frozen mid-sentence. They'd like to finish it.")
        XCTAssertEqual(p.first?.link.flatMap { URL(string: $0) }.flatMap { ContinueLink.id(from: $0) }, s.continueWatching[0].id)
    }

    func testPausedNeedsAMinuteIn() {
        var s = EngagePlanner.State()
        s.continueWatching = [episode(position: 40, updated: date(1, 21))]
        XCTAssertTrue(plan(s).isEmpty)
    }

    func testCliffhangerTheNextDayPlaysTheNextEpisode() {
        var s = EngagePlanner.State()
        s.lastFinished = episode(position: 2690, updated: date(1, 22), finished: true, left: 2)
        let p = plan(s)
        XCTAssertEqual(p.map(\.moment), [.cliffhanger])
        XCTAssertEqual(p.first?.fire, date(2, 19))
        XCTAssertEqual(p.first?.body, "You left Harbor Lights hanging off a cliff. The cliff is getting impatient.")
        XCTAssertTrue(p.first?.link?.hasSuffix("&next=1") == true)
    }

    func testNoCliffhangerWithoutANextEpisodeInTheLibrary() {
        var s = EngagePlanner.State()
        s.lastFinished = episode(position: 2690, updated: date(1, 22), finished: true, left: 0)
        XCTAssertTrue(plan(s).isEmpty)
        s.lastFinished?.episodesLeft = nil                      // a server's or Discover's: unknown
        XCTAssertTrue(plan(s).isEmpty)
    }

    func testFilmMoreThanHalfWatched() {
        var s = EngagePlanner.State()
        s.continueWatching = [film(position: 4000, updated: date(1, 21))]
        let p = plan(s)
        XCTAssertEqual(p.map(\.moment), [.filmNearlyDone])
        XCTAssertEqual(p.first?.fire, date(2, 20))
        XCTAssertEqual(p.first?.body, "The Quiet Orchard has 38 minutes left. The credits miss you.")
    }

    func testFridayWithEpisodesLeft() {
        var s = EngagePlanner.State()
        s.continueWatching = [episode(position: 30, updated: date(2, 9), left: 5)]
        let p = plan(s)
        XCTAssertEqual(p.map(\.moment), [.friday])
        XCTAssertEqual(p.first?.fire, date(6, 18))
        XCTAssertEqual(p.first?.body, "It's Friday. Harbor Lights has 5 episodes left. Coincidence? No.")
    }

    func testLateNightTheSameDayAtHalfTwelve() {
        var s = EngagePlanner.State()
        s.lateNight = (date(2, 3, 12), "Harbor Lights", "s|harbor lights")
        let p = plan(s, now: date(2, 3, 20))
        XCTAssertEqual(p.map(\.moment), [.lateNight])
        XCTAssertEqual(p.first?.fire, date(2, 12, 30))
        XCTAssertEqual(p.first?.body.replacingOccurrences(of: "\u{202F}", with: " "),
                       "Up until 3:12 AM with Harbor Lights. We're not judging. Your eyes are.")
        // Half a day later it's old news.
        XCTAssertTrue(plan(s, now: date(2, 16)).isEmpty)
    }

    func testBingeTheDayAfter() {
        var s = EngagePlanner.State()
        var d = WatchDay(day: "2026-11-02")
        d.episodes = ["1", "2", "3", "4"]
        s.days = [d]
        let p = plan(s, now: date(2, 22, 30))
        XCTAssertEqual(p.map(\.moment), [.binge])
        XCTAssertEqual(p.first?.fire, date(3, 18))
        XCTAssertEqual(p.first?.body, "4 episodes yesterday. That's not a binge, that's a lifestyle.")
        s.days[0].episodes = ["1", "2", "3"]
        XCTAssertTrue(plan(s, now: date(2, 22, 30)).isEmpty)
    }

    func testAWeekAwayThenTheHouseplants() {
        var s = EngagePlanner.State()
        s.continueWatching = [film(position: 600, updated: date(1, 21))]   // not half watched: no film moment
        s.lastWatched = date(1, 21)
        let p = plan(s)
        XCTAssertEqual(p.map(\.moment), [.weekAway, .houseplants])
        XCTAssertEqual(p.map(\.fire), [date(8, 19), date(13, 19)])
        XCTAssertEqual(p[0].body, "7 days. Your Continue Watching row is gathering dust. And small spiders.")
        XCTAssertEqual(p[1].body, "The Quiet Orchard is still waiting. Unlike your houseplants, it can't die of neglect. Probably.")
    }

    func testNothingToComeBackToMeansNoWeekAway() {
        var s = EngagePlanner.State()
        s.lastWatched = date(1, 21)
        XCTAssertTrue(plan(s).isEmpty)
    }

    // MARK: Rules

    func testOneADayTheHigherPriorityWins() {
        var s = EngagePlanner.State()
        s.continueWatching = [film(position: 4000, updated: date(2, 9)),        // film: Tue 20:00
                              episode(updated: date(1, 21))]                     // paused: Tue 19:00
        XCTAssertEqual(plan(s).map(\.moment), [.paused])
    }

    func testTheSameShowThreeDaysApart() {
        var s = EngagePlanner.State()
        s.continueWatching = [episode(updated: date(1, 21), left: 3)]
        // Paused Tue 19:00; "3 left" Wed 19:00 and Friday 18:00 are the same show within three days.
        XCTAssertEqual(plan(s).map(\.moment), [.paused])
        // With the paused one gone out more than three days before Wednesday
        // (Sun 18:00): "3 left" on Wednesday, and Friday too soon after that.
        s.sent = [.init(id: plan(s)[0].id, at: date(1, 18), showKey: "s|harbor lights")]
        let p = plan(s)
        XCTAssertEqual(p.map(\.moment), [.showNearlyDone])
        XCTAssertEqual(p.first?.fire, date(4, 19))
        XCTAssertEqual(p.first?.body, "3 episodes left of Harbor Lights. Finish it, or we'll tell everyone you quit.")
    }

    func testEachOnlyOnce() {
        var s = EngagePlanner.State()
        s.continueWatching = [episode(updated: date(1, 21))]
        let first = plan(s)
        s.sent = first.map { .init(id: $0.id, at: date(1, 9), showKey: nil) }
        XCTAssertTrue(plan(s).isEmpty)
    }

    func testADayWithANewEpisodeNotificationIsTaken() {
        var s = EngagePlanner.State()
        s.continueWatching = [episode(updated: date(1, 21))]
        s.busyDays = ["2026-11-03"]
        XCTAssertTrue(plan(s).isEmpty)
    }

    func testQuietHours() {
        XCTAssertTrue(EngagePlanner.isQuiet(date(2, 22), calendar: cal))
        XCTAssertTrue(EngagePlanner.isQuiet(date(2, 8, 59), calendar: cal))
        XCTAssertFalse(EngagePlanner.isQuiet(date(2, 9), calendar: cal))
        XCTAssertFalse(EngagePlanner.isQuiet(date(2, 21, 59), calendar: cal))
    }

    func testNothingPastTheHorizon() {
        var s = EngagePlanner.State()
        s.continueWatching = [episode(updated: date(1, 21))]
        // Planned three weeks later, the paused moment is long gone.
        XCTAssertTrue(plan(s, now: date(22, 10)).filter { $0.moment == .paused }.isEmpty)
    }

    // MARK: Pieces

    func testEpisodesLeftCountsEachEpisodeOnce() {
        let names = ["Show S01E01.mkv", "Show S01E02.mkv", "Show S01E02 1080p.mkv", "Show S01E03.mkv", "Show S01E04.mkv"]
        XCTAssertEqual(EngagePlanner.episodesLeft(names, at: 1, finished: false), 3)      // E2 (this one), E3, E4
        XCTAssertEqual(EngagePlanner.episodesLeft(names, at: 1, finished: true), 2)
        XCTAssertEqual(EngagePlanner.episodesLeft(names, at: 4, finished: true), 0)
    }

    func testClock() {
        XCTAssertEqual(EngagePlanner.clock(1864), "31:04")
        XCTAssertEqual(EngagePlanner.clock(3729), "1:02:09")
    }

    func testNewEpisodeAndNewSeasonWording() {
        let e = AiringEpisode(season: 2, number: 4, title: nil, airDate: Date(), day: nil)
        XCTAssertEqual(EngagePlanner.airingWording(show: "Harbor Lights", episode: e).title, "Harbor Lights S2 · E4 is out")
        XCTAssertEqual(EngagePlanner.airingWording(show: "Harbor Lights", episode: e).body, "Your evening plans just changed.")
        let premiere = AiringEpisode(season: 3, number: 1, title: nil, airDate: Date(), day: nil)
        XCTAssertEqual(EngagePlanner.airingWording(show: "Harbor Lights", episode: premiere).title, "Harbor Lights S3 is out")
        XCTAssertEqual(EngagePlanner.airingWording(show: "Harbor Lights", episode: premiere).body,
                       "Good news: something to watch. Bad news: there goes sleep.")
    }

    func testDownloadWording() {
        let w = EngagePlanner.downloadWording(fileName: "Harbor.Lights.S02E06.1080p.WEB.mkv")
        XCTAssertEqual(w?.title, "Harbor Lights S2 · E6 is downloaded")
        XCTAssertEqual(w?.body, "The internet can't stop you now.")
        XCTAssertNil(EngagePlanner.downloadWording(fileName: "The.Quiet.Orchard.2024.1080p.mkv"))
    }

    /// The tracker's notification takes the voice in the day only.
    func testAiringVoiceInTheDayOnly() {
        var day = TrackedShow(id: "tt1", name: "Harbor Lights")
        day.next = AiringEpisode(season: 2, number: 4, title: "Low Tide", airDate: date(3, 20), day: nil)
        var night = TrackedShow(id: "tt2", name: "Night Shift")
        night.next = AiringEpisode(season: 4, number: 5, title: "Square One", airDate: date(4, 2), day: nil)
        let voiced = AiringNotifications.plan([day, night], now: monday, mode: .air, voice: true, calendar: cal)
        XCTAssertEqual(voiced.map(\.title), ["Harbor Lights S2 · E4 is out", "Night Shift S4 · E5 is out"])
        XCTAssertEqual(voiced.map(\.body), ["Your evening plans just changed.", "Square One"])
        let plain = AiringNotifications.plan([day], now: monday, mode: .air, calendar: cal)
        XCTAssertEqual(plain.first?.body, "Low Tide")
    }

    func testLabSamplesCoverEveryText() {
        XCTAssertEqual(EngagePlanner.labSamples().count, 12)
    }
}
