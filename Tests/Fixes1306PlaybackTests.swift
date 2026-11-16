import XCTest
@testable import Folio

/// 1.30.6: the review of 1.30.4 and 1.30.5's playback path.
@MainActor
final class Fixes1306PlaybackTests: XCTestCase {
    private let mb = 1_048_576.0

    /// Three hiccups of a moment on a link that keeps up on average aren't
    /// a slow connection: 4 s of waiting with them is.
    func testThreeShortWaitsDoNotReconnect() {
        let short = [StallRecovery.Wait(start: 0, end: 0.6, readRate: mb),
                     StallRecovery.Wait(start: 10, end: 10.8, readRate: mb),
                     StallRecovery.Wait(start: 20, end: 21.0, readRate: mb)]
        XCTAssertNil(StallRecovery.reconnectReadRate(waits: short, now: 21.5, needRate: 3 * mb, lastReconnect: nil))
        let longer = short + [StallRecovery.Wait(start: 25, end: 27, readRate: mb)]
        XCTAssertNotNil(StallRecovery.reconnectReadRate(waits: longer, now: 27.5, needRate: 3 * mb, lastReconnect: nil))
    }

    /// A gate opened before or after a lookup waits on it gives the same
    /// answer, and only its first opening counts.
    func testSkipGate() async {
        let open = SkipGate()
        open.open(true)
        open.open(false)
        let a = await open.wait()
        XCTAssertTrue(a)

        // A lookup already waiting when the gate opens is let go with its answer.
        let later = SkipGate()
        let waiting = Task { await later.wait() }
        for _ in 0..<200 where later.waiters == 0 { await Task.yield() }
        XCTAssertEqual(later.waiters, 1, "the lookup isn't waiting on the gate")
        later.open(false)
        let b = await waiting.value
        XCTAssertFalse(b)
        XCTAssertEqual(later.waiters, 0)
    }

    /// The post-fix review's cases: a wait begun while the reading starts
    /// again isn't one of the three, but its time past the quiet window
    /// counts, so a link that dies just after a seek still reconnects.
    func testAWaitInTheQuietWindowCountsItsTimeAfterIt() {
        let quiet = [StallRecovery.Wait(start: 0, end: nil, readRate: 0.5 * mb, quietUntil: 8)]
        XCTAssertNil(StallRecovery.reconnectReadRate(waits: quiet, now: 20, needRate: 3 * mb, lastReconnect: nil), "12 s past the window")
        XCTAssertNotNil(StallRecovery.reconnectReadRate(waits: quiet, now: 23.5, needRate: 3 * mb, lastReconnect: nil), "15 s past it")
        // Two quiet hiccups and one wait after: not three waits.
        let mixed = [StallRecovery.Wait(start: 0, end: 2, readRate: nil, quietUntil: 3),
                     StallRecovery.Wait(start: 2.5, end: 4, readRate: nil, quietUntil: 3),
                     StallRecovery.Wait(start: 10, end: 14, readRate: mb)]
        XCTAssertNil(StallRecovery.reconnectReadRate(waits: mixed, now: 14, needRate: 3 * mb, lastReconnect: nil))
    }

    /// The frames' native-size rule is unchanged: a 1.33× fit is shown at
    /// the video's own size under Efficient (below 1.5×), fitted with shaders.
    func testFrameSizeRuleUnchanged() {
        XCTAssertEqual(MetalFrameRenderer.frameSize(view: (2556, 1179), video: (1920, 803), pip: nil, nativeBelow: 1.5).0, 1920)
        XCTAssertEqual(MetalFrameRenderer.frameSize(view: (2556, 1179), video: (1920, 803), pip: nil, nativeBelow: 0).0, 2556 & ~1)
    }
}
