import XCTest

/// 1.28.8: Settings' search is the system's field (iOS 26: in the bottom
/// bar, with the tab bar out of its way). Typing finds a setting, a sub-page
/// opens, and the tab bar is back on Home.
final class SettingsSearchUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testSystemSearchFindsASetting() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestLibrary", "-labNoEngine", "-noSplash"]
        app.launch()
        let gear = app.buttons["Settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 20), "no Settings button")
        gear.tap()
        XCTAssertTrue(app.buttons["General"].firstMatch.waitForExistence(timeout: 8) || app.staticTexts["General"].firstMatch.exists, "Settings didn't open")

        let field = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields["settingsSearch"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no search field in Settings")
        print("SETTINGSSEARCH field: \(field.elementType == .searchField ? "system search field" : "row") at \(field.frame)")
        field.tap()
        field.typeText("subtitle")
        let results = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'Results' OR label ENDSWITH 'Result' OR label ENDSWITH 'RESULTS'")).firstMatch
        XCTAssertTrue(results.waitForExistence(timeout: 5), "typing found nothing")
        print("SETTINGSSEARCH results header: \(results.label)")
        XCTAssertFalse(app.staticTexts["General"].exists, "the pages still show under the results")
    }

    func testTabBarIsBackOnHome() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestLibrary", "-labNoEngine", "-noSplash"]
        app.launch()
        let gear = app.buttons["Settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 20))
        gear.tap()
        XCTAssertTrue(app.staticTexts["General"].firstMatch.waitForExistence(timeout: 8))
        app.staticTexts["General"].firstMatch.tap()
        sleep(2)
        app.buttons["Back"].firstMatch.tap()
        sleep(1)
        XCTAssertTrue(app.staticTexts["General"].firstMatch.waitForExistence(timeout: 5), "didn't come back to Settings")
        app.buttons["Back"].firstMatch.tap()
        let discover = app.buttons["Discover"].firstMatch
        XCTAssertTrue(discover.waitForExistence(timeout: 5), "the tab bar didn't come back on Home")
        XCTAssertTrue(discover.isHittable, "the tab bar is there but can't be tapped")
    }
}
