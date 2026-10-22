import XCTest

/// Drives the player with real touches in the CI simulator while the screen
/// is recorded: open each panel from its toolbar button, switch panels, drag
/// and tap the Now Playing segmented control, close by tapping outside.
final class PanelUITests: XCTestCase {
    func test0PanelsAndTabs() throws {
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

    private func launchPlayer(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-labNoEngine"] + extra
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 20), "toolbar button not found")
        sleep(2)
        return app
    }

    /// Long press on the player's Settings button (the recording shows whether
    /// the glass lights up and grows while held, like Outplayer's).
    func test1PressPlayerToolbar() throws {
        let app = launchPlayer()
        app.buttons["Settings"].press(forDuration: 1.2)
        XCTAssertTrue(app.staticTexts["Playback"].waitForExistence(timeout: 4), "Settings did not open after a long press")
        sleep(2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap(); sleep(2)
    }

    /// Same press on a plain UIKit toolbar (no SwiftUI around it).
    func test2PressUIKitToolbar() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-popLab", "-popLabStatic"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let b = app.buttons["LabSettings"]
        XCTAssertTrue(b.waitForExistence(timeout: 20), "lab toolbar not found")
        sleep(2)
        b.press(forDuration: 1.2)
        sleep(3)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap(); sleep(2)
    }

    /// Player with screen-edge deferral on (the 1.9.11 setting), for comparison.
    func test3PressWithEdgeDeferral() throws {
        let app = launchPlayer(["-deferEdges"])
        app.buttons["Settings"].press(forDuration: 1.2)
        XCTAssertTrue(app.staticTexts["Playback"].waitForExistence(timeout: 4), "Settings did not open (deferral on)")
        sleep(2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap(); sleep(2)
    }

    /// Ten quick open/close cycles: every tap must open its panel.
    func test4RapidTaps() throws {
        let app = launchPlayer()
        let names: [(String, String)] = [("Tracks", "Audio"), ("Settings", "Playback"), ("Now Playing", "NOW PLAYING")]
        var ok = 0
        for i in 0..<10 {
            let (button, marker) = names[i % 3]
            app.buttons[button].tap()
            if app.staticTexts[marker].waitForExistence(timeout: 2) { ok += 1 } else { print("RAPID miss at \(i) (\(button))") }
            usleep(400_000)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap()
            usleep(700_000)
        }
        print("RAPID opened \(ok)/10")
        XCTAssertEqual(ok, 10, "some taps did not open their panel")
    }
}
