import XCTest

/// Drives the player with real touches in the CI simulator while the screen
/// is recorded: open each panel from its toolbar button, switch panels, drag
/// and tap the Now Playing segmented control, close by tapping outside.
final class PanelUITests: XCTestCase {
    func testPanelsAndTabs() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-labNoEngine"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft

        let tracks = app.buttons["Tracks"]
        XCTAssertTrue(tracks.waitForExistence(timeout: 20), "toolbar button not found")
        sleep(2)
        tracks.tap()                                                         // open
        XCTAssertTrue(app.staticTexts["Audio"].waitForExistence(timeout: 4), "Tracks panel did not open")
        sleep(2)
        XCTAssertTrue(app.buttons["Settings"].isHittable, "Settings button covered by the panel")
        app.buttons["Settings"].tap()                                        // switch
        XCTAssertTrue(app.staticTexts["Playback"].waitForExistence(timeout: 4), "Settings panel did not open")
        sleep(2)
        XCTAssertTrue(app.buttons["Now Playing"].isHittable, "Now Playing button covered by the panel")
        app.buttons["Now Playing"].tap()                                     // switch
        XCTAssertTrue(app.staticTexts["NOW PLAYING"].waitForExistence(timeout: 4), "Now Playing panel did not open")
        sleep(2)

        let seg = app.segmentedControls.firstMatch
        XCTAssertTrue(seg.waitForExistence(timeout: 5), "segmented control not found")
        let first = seg.buttons.element(boundBy: 0), last = seg.buttons.element(boundBy: 2), mid = seg.buttons.element(boundBy: 1)
        first.press(forDuration: 0.4, thenDragTo: last); sleep(2)  // drag the thumb across
        mid.tap(); sleep(2)                                        // tap
        first.tap(); sleep(2)

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap(); sleep(2)   // tap outside → close
        XCTAssertFalse(app.staticTexts["NOW PLAYING"].exists, "panel did not close on outside tap")
        tracks.tap(); sleep(2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap(); sleep(2)
    }
}
