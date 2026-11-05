import XCTest

/// The search tab (1.22.4): the button beside the tab bar opens into the
/// field, and your library's titles come first. With $SHOTS_DIR set, a
/// file marks each screen and the test holds it for 4 s so the screen can
/// be taken from outside (this Mac's simulator gives the test black shots).
final class SearchTabUITests: XCTestCase {
    private func hold(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"] else { return }
        try? Data().write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".ready"))
        sleep(4)
    }

    func test1LibraryTitlesFirst() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestLibrary", "-labNoEngine", "-noSplash", "-appearance", "dark"]
        app.launch()
        let search = app.buttons["Search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), "no search button")
        hold("search-0-home")
        search.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "keyboard didn't come up")
        field.typeText("lab show")
        let row = app.buttons["searchLibrary:Lab Show"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the library's Lab Show isn't in the results")
        XCTAssertTrue(app.staticTexts["In your library"].exists)
        hold("search-1-results")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["heroPlay"].waitForExistence(timeout: 8), "the title page didn't open")
    }

    /// "Zoom between tabs" on: switching still works (the zoom itself is
    /// checked in a screen recording).
    func test2TabZoomSwitches() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestLibrary", "-labNoEngine", "-noSplash", "-appearance", "dark", "-tabZoom", "YES"]
        app.launch()
        let discover = app.buttons["Discover"].firstMatch
        XCTAssertTrue(discover.waitForExistence(timeout: 10))
        sleep(2)
        discover.tap()
        sleep(2)
        app.buttons["Home"].firstMatch.tap()
        sleep(2)
        XCTAssertTrue(app.buttons["Discover"].firstMatch.exists)
    }

    /// 1.23.0 (5 Nov: "remove the search bar at the top of the Network
    /// page"): Network shows no search field of its own, on iOS 27 too, and
    /// the search page opens on its intro.
    func test3NetworkHasNoSearchBar() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestLibrary", "-labNoEngine", "-noSplash", "-appearance", "dark"]
        app.launch()
        let network = app.buttons["Network"].firstMatch
        XCTAssertTrue(network.waitForExistence(timeout: 10), "no Network tab")
        network.tap()
        sleep(2)
        hold("search-2-network")
        XCTAssertEqual(app.searchFields.count, 0, "a search field on the Network page")
        // A search bar can hide under the title until the page is pulled down.
        app.swipeDown()
        sleep(2)
        hold("search-3-network-pulled")
        XCTAssertEqual(app.searchFields.count, 0, "a search field after pulling the Network page down")
        app.buttons["Search"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["librarySearchIntro"].waitForExistence(timeout: 5), "the search page's intro didn't show")
        hold("search-4-intro")
    }
}
