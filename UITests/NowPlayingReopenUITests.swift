import XCTest

/// 1.26.2: Now Playing opens on the playing episode every time, not only the
/// first. Panels are built ahead of time and kept, so the list used to open
/// wherever it was scrolled to last (user's 8 Nov log). Runs without the
/// engine (-labNoEngine), on the system popover panels (the default).
final class NowPlayingReopenUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testReopensOnThePlayingEpisode() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-labNoEngine", "-libTrace", "-uiTestQueue=10,6"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let button = app.buttons["Now Playing"]
        XCTAssertTrue(button.waitForExistence(timeout: 20), "no Now Playing button")
        sleep(3)                                    // the panels are prebuilt meanwhile

        let playing = app.buttons["q5"].firstMatch
        let first = app.buttons["q0"].firstMatch
        button.tap()
        XCTAssertTrue(playing.waitForExistence(timeout: 5))
        sleep(2)
        XCTAssertTrue(playing.isHittable, "E6 not on screen when the panel first opens")

        // Scroll to the start of the list, away from E6.
        // Dragged by screen points over E6's row (the rows report odd frames
        // to the test while the popover is up).
        let spot = playing.frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        for _ in 0..<4 {
            let from = origin.withOffset(CGVector(dx: spot.midX, dy: spot.minY))
            from.press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: spot.midX, dy: spot.minY + 260)))
            sleep(1)
        }
        let onScreen = { (e: XCUIElement) in e.exists && !e.frame.isEmpty && app.windows.firstMatch.frame.contains(CGPoint(x: e.frame.midX, y: e.frame.midY)) && e.isHittable }
        print("NOWPLAYING after scrolling: E1 \(first.frame) E6 \(playing.frame)")
        guard onScreen(first), !onScreen(playing) || playing.frame.minY > spot.maxY + 40 else {
            throw XCTSkip("the panel shows E1 and E6 together at this size; nothing to scroll away from")
        }

        // Close, and open again: back on E6.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        sleep(2)
        button.tap()
        sleep(2)
        print("NOWPLAYING reopened: E1 \(first.frame) E6 \(playing.frame), first open E6 \(spot)")
        XCTAssertEqual(playing.frame.midY, spot.midY, accuracy: 30, "E6 isn't where it was on the first opening: the panel kept the scroll position")
    }

    /// The case in the 8 Nov log: the panel was prebuilt on one episode and
    /// first opened after others had played. It opens on the one playing now.
    func testFirstOpeningAfterTheEpisodeChanged() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-labNoEngine", "-libTrace", "-uiTestQueue=10,1", "-uiTestAdvanceTo=9"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let button = app.buttons["Now Playing"]
        XCTAssertTrue(button.waitForExistence(timeout: 20), "no Now Playing button")
        sleep(8)                                    // prebuilt on E1, then E9 starts
        button.tap()
        let playing = app.buttons["q8"].firstMatch
        XCTAssertTrue(playing.waitForExistence(timeout: 5))
        sleep(2)
        print("NOWPLAYING first opening on E9: E1 \(app.buttons["q0"].firstMatch.frame) E9 \(playing.frame) window \(app.windows.firstMatch.frame)")
        XCTAssertTrue(playing.isSelected, "E9 isn't the playing row")
        XCTAssertTrue(app.windows.firstMatch.frame.contains(CGPoint(x: playing.frame.midX, y: playing.frame.midY)) && playing.frame.minY > 60,
                      "E9 not on screen on the first opening (the list was left on E1)")
    }
}
