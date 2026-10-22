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

    /// Lock button next to PiP: locks the controls, Unlock restores them.
    func test5LockButton() throws {
        let app = launchPlayer()
        let lock = app.buttons["Lock controls"]
        XCTAssertTrue(lock.waitForExistence(timeout: 5), "lock button missing")
        lock.tap()
        XCTAssertTrue(app.buttons["Unlock"].waitForExistence(timeout: 4), "Unlock did not appear")
        XCTAssertFalse(app.buttons["Settings"].exists, "controls still shown while locked")
        sleep(1)
        app.buttons["Unlock"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 4), "controls did not come back")
        sleep(1)
    }

    /// The tap sequence from the freeze log, replayed at its real timing.
    /// Afterwards the screen must match the last tap (Settings open) and the
    /// player must still respond: outside tap closes, Tracks opens and closes.
    func test6RapidSwitchReplay() throws { try replay([]) }

    /// Same replay without the settle delay between transitions (comparison).
    func test7ReplayNoSettle() throws { try replay(["-panelNoSettle"]) }

    private func replay(_ extra: [String]) throws {
        let app = launchPlayer(["-panelStress"] + extra)
        sleep(22)                                                 // replay: 3.5 s after landscape settles, lasts 11.6 s
        XCTAssertTrue(app.staticTexts["Playback"].waitForExistence(timeout: 4), "Settings (last tap) is not showing")
        XCTAssertFalse(app.staticTexts["NOW PLAYING"].exists, "an orphaned Now Playing panel is on screen")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap(); sleep(2)
        XCTAssertFalse(app.staticTexts["Playback"].exists, "panel did not close after the replay (stuck)")
        app.buttons["Tracks"].tap()
        XCTAssertTrue(app.staticTexts["Audio"].waitForExistence(timeout: 4), "player unresponsive after the replay")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap(); sleep(2)
        XCTAssertFalse(app.staticTexts["Audio"].exists, "Tracks did not close")
    }
}
