import XCTest
@testable import Folio

/// The downloads Live Activity's speed and time left (1.22.3). On the
/// 4 Nov phone report (1.22.1) it said "48:34 left, 319 KB/s" and the log
/// "ends in 2760s at 337 KB/s" for a file that was in 25 s later: the
/// estimate was taken from the first seconds (a running average seeded with
/// the first reading, while the connections were starting), and with Folio
/// suspended nothing corrected it until the end.
final class DownloadSpeedTests: XCTestCase {
    typealias State = DownloadActivityAttributes.ContentState
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    /// The report's file: 2760 s at 337 KB/s.
    private let size: Int64 = 930_000_000

    /// Readings once a second as the report's download went: nothing for a
    /// second (connections starting), two slow seconds, then 46 MB/s.
    private func reportTrace() -> [Int64] { [0, 0, 337_000, 300_000] + Array(repeating: 46_000_000, count: 20) }

    func testNoEstimateFromTheFirstSeconds() {
        var m = SpeedMeter()
        let trace = reportTrace()
        for (t, bytes) in trace.prefix(4).enumerated() { m.add(bytes, at: TimeInterval(t)) }
        // At 3 s: 637 KB in so far, and the meter won't estimate from it.
        XCTAssertGreaterThan(m.rate, 0)
        XCTAssertFalse(m.settled(at: 3))
        XCTAssertEqual(m.estimate(at: 3), 0)
        // So the activity has no time left yet, rather than 46 minutes.
        var item = DownloadItem(url: URL(string: "https://x.invalid/E.mkv")!, fileName: "E.mkv", package: "P", expected: size,
                                destination: URL(fileURLWithPath: "/x/Documents/Media/P/E.mkv"))
        item.state = .running
        item.received = 637_000
        let early = DownloadActivity.state([item], run: [item.id], speed: m.estimate(at: 3), now: t0) { $0.fileName }
        XCTAssertNil(early.timerRange)
        XCTAssertNil(early.secondsLeft)
        // What 1.22.1 sent from such a reading.
        let old = DownloadActivity.state([item], run: [item.id], speed: 337_000, now: t0) { $0.fileName }
        XCTAssertEqual(old.secondsLeft ?? 0, 2758, accuracy: 5)
    }

    func testTheEstimateFollowsTheSpeedWithinAWindow() throws {
        var m = SpeedMeter()
        var received: Int64 = 0
        var estimates: [Double] = []
        for (t, bytes) in reportTrace().enumerated() {
            m.add(bytes, at: TimeInterval(t))
            received += bytes
            let speed = m.estimate(at: TimeInterval(t))
            estimates.append(speed > 0 ? Double(size - received) / speed : -1)
        }
        // Settled at 4 s (bytes since 1 s), and from 9 s on the window holds only fast seconds.
        XCTAssertEqual(estimates[3], -1)
        XCTAssertGreaterThan(estimates[4], 0)
        XCTAssertEqual(m.rate, 46_000_000, accuracy: 1)
        // At 9 s: 690 MB left at 46 MB/s, 15 s; the file was in at ~24 s.
        XCTAssertEqual(estimates[9], Double(size - receivedBy(9)) / 46_000_000, accuracy: 0.5)
        XCTAssertLessThan(estimates[9], 20)
        // Never anywhere near the report's 2760 s.
        XCTAssertLessThan(try XCTUnwrap(estimates.filter { $0 > 0 }.max()), 120)
    }

    private func receivedBy(_ t: Int) -> Int64 { reportTrace().prefix(t + 1).reduce(0, +) }

    func testAfterASuspensionItIsTheAverageOverTheGap() {
        var m = SpeedMeter()
        for t in 0..<6 { m.add(2_000_000, at: TimeInterval(t)) }
        XCTAssertEqual(m.rate, 2_000_000, accuracy: 1)
        // Suspended for a minute while iOS downloaded 120 MB: that's 2 MB/s, not 120 MB/s.
        m.add(120_000_000, at: 65)
        XCTAssertEqual(m.rate, 120_000_000 / 60, accuracy: 1)
        XCTAssertTrue(m.settled(at: 65))
    }

    func testAStallReadsAsNothingWithinTheWindow() {
        var m = SpeedMeter()
        for t in 0..<6 { m.add(1_000_000, at: TimeInterval(t)) }
        for t in 6..<12 { m.add(0, at: TimeInterval(t)) }
        XCTAssertEqual(m.rate, 0)
        m.reset()
        XCTAssertEqual(m.rate, 0)
        XCTAssertFalse(m.settled(at: 100))
    }

    func testFolioUpdatesTheActivityInTheBackgroundWhileItMeasures() {
        // Files downloading in Folio: their progress comes in in the background too.
        XCTAssertTrue(DownloadActivity.mayUpdate(background: true, measuring: true, corrected: false))
        // iOS's background session (a download begun by 1.22.2): only the catch-up's numbers.
        XCTAssertFalse(DownloadActivity.mayUpdate(background: true, measuring: false, corrected: false))
        XCTAssertTrue(DownloadActivity.mayUpdate(background: true, measuring: false, corrected: true))
        XCTAssertTrue(DownloadActivity.mayUpdate(background: false, measuring: false, corrected: false))
    }

    func testASettledSpeedGivesTheRightEnd() throws {
        var item = DownloadItem(url: URL(string: "https://x.invalid/E.mkv")!, fileName: "E.mkv", package: "P", expected: size,
                                destination: URL(fileURLWithPath: "/x/Documents/Media/P/E.mkv"))
        item.state = .running
        item.received = 240_000_000
        let s = DownloadActivity.state([item], run: [item.id], speed: 46_000_000, now: t0) { $0.fileName }
        XCTAssertEqual(try XCTUnwrap(s.finishBy).timeIntervalSince(t0), 15, accuracy: 0.01)
        XCTAssertEqual(s.speedText, ByteCountFormatter.string(fromByteCount: 46_000_000, countStyle: .file) + "/s")
    }
}
