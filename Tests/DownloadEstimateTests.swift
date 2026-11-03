import XCTest
@testable import Folio

/// The downloads Live Activity's estimate (1.22.1): Folio is suspended
/// while iOS downloads in the background, so the activity carries when the
/// run should end and its timers move on alone (4 Nov report: it showed no
/// progress). Folio corrects it whenever it runs.
final class DownloadEstimateTests: XCTestCase {
    typealias State = DownloadActivityAttributes.ContentState
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ state: DownloadItem.State, received: Int64, expected: Int64) -> DownloadItem {
        var d = DownloadItem(url: URL(string: "https://dav.example.invalid/\(UUID().uuidString).mkv")!, fileName: "E.mkv", package: "P",
                             expected: expected, destination: URL(fileURLWithPath: "/x/Documents/Media/P/E.mkv"))
        d.state = state
        d.received = received
        return d
    }

    func testTheEstimateIsTheTimeLeftAtThatSpeed() throws {
        let a = item(.running, received: 250, expected: 1000)
        let s = DownloadActivity.state([a], run: [a.id], speed: 10, now: t0) { $0.fileName }
        XCTAssertEqual(s.measuredAt, t0)
        XCTAssertEqual(s.finishBy, t0.addingTimeInterval(75))
        let range = try XCTUnwrap(s.timerRange)
        XCTAssertEqual(range.upperBound, t0.addingTimeInterval(75))
        // The ring is where the run is at the reading, full at the end, in between linearly.
        XCTAssertEqual(s.progress(at: t0), 0.25, accuracy: 0.0001)
        XCTAssertEqual(s.progress(at: t0.addingTimeInterval(37.5)), 0.625, accuracy: 0.0001)
        XCTAssertEqual(s.progress(at: t0.addingTimeInterval(500)), 1)
        XCTAssertEqual(s.timeLeftRange, t0...t0.addingTimeInterval(75))
    }

    func testNoTimersWithoutAnEstimate() {
        let a = item(.running, received: 0, expected: 1000)
        XCTAssertNil(DownloadActivity.state([a], run: [a.id], speed: 0, now: t0) { $0.fileName }.timerRange, "no speed yet")
        let q = item(.queued, received: 0, expected: 1000)
        XCTAssertNil(DownloadActivity.state([q], run: [q.id], speed: 5000, now: t0) { $0.fileName }.timerRange, "waiting")
        var done = State(title: "x", filesLeft: 0, progress: 1, speed: 0, secondsLeft: nil, done: true, measuredAt: t0, finishBy: t0.addingTimeInterval(9))
        XCTAssertNil(done.timerRange)
        done.done = false
        XCTAssertNil(done.timerRange, "nothing left")
    }

    func testOnlyAnEstimateThatMovedIsAnUpdate() {
        let shown = State(title: "E", filesLeft: 1, progress: 0.25, speed: 10, secondsLeft: 75, measuredAt: t0, finishBy: t0.addingTimeInterval(75))
        // 30 s on, right where the timers are, same speed: nothing to send.
        let onTrack = State(title: "E", filesLeft: 1, progress: 0.55, speed: 10, secondsLeft: 45,
                            measuredAt: t0.addingTimeInterval(30), finishBy: t0.addingTimeInterval(75))
        XCTAssertFalse(DownloadActivity.looksDifferent(shown, onTrack))
        // Slower than thought: it ends 40 s later.
        var slower = onTrack
        slower.progress = 0.40
        slower.finishBy = t0.addingTimeInterval(115)
        XCTAssertTrue(DownloadActivity.looksDifferent(shown, slower))
        // A file more in the queue.
        var more = onTrack
        more.filesLeft = 2
        XCTAssertTrue(DownloadActivity.looksDifferent(shown, more))
        // An estimate where there was none.
        let none = State(title: "E", filesLeft: 1, progress: 0.25, speed: 0, secondsLeft: nil)
        XCTAssertTrue(DownloadActivity.looksDifferent(none, shown))
    }

    func testStaleOnlyPastTheEstimate() {
        let s = State(title: "E", filesLeft: 1, progress: 0.25, speed: 10, secondsLeft: 600, measuredAt: t0, finishBy: t0.addingTimeInterval(600))
        XCTAssertEqual(DownloadActivity.staleDate(s, now: t0), t0.addingTimeInterval(720))
        let none = State(title: "E", filesLeft: 1, progress: 0.25, speed: 0, secondsLeft: nil)
        XCTAssertEqual(DownloadActivity.staleDate(none, now: t0), t0.addingTimeInterval(120))
        var done = none
        done.done = true
        XCTAssertNil(DownloadActivity.staleDate(done, now: t0))
    }

    func testContentStaysSmall() throws {
        let s = State(title: String(repeating: "A long file name ", count: 20), filesLeft: 12, progress: 0.5, speed: 1e7, secondsLeft: 1,
                      measuredAt: t0, finishBy: t0)
        XCTAssertLessThan(try JSONEncoder().encode(s).count, 4096)
    }
}
