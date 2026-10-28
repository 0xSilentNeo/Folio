import XCTest

/// Discover → Search: results as you type, recent searches, offline.
/// The IMDb cache is seeded (`-labDiscover`), so no network is needed.
final class SearchUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func openSearch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-labDiscover", "-noSplash"] + extra
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let tab = app.tabBars.buttons["Discover"].exists ? app.tabBars.buttons["Discover"] : app.buttons["Discover"]
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "Discover tab not found")
        tab.tap()
        let glass = app.buttons["Search"].firstMatch
        XCTAssertTrue(glass.waitForExistence(timeout: 10), "search button not found")
        glass.tap()
        return app
    }

    func test1LiveSearchAndHistory() throws {
        let app = openSearch()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "search field not found")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "keyboard didn't come up")
        print("SEARCH keyboard up: \(app.keyboards.count > 0)")

        // As you type: no Search key.
        field.typeText("lab")
        let t0 = Date()
        let movie = app.staticTexts["Lab Movie"].firstMatch
        XCTAssertTrue(movie.waitForExistence(timeout: 5), "no live results for \"lab\"")
        print("SEARCH live results after \(Int(Date().timeIntervalSince(t0) * 1000)) ms (no Search pressed)")
        XCTAssertTrue(app.staticTexts["Lab Series"].exists, "Lab Series missing from the results")

        // First tap with the keyboard up opens the title.
        XCTAssertTrue(app.keyboards.count > 0, "keyboard went away before the tap")
        movie.tap()
        let opened = app.descendants(matching: .any)["heroPlay"].waitForExistence(timeout: 8)
        print("SEARCH first tap with the keyboard up opened the title: \(opened)")
        XCTAssertTrue(opened, "the first tap on a result didn't open it")
        sleep(1)
        let back = app.navigationBars.buttons.firstMatch
        if back.exists { back.tap() } else { app.buttons["Back"].firstMatch.tap() }
        sleep(2)

        // Opening a result kept the search: it's in Recent once the field is empty.
        let clear = app.searchFields.firstMatch.buttons.firstMatch
        if clear.exists { clear.tap() } else {
            app.searchFields.firstMatch.tap()
            app.searchFields.firstMatch.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5))
        }
        let recent = app.buttons["Recent search, lab"].firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 5), "\"lab\" not in recent searches after opening a result")
        print("SEARCH recent after opening a result: \(recent.exists)")

        // Search key: kept, no results state.
        app.searchFields.firstMatch.typeText("labx\n")
        XCTAssertTrue(app.staticTexts["No titles match “labx”."].waitForExistence(timeout: 5), "no-results state missing")
        print("SEARCH no-results state shown")
        let clear2 = app.searchFields.firstMatch.buttons.firstMatch
        if clear2.exists { clear2.tap() }
        let labx = app.buttons["Recent search, labx"].firstMatch
        XCTAssertTrue(labx.waitForExistence(timeout: 5), "\"labx\" not kept after Search")
        // Newest first.
        if labx.exists, recent.exists { XCTAssertLessThan(labx.frame.minY, recent.frame.minY, "newest search isn't on top") }

        // Swipe to delete one.
        labx.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 3), "no Delete on swipe")
        delete.tap()
        sleep(1)
        XCTAssertFalse(app.buttons["Recent search, labx"].exists, "deleted search still there")
        print("SEARCH swipe to delete: \(!app.buttons["Recent search, labx"].exists)")

        // Clear all, after confirming.
        app.buttons["Clear recent searches"].firstMatch.tap()
        let confirm = app.buttons["Clear"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "no confirmation for Clear")
        confirm.tap()
        sleep(1)
        XCTAssertFalse(app.buttons["Recent search, lab"].exists, "Clear left a search")
        print("SEARCH clear all: \(!app.buttons["Recent search, lab"].exists)")

        // History survives a relaunch (file, not memory).
        app.searchFields.firstMatch.typeText("lab movie\n")
        sleep(2)
        app.terminate()
        let again = openSearch()
        if again.searchFields.firstMatch.buttons.firstMatch.exists { again.searchFields.firstMatch.buttons.firstMatch.tap() }
        let kept = again.buttons["Recent search, lab movie"].firstMatch.waitForExistence(timeout: 5)
        print("SEARCH history after relaunch: \(kept)")
        XCTAssertTrue(kept, "history lost on relaunch")
    }

    func test2ScrollDismissesKeyboard() throws {
        let app = openSearch()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText("lab")
        XCTAssertTrue(app.staticTexts["Lab Movie"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.count > 0)
        app.staticTexts["Lab Series"].firstMatch.swipeUp()
        sleep(1)
        print("SEARCH keyboard after scrolling: \(app.keyboards.count > 0 ? "still up" : "dismissed")")
        XCTAssertEqual(app.keyboards.count, 0, "scrolling the results didn't dismiss the keyboard")
    }

    func test3Offline() throws {
        let app = openSearch(["-labSearchOffline"])
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText("dune")
        let offline = app.staticTexts["You're offline."].firstMatch.waitForExistence(timeout: 5)
        print("SEARCH offline state: \(offline), retry button: \(app.buttons["Try Again"].exists)")
        XCTAssertTrue(offline, "offline state not shown")
        XCTAssertTrue(app.buttons["Try Again"].exists, "no Try Again")
        app.buttons["Try Again"].tap()
        XCTAssertTrue(app.staticTexts["You're offline."].firstMatch.waitForExistence(timeout: 5), "retry lost the offline state")
        XCTAssertEqual(app.state, .runningForeground)
    }
}
