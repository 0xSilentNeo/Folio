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
    /// The 13 Nov recording (1.30.3): turned on from Settings, Back asked for
    /// Face ID for the Settings already open, then Settings took no touches
    /// at all, and Home's FOLIO broke over two lines beside the kids pill.
    func test3SettingsStayUsableAfterTurningOn() {
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
        XCTAssertTrue(app.buttons["kidsTurnOff"].waitForExistence(timeout: 5))
        shot("kids-on")

        // Back to Settings: no passcode for the Settings already open.
        let back = app.buttons["Back"].firstMatch
        if back.waitForExistence(timeout: 3) { back.tap() } else { app.navigationBars.buttons.firstMatch.tap() }
        let playback = app.staticTexts["Playback"].firstMatch
        XCTAssertTrue(playback.waitForExistence(timeout: 5), "Settings' list isn't there after Back")
        XCTAssertFalse(app.staticTexts["Enter Passcode"].exists, "Back asked for the passcode")
        shot("kids-settings")

        // Settings still take touches: a page opens and closes.
        playback.tap()
        let playbackPage = app.navigationBars["Playback"].firstMatch
        let opened = playbackPage.waitForExistence(timeout: 5) || app.staticTexts["Playback"].firstMatch.waitForExistence(timeout: 1)
        XCTAssertTrue(opened, "a row in Settings didn't open")
        let back2 = app.buttons["Back"].firstMatch
        if back2.waitForExistence(timeout: 3) { back2.tap() } else { app.navigationBars.buttons.firstMatch.tap() }
        XCTAssertTrue(app.staticTexts["Kids Profile"].firstMatch.waitForExistence(timeout: 5), "not back on Settings")

        // Home: the kids button, and FOLIO on one line.
        let back3 = app.buttons["Back"].firstMatch
        if back3.waitForExistence(timeout: 3) { back3.tap() } else { app.navigationBars.buttons.firstMatch.tap() }
        XCTAssertTrue(app.buttons["kidsBadge"].waitForExistence(timeout: 5), "no kids button on Home")
        let mark = app.staticTexts["Folio"].firstMatch
        XCTAssertTrue(mark.waitForExistence(timeout: 3))
        XCTAssertLessThan(mark.frame.height, 40, "FOLIO broke over two lines: \(mark.frame)")
        shot("kids-home")

        // Settings opened again: the passcode, with no search field over it,
        // and Cancel goes back to Home.
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Enter Passcode"].waitForExistence(timeout: 5), "Settings opened without the passcode")
        let field = app.searchFields["Search Settings"].firstMatch
        XCTAssertFalse(field.exists && field.isHittable, "the search field is over the lock")
        shot("kids-settings-locked")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["kidsBadge"].waitForExistence(timeout: 5), "Cancel didn't go back to Home")

        app.terminate()
        app.launchArguments = ["-uiTestLibrary", "-labNoEngine", "-noSplash", "-labKidsReset"]
        app.launch()
        app.terminate()
    }

    /// 1.30.4: the passcode pad up on the Kids Profile page when Folio goes to
    /// the background closes before Settings does, so nothing is left over
    /// Home with no way to close it.
    func test4BackgroundClosesThePasscodePad() {
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
        XCTAssertTrue(app.buttons["kidsTurnOff"].waitForExistence(timeout: 5))

        // The pad up (Change Passcode asks for the current one), then the background.
        app.buttons["kidsChangePasscode"].tap()
        XCTAssertTrue(app.staticTexts["Enter Passcode"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()

        // Home, with no pad over it, and it still takes touches: Settings asks, Cancel comes back.
        XCTAssertTrue(app.buttons["kidsBadge"].waitForExistence(timeout: 5), "not back on Home")
        XCTAssertFalse(app.buttons["kidsTurnOff"].exists, "the Kids Profile page stayed open after the background")
        XCTAssertFalse(app.otherElements["kidsPasscode"].exists, "the passcode pad stayed up over Home")
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Enter Passcode"].waitForExistence(timeout: 5), "Settings didn't ask for the passcode")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["kidsBadge"].waitForExistence(timeout: 5), "Cancel didn't go back to Home")

        // The next test starts with the profile off and no passcode.
        app.terminate()
        app.launchArguments = ["-uiTestLibrary", "-labNoEngine", "-noSplash", "-labKidsReset"]
        app.launch()
        app.terminate()
    }

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
