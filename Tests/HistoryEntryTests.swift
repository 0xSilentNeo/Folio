import XCTest
@testable import Folio

/// When a history entry counts as finished (HistoryEntry.isFinished, 1.20.2):
/// a clip shorter than 90 s used to count as watched before it began.
final class HistoryEntryTests: XCTestCase {
    private func entry(_ position: Double, of duration: Double) -> HistoryEntry {
        HistoryEntry(item: MediaItem(url: "file:///lab/Media/clip.mp4", title: "Clip", source: .url),
                     position: position, duration: duration, updated: Date(), watched: nil)
    }

    func testAShortClipIsNotFinishedAtTheStart() {
        XCTAssertFalse(entry(0, of: 60).isFinished)
        XCTAssertFalse(entry(30, of: 60).isFinished)
        XCTAssertTrue(entry(56, of: 60).isFinished)          // over 92%
    }

    func testTheCreditsOfAnEpisodeCountAsFinished() {
        XCTAssertTrue(entry(820, of: 900).isFinished)        // 80 s left of 15 min: 91%, the credits rule
        XCTAssertFalse(entry(800, of: 900).isFinished)       // 100 s left
        XCTAssertFalse(entry(1200, of: 1421).isFinished)
    }

    func testTheCreditsRuleNeedsTenMinutes() {
        XCTAssertFalse(entry(500, of: 580).isFinished)       // 80 s left of 9:40: 86%
    }

    func testAFiveMinuteVideoNeedsMostOfItWatched() {
        XCTAssertFalse(entry(220, of: 300).isFinished)       // 80 s left, 73%
        XCTAssertTrue(entry(280, of: 300).isFinished)
    }

    func testResumeNeedsFifteenSecondsAndNotFinished() {
        XCTAssertFalse(entry(10, of: 60).canResume)
        XCTAssertTrue(entry(20, of: 60).canResume)
    }
}
