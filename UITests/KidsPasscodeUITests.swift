import XCTest

/// The kids passcode (1.22.2): chosen the first time, then kept. Turning the
/// profile on again asks for nothing; turning it off asks for the same one.
/// Screenshots go to $SHOTS_DIR when it's set.
final class KidsPasscodeUITests: XCTestCase {
    /// With $SHOTS_DIR: a file saying the screen is ready, then 4 s to take
    /// it from outside (this Mac's simulator gives the test black shots).
    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"] else { return }
        try? Data().write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".ready"))
        sleep(4)
    }

    private func type(_ code: String, in app: XCUIApplication) {
        for d in code { app.buttons["pin\(d)"].tap() }
    }

    func test1ChosenOnceThenKept() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestLibrary", "-labNoEngine", "-noSplash", "-labKidsReset", "-appearance", "dark"]
        app.launch()
        app.buttons["Settings"].firstMatch.tap()
        app.staticTexts["Kids Profile"].firstMatch.tap()

        // The first time: a new passcode, twice.
        app.buttons["kidsTurnOn"].tap()
        XCTAssertTrue(app.staticTexts["Enter New Passcode"].waitForExistence(timeout: 5))
        shot("kids-1-new-passcode")
        type("2580", in: app)
        XCTAssertTrue(app.staticTexts["Re-enter New Passcode"].waitForExistence(timeout: 3))
        type("2580", in: app)
        XCTAssertTrue(app.buttons["kidsTurnOff"].waitForExistence(timeout: 5), "the profile is on")

        // Off: the same passcode.
        app.buttons["kidsTurnOff"].tap()
        XCTAssertTrue(app.staticTexts["Enter Passcode"].waitForExistence(timeout: 5))
        shot("kids-2-enter-passcode")
        type("2580", in: app)
        XCTAssertTrue(app.buttons["kidsTurnOn"].waitForExistence(timeout: 5), "the profile is off")

        // On again: no passcode screen this time.
        app.buttons["kidsTurnOn"].tap()
        XCTAssertTrue(app.buttons["kidsTurnOff"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Enter Passcode"].exists || app.staticTexts["Enter New Passcode"].exists, "turning on again asked for a passcode")
        shot("kids-3-on-again")

        // And off again with it, so the next run starts clean.
        app.buttons["kidsTurnOff"].tap()
        XCTAssertTrue(app.staticTexts["Enter Passcode"].waitForExistence(timeout: 5))
        type("2580", in: app)
        XCTAssertTrue(app.buttons["kidsTurnOn"].waitForExistence(timeout: 5))
    }

    /// 1.26.1: going to the background with the profile on closes Settings and
    /// the page opened from it; turning the profile on doesn't (test1).
    func test2BackgroundClosesSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestLibrary", "-labNoEngine", "-noSplash", "-labKidsReset", "-appearance", "dark"]
        app.launch()
        app.buttons["Settings"].firstMatch.tap()
        app.staticTexts["Kids Profile"].firstMatch.tap()
        app.buttons["kidsTurnOn"].tap()
        XCTAssertTrue(app.staticTexts["Enter New Passcode"].waitForExistence(timeout: 5))
        type("2580", in: app)
        XCTAssertTrue(app.staticTexts["Re-enter New Passcode"].waitForExistence(timeout: 3))
        type("2580", in: app)
        XCTAssertTrue(app.buttons["kidsTurnOff"].waitForExistence(timeout: 5), "turning on closed the page")

        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        XCTAssertTrue(app.buttons["Settings"].firstMatch.waitForExistence(timeout: 5), "not back on Home")
        XCTAssertFalse(app.buttons["kidsTurnOff"].exists, "the Kids Profile page stayed open after the background")

        // The next test starts with the profile off and no passcode.
        app.terminate()
        app.launchArguments = ["-uiTestLibrary", "-labNoEngine", "-noSplash", "-labKidsReset"]
        app.launch()
        app.terminate()
    }
}
