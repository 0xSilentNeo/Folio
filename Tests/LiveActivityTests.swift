import XCTest
@testable import Folio

/// The Live Activities' content (1.22.0): the downloads activity's run,
/// texts and when it ends (DownloadActivity), the now-playing activity's
/// progress, time left and when ActivityKit needs an update
/// (NowPlayingActivity).
final class LiveActivityTests: XCTestCase {
    typealias Download = DownloadActivityAttributes.ContentState
    typealias Playing = NowPlayingActivityAttributes.ContentState

    // MARK: Text

    func testMinutesLeft() {
        XCTAssertEqual(ActivityFormat.minutesLeft(20), "Less than a minute left")
        XCTAssertEqual(ActivityFormat.minutesLeft(60), "1 min left")
        XCTAssertEqual(ActivityFormat.minutesLeft(61), "2 min left")
        XCTAssertEqual(ActivityFormat.minutesLeft(12 * 60), "12 min left")
        XCTAssertEqual(ActivityFormat.minutesLeft(3600), "1 h left")
        XCTAssertEqual(ActivityFormat.minutesLeft(3900), "1 h 5 min left")
        XCTAssertEqual(ActivityFormat.minutesLeft(.infinity), "")
    }

    func testClock() {
        XCTAssertEqual(ActivityFormat.clock(0), "0:00")
        XCTAssertEqual(ActivityFormat.clock(245.9), "4:05")
        XCTAssertEqual(ActivityFormat.clock(754), "12:34")
        XCTAssertEqual(ActivityFormat.clock(3723), "1:02:03")
        XCTAssertEqual(ActivityFormat.clock(-5), "0:00")
        XCTAssertEqual(ActivityFormat.clock(.nan), "0:00")
    }

    func testDownloadTexts() {
        var s = Download(title: "Mob Land · S01E03", filesLeft: 3, progress: 0.426, speed: 2_400_000, secondsLeft: 760)
        XCTAssertEqual(s.percentText, "42%")
        XCTAssertTrue(s.speedText.hasSuffix("/s"), s.speedText)
        XCTAssertEqual(s.detailText, "13 min left · 3 files")
        XCTAssertEqual(s.headline, "Mob Land · S01E03")
        s.filesLeft = 1
        XCTAssertEqual(s.detailText, "13 min left")
        s.secondsLeft = nil
        XCTAssertNil(s.detailText, "no speed yet: nothing to say")
        s.waiting = true
        s.filesLeft = 2
        XCTAssertEqual(s.detailText, "Waiting to retry · 2 files")
        s.progress = 1.3
        XCTAssertEqual(s.percentText, "100%")
    }

    func testDoneTexts() {
        var s = Download(title: "x", filesLeft: 0, progress: 1, speed: 0, secondsLeft: nil, done: true, finished: 3)
        XCTAssertEqual(s.headline, "Downloads finished")
        XCTAssertEqual(s.detailText, "3 files in your library")
        s.finished = 1
        s.failed = 1
        XCTAssertEqual(s.detailText, "1 file in your library · 1 failed")
    }

    func testTheLinkOpensDownloads() {
        XCTAssertEqual(DownloadsLink.url.scheme, "folio")
        XCTAssertEqual(DownloadsLink.url.host, "downloads")
    }

    // MARK: The downloads run

    private func item(_ name: String, _ state: DownloadItem.State, received: Int64 = 0, expected: Int64 = 100,
                      notBefore: Date? = nil) -> DownloadItem {
        var d = DownloadItem(url: URL(string: "https://dav.example.invalid/\(name)")!, fileName: name, package: "P",
                             expected: expected, destination: URL(fileURLWithPath: "/x/Documents/Media/P/\(name)"))
        d.state = state
        d.received = state == .done ? expected : received
        d.notBefore = notBefore
        return d
    }

