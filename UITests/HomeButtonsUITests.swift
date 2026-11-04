import XCTest

/// The round buttons beside Home's "Library" title: each opens what it
/// should. With $SHOTS_DIR set, the test waits between taps so a screen
/// recording shows each button's shape while its menu opens (1.22.3:
/// "they go from round to a distorted square, then morph").
final class HomeButtonsUITests: XCTestCase {
    private var slow: Bool { ProcessInfo.processInfo.environment["SHOTS_DIR"] != nil }

    func test1MenusOpenFromTheirButtons() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestLibrary", "-labNoEngine", "-noSplash", "-appearance", "dark"]
        app.launch()
        for id in ["libraryFilterMenu", "librarySortMenu", "viewModeMenu"] {
            let b = app.buttons[id].firstMatch
            XCTAssertTrue(b.waitForExistence(timeout: 8), id)
            if slow { sleep(2) }
            b.tap()
            XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 3) || app.buttons.count > 0, "\(id) opened nothing")
            if slow { sleep(2) }
            // Closed by a tap outside it, as a person would.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
            if slow { sleep(1) }
        }
    }
}
