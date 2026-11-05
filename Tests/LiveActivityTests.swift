import XCTest
@testable import Folio

/// The Live Activities' content (1.22.0): the downloads activity's run,
/// texts and when it ends (DownloadActivity).
final class LiveActivityTests: XCTestCase {
    typealias Download = DownloadActivityAttributes.ContentState

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
}
