import XCTest
@testable import Folio

/// 1.25.0: Folio's notification engine. The rules (NotifyPlanner), the
/// wording (every kind has lines, facts fill in, rotation), the signals
/// behind each kind, IMDb's chart data and the weather's.
@MainActor
final class NotifyTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        return c
    }()

    private func date(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
    }

    /// Mon 2 Nov 2026, 10:00 in Melbourne.
    private var monday: Date { date(2, 10) }

    private func rules(max: Int = 1, sent: [NotifySent] = []) -> NotifyPlanner.Rules {
        var r = NotifyPlanner.Rules(now: monday, calendar: cal)
        r.maxPerDay = max
        r.sent = sent
        return r
    }

    private func flex(_ k: NotifyKind, _ key: String, days: Double = 5, show: String? = nil) -> NotifyCandidate {
        NotifyCandidate(kind: k, key: key, window: monday...monday.addingTimeInterval(days * 86400), facts: ["title": "X"], showKey: show, reason: "test")
    }

    // MARK: Wording

    func testEveryKindHasLinesInItsTones() {
        for k in NotifyKind.allCases {
            for t in NotifyTone.allCases {
                let lines = NotifyWording.lines(k, t)
                if t == .subtle && (k.group == .fun || k.group.essential) { continue }
                XCTAssertFalse(lines.isEmpty, "\(k.rawValue) has no \(t.rawValue) lines")
            }
            XCTAssertFalse(NotifyWording.lines(k, .balanced).isEmpty, "\(k.rawValue) has no balanced lines")
        }
    }

    func testEveryKindsSampleFillsALineInEveryTone() {
        for k in NotifyKind.allCases {
            let facts = NotifyWording.sample(k, show: "Harbor Lights", film: "The Quiet Orchard", file: "VID_1.mp4")
            for t in NotifyTone.allCases where !NotifyWording.lines(k, t).isEmpty {
                XCTAssertNotNil(NotifyWording.text(k, t, facts, variation: 0), "\(k.rawValue) \(t.rawValue): the sample doesn't fill a line")
                for line in NotifyWording.usable(k, t, facts) {
                    XCTAssertFalse(line.body.contains("{"), "\(k.rawValue): unfilled \(line.body)")
                    XCTAssertFalse(line.title?.contains("{") ?? false)
                }
            }
        }
    }

    /// Balanced's first lines are the ones picked on 6 Nov.
    func testBalancedFirstLinesAreThe1240Ones() {
        XCTAssertEqual(NotifyWording.text(.paused, .balanced, ["show": "Harbor Lights", "time": "31:04"], variation: 0)?.body,
                       EngagePlanner.Text.paused("Harbor Lights", at: 1864))
        XCTAssertEqual(NotifyWording.text(.weekAway, .balanced, [:], variation: 0)?.body, EngagePlanner.Text.weekAway)
        XCTAssertEqual(NotifyWording.text(.houseplants, .balanced, ["show": "Harbor Lights"], variation: 0)?.body,
                       EngagePlanner.Text.houseplants("Harbor Lights"))
    }

    func testRotationWrapsAndSkipsLinesWithMissingFacts() {
        let a = NotifyWording.text(.binge, .balanced, ["n": "5"], variation: 0)?.body
        let b = NotifyWording.text(.binge, .balanced, ["n": "5"], variation: 1)?.body
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(NotifyWording.text(.binge, .balanced, ["n": "5"], variation: 3)?.body, a)
        // The recap without hours uses only the lines that don't need them.
        let recap = NotifyWording.usable(.monthlyRecap, .balanced, ["month": "October", "list": "A, B"])
        XCTAssertEqual(recap.count, 1)
        XCTAssertNil(NotifyWording.fill("{missing} here", [:]))
        XCTAssertEqual(NotifyWording.fill("{a} and {b}", ["a": "1", "b": "2"]), "1 and 2")
    }

    func testEssentialsKeepPlainWordingInSubtle() {
        XCTAssertNil(NotifyWording.text(.newEpisode, .subtle, ["what": "X S1 · E2"], variation: 0))
        XCTAssertEqual(NotifyCenter.plain(.downloadFinished, ["what": "X S1 · E2"])?.body, "X S1 · E2")
        let e = AiringEpisode(season: 2, number: 4, title: nil, airDate: Date(), day: nil)
        XCTAssertNil(NotifyCenter.airingWording(show: "X", episode: e, tone: .subtle, variation: 0))
        XCTAssertEqual(NotifyCenter.airingWording(show: "X", episode: e, tone: .balanced, variation: 1)?.body,
                       "We'd recommend touching grass, but there's a new episode.")
    }

    // MARK: Rules

    func testOneADayByDefaultAndMoreWhenAllowed() {
        let c = [flex(.trendingMovie, "a"), flex(.forgotten, "b"), flex(.forYouPick, "c")]
        let one = NotifyPlanner.choose(c, rules(max: 1))
        XCTAssertEqual(Set(one.map { WatchLog.dayKey($0.fire, calendar: cal) }).count, one.count, "one a day")
        let three = NotifyPlanner.choose(c, rules(max: 3))
        XCTAssertEqual(three.count, 3)
        let firstDay = three.filter { WatchLog.dayKey($0.fire, calendar: cal) == WatchLog.dayKey(three[0].fire, calendar: cal) }
        XCTAssertGreaterThan(firstDay.count, 1)
        for (a, b) in zip(firstDay, firstDay.dropFirst()) { XCTAssertGreaterThanOrEqual(b.fire.timeIntervalSince(a.fire), 2 * 3600) }
    }

    func testFlexibleOnesComeAtTheUsualTimeOutsideQuietHours() {
        var r = rules()
        r.preferredMinute = 18 * 60 + 30
        let out = NotifyPlanner.choose([flex(.trendingSeries, "a")], r)
        XCTAssertEqual(out.count, 1)
        let c = cal.dateComponents([.day, .hour, .minute], from: out[0].fire)
        XCTAssertEqual([c.day, c.hour, c.minute], [2, 18, 30])
        XCTAssertFalse(r.quiet.contains(out[0].fire, calendar: cal))
    }

    func testWeeklyLimitPerGroup() {
        let c = (0..<6).map { flex(.risingFast, "r\($0)", days: 6) }
        let out = NotifyPlanner.choose(c, rules(max: 5))
        // Trending: at most three a week (Mon 2 – Sun 8 Nov is one week).
        XCTAssertEqual(out.count, 3)
    }

    func testSentOnceAndShowSpacing() {
        let sent = [NotifySent(key: "a", kind: .forgotten, at: date(1, 19), showKey: nil)]
        XCTAssertTrue(NotifyPlanner.choose([flex(.forgotten, "a")], rules(sent: sent)).isEmpty)
        let two = [flex(.forYouPick, "x", show: "s1"), flex(.hiddenGem, "y", show: "s1")]
        let out = NotifyPlanner.choose(two, rules(max: 3))
        XCTAssertEqual(out.count, 2)
        XCTAssertGreaterThanOrEqual(abs(out[1].fire.timeIntervalSince(out[0].fire)), 3 * 86400)
    }

    func testKindsSwitchedOffAndEssentialsArentPlanned() {
        var r = rules(max: 3)
        r.allowed = { $0 != .forgotten }
        let out = NotifyPlanner.choose([flex(.forgotten, "a"), flex(.forYouPick, "b")], r)
        XCTAssertEqual(out.map(\.candidate.kind), [.forYouPick])
    }

    func testFixedMomentsKeepTheirTimeAndQuietHoursDropThem() {
        let ok = NotifyCandidate(kind: .movieNight, key: "m", fire: date(6, 18, 30), reason: "t")
        let late = NotifyCandidate(kind: .lateNightThriller, key: "l", fire: date(6, 23), reason: "t")
        let out = NotifyPlanner.choose([ok, late], rules(max: 3))
        XCTAssertEqual(out.map(\.candidate.key), ["m"])
        XCTAssertEqual(out.first?.fire, date(6, 18, 30))
    }

    func testQuietHours() {
        let q = QuietHours.standard
        XCTAssertTrue(q.contains(date(2, 23), calendar: cal))
        XCTAssertTrue(q.contains(date(2, 8, 59), calendar: cal))
        XCTAssertFalse(q.contains(date(2, 9), calendar: cal))
        XCTAssertFalse(QuietHours(start: 0, end: 0).contains(date(2, 3), calendar: cal))
        let day = QuietHours(start: 13 * 60, end: 14 * 60)
        XCTAssertTrue(day.contains(date(2, 13, 30), calendar: cal))
        XCTAssertFalse(day.contains(date(2, 14, 30), calendar: cal))
    }

    func testPreferredMinuteFollowsWhenYouWatch() {
        XCTAssertEqual(NotifyPlanner.preferredMinute(firstHours: [], quiet: .standard), 19 * 60)
        XCTAssertEqual(NotifyPlanner.preferredMinute(firstHours: [20, 21, 20, 22], quiet: .standard), 21 * 60 - 30)
        // Usually at 23:00 with quiet hours from 22:00: an hour before they start.
        XCTAssertEqual(NotifyPlanner.preferredMinute(firstHours: [23, 23, 23], quiet: .standard), 21 * 60)
    }

    func testTestTimesAreTwentySecondsApart() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(NotifyPlanner.testTimes(3, from: now).map { $0.timeIntervalSince(now) }, [20, 40, 60])
    }

    // MARK: Signals

    private func entry(_ id: String, _ rank: Int, _ change: Int, rating: Double? = 7.5, votes: Int? = 20000, year: Int = 2026,
                       type: String = "movie", genres: [String] = ["Drama"]) -> TrendEntry {
        TrendEntry(id: id, title: "T\(id)", type: type, rank: rank, change: change, rating: rating, votes: votes, genres: genres, year: year, poster: nil)
    }

    func testTrendingSignals() {
        var x = NotifySignals.Inputs(now: monday, calendar: cal)
        x.trend = TrendFeed.Snapshot(fetched: monday.addingTimeInterval(-3600),
                                     movies: [entry("tt1", 1, 0), entry("tt2", 8, 140), entry("tt3", 9, 2, rating: 5.1, votes: 3000),
                                              entry("tt4", 16, 65, rating: 7.9, votes: 420000, year: 1993), entry("tt5", 20, 3, rating: 8.8)],
                                     series: [entry("tt9", 1, 0, type: "series"), entry("tt8", 30, 5, rating: 9.1, type: "series")],
                                     previousVotes: ["tt4": 240000], previousIDs: ["tt1", "tt9"])
        let kinds = Set(NotifySignals.trending(x).map(\.kind))
        XCTAssertTrue(kinds.isSuperset(of: [.trendingMovie, .trendingSeries, .risingFast, .viral, .lowRatedPopular, .comeback,
                                            .ratingMilestone, .topRated, .highlyRatedSeries]), "\(kinds)")
        let milestone = NotifySignals.trending(x).first { $0.kind == .ratingMilestone }
        XCTAssertEqual(milestone?.facts["votes"], "250K")
        // A chart older than four days says nothing.
        x.trend?.fetched = monday.addingTimeInterval(-5 * 86400)
        XCTAssertTrue(NotifySignals.trending(x).isEmpty)
    }

    func testTrendingSkipsWhatYouveWatched() {
        var x = NotifySignals.Inputs(now: monday, calendar: cal)
        x.trend = TrendFeed.Snapshot(fetched: monday, movies: [entry("tt1", 1, 0)], series: [])
        x.watched = [.init(at: monday, genres: [], imdbID: "tt1")]
        XCTAssertFalse(NotifySignals.trending(x).contains { $0.kind == .trendingMovie })
    }

    func testLibrarySignals() {
        var x = NotifySignals.Inputs(now: monday, calendar: cal)
        let old = monday.addingTimeInterval(-90 * 86400)
        x.films = (0..<25).map { i in
            .init(title: "Film \(i)", path: "/m/\(i).mkv", added: old, played: false, watched: false,
                  imdbID: i == 3 ? "tt0068646" : nil, rating: nil, poster: nil)
        }
        x.top250 = ["tt0068646"]
        x.filmsBefore = 24
        x.mystery = ["VID_20250614.mp4"]
        let c = NotifySignals.library(x)
        XCTAssertEqual(Set(c.map(\.kind)), [.forgotten, .bigCollection, .unwatchedClassic, .mysteryFile, .milestone])
        XCTAssertEqual(c.first { $0.kind == .unwatchedClassic }?.facts["title"], "Film 3")
        XCTAssertEqual(c.first { $0.kind == .milestone }?.facts["n"], "25")
    }

    func testFunSignals() {
        var x = NotifySignals.Inputs(now: monday, calendar: cal)
        x.habits = [.init(day: "2026-11-01", opens: 6, opensPlayed: 0, idleMinutes: 45)]
        x.watchDays = (0..<6).map { i in
            var d = WatchDay(day: WatchLog.dayKey(monday.addingTimeInterval(Double(-i) * 86400), calendar: cal))
            d.seconds = 1800
            return d
        }
        x.continueCount = 6
        x.forecast = [.init(day: "2026-11-03", maxC: 18, minC: 9, rain: 90), .init(day: "2026-11-04", maxC: 5, minC: 1, rain: 10)]
        x.holidays = [.init(date: "2026-11-03", name: "Melbourne Cup Day")]
        let kinds = Set(NotifySignals.fun(x).map(\.kind))
        XCTAssertTrue(kinds.isSuperset(of: [.openedNoWatch, .longChoosing, .streak, .unfinishedPile, .movieNight, .rainy, .cold, .holiday]), "\(kinds)")
        XCTAssertEqual(NotifySignals.fun(x).first { $0.kind == .streak }?.facts["n"], "6")
    }

    // MARK: Data

    /// The shape of IMDb's chart page data, as on the live page (7 Nov).
    func testTrendEntriesFromChartData() {
        let node: [String: Any] = [
            "id": "tt1234567", "titleText": ["text": "Collision Course"], "titleType": ["id": "movie"],
            "releaseYear": ["year": 2026], "ratingsSummary": ["aggregateRating": 5.6, "voteCount": 2199],
            "titleGenres": ["genres": [["genre": ["text": "Action"]]]],
            "meterRanking": ["currentRank": 13, "rankChange": ["changeDirection": "UP", "difference": 4973]],
        ]
        let down: [String: Any] = [
            "id": "tt7654321", "titleText": ["text": "Wildwood"], "titleType": ["id": "tvSeries"],
            "meterRanking": ["currentRank": 3, "rankChange": ["changeDirection": "DOWN", "difference": 2]],
        ]
        let e = IMDbSource.trendEntries(["props": ["edges": [["node": node], ["node": down]]]], type: "movie")
        XCTAssertEqual(e.map(\.id), ["tt7654321", "tt1234567"])
        XCTAssertEqual(e[1].change, 4973)
        XCTAssertEqual(e[1].votes, 2199)
        XCTAssertEqual(e[1].rating, 5.6)
        XCTAssertEqual(e[1].year, 2026)
        XCTAssertEqual(e[0].change, -2)
        XCTAssertEqual(e[0].type, "series")
    }

    /// Open-Meteo's daily forecast (the shape of its answer, 7 Nov).
    func testWeatherParse() {
        let json = #"{"daily":{"time":["2026-11-07","2026-11-08"],"temperature_2m_max":[28.3,16.2],"temperature_2m_min":[13.2,10.4],"precipitation_probability_max":[100,86]}}"#
        let d = WeatherFeed.parse(Data(json.utf8))
        XCTAssertEqual(d?.count, 2)
        XCTAssertEqual(d?[1].rain, 86)
        XCTAssertEqual(d?[0].maxC, 28.3)
        XCTAssertEqual(WeatherFeed.degrees(0, locale: Locale(identifier: "en_US")), "32°")
        XCTAssertEqual(WeatherFeed.degrees(4.4, locale: Locale(identifier: "en_AU")), "4°")
    }

    func testLinks() {
        let l = TitleLink.make(id: "tt1", type: "series", name: "Harbor & Lights", poster: nil)
        let m = TitleLink.meta(from: URL(string: l)!)
        XCTAssertEqual(m?.id, "tt1")
        XCTAssertEqual(m?.name, "Harbor & Lights")
        XCTAssertEqual(LibraryLink.path(from: URL(string: LibraryLink.url("/a b/c.mkv"))!), "/a b/c.mkv")
    }

    func testSoundChoicesRoundTrip() {
        for s in [NotifySound.standard, .none, .folio("reel"), .apple("New/Bloom.caf"), .custom("custom-x.caf")] {
            XCTAssertEqual(NotifySound(s.stored), s)
        }
        XCTAssertEqual(NotifySound.apple("sms-received1.caf").label, "Tri-tone")
        XCTAssertEqual(NotifySound.apple("New/Sherwood_Forest.caf").label, "Sherwood Forest")
    }

    func testWatchDayDecodesWithoutHours() throws {
        let old = #"[{"day":"2026-11-01","seconds":60,"lateSeconds":0,"episodes":[],"films":[],"shows":{},"showEpisodes":{}}]"#
        let d = try JSONDecoder().decode([WatchDay].self, from: Data(old.utf8))
        XCTAssertNil(d[0].hours)
    }
}
