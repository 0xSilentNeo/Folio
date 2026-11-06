import XCTest
@testable import Folio

/// 1.24.0: the widgets' redesign — the watch log behind Your week, the next
/// episode's label, the Airing snapshot's recent episodes, where an aired
/// episode is, and the new links and files.
@MainActor
final class Widgets124Tests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        return c
    }()

    private func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = cal.timeZone
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return f.date(from: s)!
    }

    // MARK: Watch log

    func testTheWatchLogCountsAWeek() {
        let log = WatchLog(url: nil, days: [])
        let now = date("2026-11-06T21:00:00")
        log.add(seconds: 1500, at: date("2026-11-06T20:00:00"), id: "a1", isEpisode: true, showKey: "s|show a", showName: "Show A", calendar: cal)
        log.add(seconds: 1400, at: date("2026-11-06T20:30:00"), id: "a2", isEpisode: true, showKey: "s|show a", showName: "Show A", calendar: cal)
        log.add(seconds: 600, at: date("2026-11-06T20:40:00"), id: "a2", isEpisode: true, showKey: "s|show a", showName: "Show A", calendar: cal)
        // A film over 90 minutes (the player adds a few seconds at a time; an hour or more at once is refused).
        for m in [0, 30, 60] {
            log.add(seconds: 1800, at: date("2026-11-04T22:00:00").addingTimeInterval(Double(m) * 60), id: "f1", isEpisode: false, showKey: nil, showName: nil, calendar: cal)
        }
        // Two late-night minutes: counted for that day, and its latest moment kept.
        log.add(seconds: 120, at: date("2026-11-05T03:12:00"), id: "b1", isEpisode: true, showKey: "s|show b", showName: "Show B", calendar: cal)
        // Eight days ago: outside the week.
        log.add(seconds: 3000, at: date("2026-10-29T20:00:00"), id: "old", isEpisode: false, showKey: nil, showName: nil, calendar: cal)

        let w = log.week(now: now, calendar: cal)
        XCTAssertEqual(w.seconds, 1500 + 1400 + 600 + 5400 + 120)
        XCTAssertEqual(w.episodes, 3)
        XCTAssertEqual(w.films, 1)
        XCTAssertEqual(w.shows, 2)
        XCTAssertEqual(w.perDay.count, 7)
        XCTAssertEqual(w.perDay.last, 3500)
        XCTAssertNil(w.countingSince)                        // the log began before this week
        XCTAssertEqual(log.day(date("2026-11-05T12:00:00"), calendar: cal)?.lateSeconds, 120)
        XCTAssertEqual(log.day(date("2026-11-05T12:00:00"), calendar: cal)?.lateUntil, date("2026-11-05T03:12:00"))
        XCTAssertEqual(log.day(now, calendar: cal)?.showEpisodes["s|show a"], ["a1", "a2"])
    }

    func testANewLogSaysWhenItBeganCounting() {
        let log = WatchLog(url: nil, days: [])
        log.add(seconds: 60, at: date("2026-11-05T20:00:00"), id: "a", isEpisode: false, showKey: nil, showName: nil, calendar: cal)
        let w = log.week(now: date("2026-11-06T21:00:00"), calendar: cal)
        XCTAssertEqual(w.countingSince, cal.startOfDay(for: date("2026-11-05T20:00:00")))
        // A seek or an hour-long jump isn't watching.
        log.add(seconds: 4000, at: date("2026-11-06T20:00:00"), id: "a", isEpisode: false, showKey: nil, showName: nil, calendar: cal)
        XCTAssertNil(log.day(date("2026-11-06T20:00:00"), calendar: cal))
    }

    func testWeekDurations() {
        XCTAssertEqual(WeekGlance.duration(0), "0 min")
        XCTAssertEqual(WeekGlance.duration(35 * 60), "35 min")
        XCTAssertEqual(WeekGlance.duration(4 * 3600 + 20 * 60), "4 h 20")
        XCTAssertEqual(WeekGlance.duration(2 * 3600 + 5 * 60), "2 h 05")
        XCTAssertEqual(WeekGlance.duration(3 * 3600), "3 h")
    }

    // MARK: The next episode's label

    func testTheNextEpisodesLabel() {
        let p = TitleParser.parse("Show S02E03.mkv")
        XCTAssertEqual(NextUp.label(TitleParser.parse("Show S02E04.mkv"), after: p), "E4")
        XCTAssertEqual(NextUp.label(TitleParser.parse("Show S03E01.mkv"), after: p), "S3 · E1")
        XCTAssertNil(NextUp.label(TitleParser.parse("Show Extras.mkv"), after: p))
        XCTAssertEqual(NextUp.label(TitleParser.parse("[Grp] Anime - 08.mkv"), after: TitleParser.parse("[Grp] Anime - 07.mkv")), "E8")
    }

    // MARK: Airing: recent episodes and where they are

    private func show(_ id: String, _ name: String, aired: [(Int, Int, TimeInterval)], now: Date) -> TrackedShow {
        var s = TrackedShow(id: id, name: name)
        let eps = aired.map { AiringEpisode(season: $0.0, number: $0.1, title: nil, airDate: now.addingTimeInterval($0.2)) }
        s.lastAired = eps.filter { $0.airDate! <= now }.last
        s.next = eps.first { $0.airDate! > now }
        s.later = Array(eps.filter { $0.airDate! > now }.dropFirst())
        return s
    }

    func testTheSnapshotKeepsTheWeeksEpisodesAndTheCount() {
        let now = date("2026-11-06T21:00:00")
        let a = show("a", "Salt and Iron", aired: [(2, 1, -3 * 3600), (2, 2, 7 * 86400 - 3 * 3600)], now: now)
        let b = show("b", "Old Show", aired: [(1, 9, -9 * 86400)], now: now)
        let c = show("c", "Night Shift", aired: [(4, 4, -2 * 86400), (4, 5, 3600)], now: now)
        let snap = AiringSnapshotWriter.snapshot([a, b, c], now: now)
        XCTAssertEqual(snap.tracked, 3)
        XCTAssertEqual(snap.recent?.map(\.id), ["a|S2 · E1", "c|S4 · E4"])   // newest first; nine days ago is out
        XCTAssertEqual(snap.recent?.first?.season, 2)
        XCTAssertEqual(snap.recent?.first?.number, 1)
        XCTAssertNil(snap.recent?.first?.available)
    }

    func testAnAiredEpisodeIsFoundInTheLibraryByItsShowsNames() {
        var s = TrackedShow(id: "x", name: "The Gentlemen")
        s.otherNames = ["Gentlemen (2024)"]
        let files = [URL(fileURLWithPath: "/m/The.Gentlemen.S02E01.1080p.mkv"), URL(fileURLWithPath: "/m/The.Gentlemen.S02E02.1080p.mkv"),
                     URL(fileURLWithPath: "/m/Other.Show.S02E02.mkv")]
        XCTAssertEqual(EpisodeFinder.find(s, season: 2, episode: 2, libraryFiles: files)?.item.url, "/m/The.Gentlemen.S02E02.1080p.mkv")
        XCTAssertEqual(EpisodeFinder.find(s, season: 2, episode: 2, libraryFiles: files)?.place, "in your library")
        XCTAssertNil(EpisodeFinder.find(s, season: 1, episode: 2, libraryFiles: files))      // another season
        XCTAssertNil(EpisodeFinder.find(s, season: 2, episode: 3, libraryFiles: files))
    }

    // MARK: Links and files

    func testTheNewLinks() {
        let next = ContinueLink.nextURL(id: "/var/mobile/Media/Show S01E01.mkv")
        XCTAssertEqual(ContinueLink.id(from: next), "/var/mobile/Media/Show S01E01.mkv")
        XCTAssertTrue(ContinueLink.wantsNext(next))
        XCTAssertFalse(ContinueLink.wantsNext(ContinueLink.url(id: "a")))

        let aired = TrackLink.aired(id: "tt123", season: 2, episode: 1)
        XCTAssertEqual(aired.host, "aired")
        XCTAssertEqual(GlanceLink.value("id", in: aired), "tt123")
        XCTAssertEqual(GlanceLink.value("s", in: aired), "2")
        XCTAssertEqual(GlanceLink.value("e", in: aired), "1")

        let lib = GlanceLink.library(file: "Films/A & B (2024).mkv")
        XCTAssertEqual(GlanceLink.value("file", in: lib), "Films/A & B (2024).mkv")
        let rel = GlanceLink.release(server: "1E5C06D7-1290-4C33-8B5D-000000000000", folder: "Show.S01.2160p-GRP")
        XCTAssertEqual(GlanceLink.value("name", in: rel), "Show.S01.2160p-GRP")
        XCTAssertNil(TrackLink.id(from: TrackLink.list))
    }

    func testGlanceFilesRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = WidgetStore.folder(dir)
        let week = WeekGlance(seconds: 15600, shows: 3, films: 1, episodes: 9, perDay: [0, 0, 0, 0, 0, 0, 15600], countingSince: nil, day: Date(timeIntervalSince1970: 1_800_000_000))
        try week.write(to: store)
        XCTAssertEqual(WeekGlance.read(from: store), week)
        let picks = PicksGlance(picks: [.init(file: "Films/A.mkv", title: "A", line: "Film · 2024 · in your library")])
        try picks.write(to: store)
        XCTAssertEqual(PicksGlance.read(from: store), picks)
        XCTAssertEqual(PickIndex.current(store), 0)
        PickIndex.advance(store)
        PickIndex.advance(store)
        XCTAssertEqual(PickIndex.current(store), 2)
    }

    func testOldSnapshotsStillRead() throws {
        // A 1.23 snapshot has none of the new fields.
        let old = #"{"items":[{"id":"x","title":"Show","line":"S1 · E2","progress":0.5,"remaining":600}]}"#
        let snap = try JSONDecoder().decode(ContinueSnapshot.self, from: Data(old.utf8))
        XCTAssertNil(snap.items[0].episode)
        XCTAssertTrue(snap.items[0].isFilm)
        let air = #"{"items":[]}"#
        XCTAssertNil(try JSONDecoder().decode(AiringSnapshot.self, from: Data(air.utf8)).recent)
    }

    func testShortTimesLeft() {
        func item(_ remaining: Double) -> ContinueSnapshot.Item { .init(id: "x", title: "X", progress: 0.5, remaining: remaining) }
        XCTAssertEqual(item(540).shortRemaining, "9m")
        XCTAssertEqual(item(4320).shortRemaining, "1h 12m")
        XCTAssertEqual(item(7200).shortRemaining, "2h")
        XCTAssertEqual(item(20).shortRemaining, "1m")
    }
}
