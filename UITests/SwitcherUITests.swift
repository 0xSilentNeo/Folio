import XCTest

/// What iOS shows for Folio in the app switcher and on the way back into the
/// app, with the player up (PiP trace on). The simulator can't do PiP, but
/// the switcher card and the zoom back in are iOS's own snapshot handling,
/// the same with or without PiP. The run's screen recording is the result;
/// each step is printed ("SWITCHER …") to find it there.
final class SwitcherUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-noSplash", "-pipTrace", "YES", "-pipEnabled", "YES", "-pipReturnOnOpen", "YES"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 30), "player didn't open")
        sleep(5)
        return app
    }

    private func mark(_ what: String) { print("SWITCHER \(what) \(Date().timeIntervalSince1970)") }

    /// Swipe up from the bottom edge and hold: the app switcher.
    private func openSwitcher() {
        let from = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.995))
        let to = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 1.2)
    }

    /// Player turned to landscape (the default on opening a video), phone
    /// upright: Home, the switcher, back into the app from its card.
    func test1LeftInLandscapeBackInPortrait() throws {
        let app = launch()
        mark("home")
        XCUIDevice.shared.press(.home)
        sleep(3)
        mark("switcher")
        openSwitcher()
        sleep(3)
        mark("card tap")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        sleep(4)
        if app.state != .runningForeground { mark("card tap missed; activate"); app.activate(); sleep(4) }
        mark("back \(app.state.rawValue)")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Control: the same, but the phone is turned to landscape before going
    /// back, so the app comes back the way it was left.
    func test2LeftInLandscapeBackInLandscape() throws {
        let app = launch()
        mark("home")
        XCUIDevice.shared.press(.home)
        sleep(3)
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        mark("activate in landscape")
        app.activate()
        sleep(4)
        mark("back \(app.state.rawValue)")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Control: the player stays upright (no turn to landscape on opening).
    func test3UprightPlayer() throws {
        let app = launch(["-landscapeOnOpen", "NO"])
        mark("home")
        XCUIDevice.shared.press(.home)
        sleep(3)
        mark("activate")
        app.activate()
        sleep(4)
        mark("back \(app.state.rawValue)")
        XCTAssertEqual(app.state, .runningForeground)
    }
}