    func testPhase() {
        let a = item("a.mkv", .running, received: 50), b = item("b.mkv", .queued), c = item("c.mkv", .done)
        let run: Set<UUID> = [a.id, b.id, c.id]
        XCTAssertEqual(DownloadActivity.phase([a, b, c], run: run, conditionsOK: true), .downloading)
        // A retry's wait: still up.
        XCTAssertEqual(DownloadActivity.phase([b, c], run: run, conditionsOK: true), .waiting)
        // Held by Low Power Mode or charging: as good as paused, it goes.
        XCTAssertEqual(DownloadActivity.phase([b, c], run: run, conditionsOK: false), .stopped)
        // All done: Done.
        XCTAssertEqual(DownloadActivity.phase([c], run: run, conditionsOK: true), .finished)
        // A paused file from before this run doesn't count.
        XCTAssertEqual(DownloadActivity.phase([c, item("d.mkv", .paused)], run: run, conditionsOK: true), .finished)
        // Some done, the rest paused: not Done.
        let paused = item("e.mkv", .paused)
        XCTAssertEqual(DownloadActivity.phase([c, paused], run: run.union([paused.id]), conditionsOK: true), .stopped)
        // Cancelled (gone from the list) with nothing finished.
        XCTAssertEqual(DownloadActivity.phase([], run: run, conditionsOK: true), .stopped)
        // Failed only.
        let failed = item("f.mkv", .failed)
        XCTAssertEqual(DownloadActivity.phase([failed], run: [failed.id], conditionsOK: true), .stopped)
    }

    func testRunState() {
        let done = item("Show.S01E01.mkv", .done, expected: 200)
        let running = item("Show.S01E02.mkv", .running, received: 100, expected: 200)
        let queued = item("Show.S01E03.mkv", .queued, expected: 200)
        let earlier = item("Old.mkv", .done, expected: 10_000)       // finished before this run
        let paused = item("Paused.mkv", .paused, received: 10, expected: 200)
        let run: Set<UUID> = [done.id, running.id, queued.id, paused.id]
        let s = DownloadActivity.state([earlier, done, running, queued, paused], run: run, speed: 100) { $0.fileName }
        XCTAssertEqual(s.title, "Show.S01E02.mkv")
        XCTAssertEqual(s.filesLeft, 2)
        // 200 + 100 of 600: the earlier file and the paused one aren't counted.
        XCTAssertEqual(s.progress, 0.5, accuracy: 0.001)
        // (100 + 200) bytes left at 100 B/s.
        XCTAssertEqual(s.secondsLeft ?? -1, 3, accuracy: 0.001)
        XCTAssertFalse(s.waiting)
        XCTAssertEqual(s.finished, 1)
    }

    func testSeveralAtOnceAndWaiting() {
        let a = item("a.mkv", .running, received: 10), b = item("b.mkv", .running, received: 10)
        let s = DownloadActivity.state([a, b], run: [a.id, b.id], speed: 0) { $0.fileName }
        XCTAssertEqual(s.title, "2 files")
        XCTAssertNil(s.secondsLeft, "no speed yet")
        let q = item("q.mkv", .queued)
        let w = DownloadActivity.state([q], run: [q.id], speed: 5000) { $0.fileName }
        XCTAssertTrue(w.waiting)
        XCTAssertEqual(w.speed, 0)
        XCTAssertEqual(w.title, "q.mkv")
    }

    func testOnlyAVisibleChangeIsAnUpdate() {
        let s = Download(title: "a", filesLeft: 2, progress: 0.421, speed: 2_400_000, secondsLeft: 600)
        var t = s
        t.progress = 0.424                 // still 42%
        t.secondsLeft = 590                // still 10 min
        XCTAssertFalse(DownloadActivity.looksDifferent(s, t))
        t.progress = 0.43
        XCTAssertTrue(DownloadActivity.looksDifferent(s, t))
        var u = s
        u.filesLeft = 1
        XCTAssertTrue(DownloadActivity.looksDifferent(s, u))
    }

