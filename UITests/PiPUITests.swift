import XCTest

/// Picture in Picture in the simulator, with the PiP trace on: into PiP,
/// to the Home Screen, back to the app. For the event order and timing in
/// the trace (and the snapshots iOS keeps), not for smoothness — that's
/// only judged on a phone.
final class PiPUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-noSplash", "-pipTrace", "YES", "-pipEnabled", "YES", "-pipReturnOnOpen", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 30), "player didn't open")
        sleep(5)                                            // playing, controls up (UI test keeps them)
        return app
    }

    /// The PiP button, then Home, then back to the app.
    func test1ButtonHomeAndBack() throws {
        let app = launch()
        let pip = app.buttons["Picture in Picture"].firstMatch
        XCTAssertTrue(pip.waitForExistence(timeout: 10), "no PiP button")
        print("PIPTEST tap PiP \(Date())")
        pip.tap()
        sleep(3)
        print("PIPTEST home \(Date())")
        XCUIDevice.shared.press(.home)
        sleep(5)
        print("PIPTEST back to the app \(Date())")
        app.activate()
        sleep(6)
        print("PIPTEST app state \(app.state.rawValue), player \(app.buttons["Close player"].exists)")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Straight to Home while playing (PiP starts by itself), then back.
    func test2AutoPiPHomeAndBack() throws {
        let app = launch()
        print("PIPTEST home while playing \(Date())")
        XCUIDevice.shared.press(.home)
        sleep(5)
        print("PIPTEST back to the app \(Date())")
        app.activate()
        sleep(6)
        print("PIPTEST app state \(app.state.rawValue), player \(app.buttons["Close player"].exists)")
        XCTAssertEqual(app.state, .runningForeground)
    }
}