    // MARK: Now playing

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func playing(_ position: Double, duration: Double = 1440, paused: Bool = false, at: Date? = nil) -> Playing {
        Playing(title: "Lab Show", subtitle: "S1 · E3", artwork: nil, position: position, duration: duration, paused: paused, at: at ?? t0)
    }

    func testPlayingMovesOnByItself() {
        let s = playing(300)
        XCTAssertEqual(s.startDate, t0.addingTimeInterval(-300))
        XCTAssertEqual(s.endDate, t0.addingTimeInterval(1140))
        XCTAssertEqual(s.timerRange, t0.addingTimeInterval(-300)...t0.addingTimeInterval(1140))
        let later = t0.addingTimeInterval(60)
        XCTAssertEqual(s.position(at: later), 360)
        XCTAssertEqual(s.progress(at: later), 0.25, accuracy: 0.0001)
        XCTAssertEqual(s.timeLeft(at: later), 1080)
        XCTAssertEqual(s.timeLeftText(at: later), "18:00 left")
        // Past the end it stays at the end.
        XCTAssertEqual(s.timeLeft(at: t0.addingTimeInterval(5000)), 0)
    }

    func testPausedStandsStill() {
        let s = playing(300, paused: true)
        XCTAssertNil(s.timerRange)
        XCTAssertEqual(s.position(at: t0.addingTimeInterval(600)), 300)
        XCTAssertEqual(s.timeLeftText(at: t0.addingTimeInterval(600)), "19:00 left")
        XCTAssertNil(NowPlayingActivity.staleDate(s))
        XCTAssertEqual(NowPlayingActivity.staleDate(playing(300)), t0.addingTimeInterval(1200))
    }

    func testNoLengthKnown() {
        let s = playing(30, duration: 0)
        XCTAssertNil(s.timerRange)
        XCTAssertEqual(s.progress(at: t0), 0)
        XCTAssertEqual(s.timeLeftText(at: t0), "")
    }

    func testUpdatesOnlyOnPausePlaySeekOrLength() {
        let shown = playing(300)
        // The player reports every second: the timers already show that.
        XCTAssertFalse(NowPlayingActivity.needsUpdate(from: shown, to: playing(330, at: t0.addingTimeInterval(30))))
        XCTAssertFalse(NowPlayingActivity.needsUpdate(from: shown, to: playing(331.5, at: t0.addingTimeInterval(30))), "a little jitter")
        // Paused, played, seeked, a new length, a new video.
        XCTAssertTrue(NowPlayingActivity.needsUpdate(from: shown, to: playing(330, paused: true, at: t0.addingTimeInterval(30))))
        XCTAssertTrue(NowPlayingActivity.needsUpdate(from: playing(300, paused: true), to: playing(300, at: t0.addingTimeInterval(30))))
        XCTAssertTrue(NowPlayingActivity.needsUpdate(from: shown, to: playing(340, at: t0.addingTimeInterval(30))), "skipped 10 s")
        XCTAssertTrue(NowPlayingActivity.needsUpdate(from: shown, to: playing(320, at: t0.addingTimeInterval(30))), "back 10 s")
        XCTAssertTrue(NowPlayingActivity.needsUpdate(from: shown, to: playing(330, duration: 1500, at: t0.addingTimeInterval(30))))
        var next = playing(0, at: t0.addingTimeInterval(30))
        next.title = "Next episode"
        XCTAssertTrue(NowPlayingActivity.needsUpdate(from: shown, to: next))
        // Paused and still paused at the same place: nothing.
        XCTAssertFalse(NowPlayingActivity.needsUpdate(from: playing(300, paused: true), to: playing(300, paused: true, at: t0.addingTimeInterval(90))))
    }

    func testContentStaysSmall() throws {
        // ActivityKit refuses content over 4 KB.
        var s = playing(300)
        s.title = String(repeating: "A long title ", count: 20)
        s.subtitle = String(repeating: "S1 · E3 · A long episode title ", count: 10)
        s.artwork = "nowplaying-1234ABCD.jpg"
        XCTAssertLessThan(try JSONEncoder().encode(s).count, 4096)
    }
}
