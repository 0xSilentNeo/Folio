import XCTest

/// Discover → Search: results as you type, recent searches, offline, and
/// (1.30.5) the Library and Search tabs, the hint between them, and the
/// Search tab's Shows and Movies pills. The IMDb cache is seeded
/// (`-labDiscover`), so no network is needed.
final class SearchUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    /// One of the tabs across the results' top (1.30.5): "library" or "search".
    /// The tab is kept across launches, so each test chooses the one it needs.
    @discardableResult
    private func showTab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let tab = app.buttons["searchTab:" + name].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "no \(name) tab")
        tab.tap()
        XCTAssertTrue(waitFor("isSelected == true", tab), "the \(name) tab isn't chosen")
        return tab
    }

    /// Whether the element comes to match `predicate` in time (no failure of its own).
    private func waitFor(_ predicate: String, _ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let e = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        return XCTWaiter().wait(for: [e], timeout: timeout) == .completed
    }

    private func clearField(_ app: XCUIApplication, typed count: Int) {
        let clear = app.searchFields.firstMatch.buttons.firstMatch
        if clear.exists { clear.tap() } else {
            app.searchFields.firstMatch.tap()
            app.searchFields.firstMatch.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count))
        }
    }

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

        // As you type: no Search key. IMDb's titles are under the Search tab (1.30.5).
        field.typeText("lab")
        let t0 = Date()
        showTab(app, "search")
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
        clearField(app, typed: 5)
        let recent = app.buttons["Recent search, lab"].firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 5), "\"lab\" not in recent searches after opening a result")
        print("SEARCH recent after opening a result: \(recent.exists)")

        // Search key: kept, no results state (on the Search tab, still chosen).
        app.searchFields.firstMatch.typeText("labx\n")
        XCTAssertTrue(app.staticTexts["No titles match “labx”."].waitForExistence(timeout: 5), "no-results state missing")
        print("SEARCH no-results state shown")
        let clear2 = app.searchFields.firstMatch.buttons.firstMatch
        if clear2.exists { clear2.tap() }
        let labx = app.buttons["Recent search, labx"].firstMatch
        XCTAssertTrue(labx.waitForExistence(timeout: 5), "\"labx\" not kept after Search")
        // Newest first: Recent is chips that wrap, so before it on its
        // line, or on a line above.
        if labx.exists, recent.exists {
            let sameLine = abs(labx.frame.minY - recent.frame.minY) <= 1
            XCTAssertTrue(sameLine ? labx.frame.minX < recent.frame.minX : labx.frame.minY < recent.frame.minY, "newest search isn't first")
        }

        // Long press: the chip's own menu deletes it.
        labx.press(forDuration: 1.0)
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 3), "no Delete in the chip's menu")
        delete.tap()
        sleep(1)
        XCTAssertFalse(app.buttons["Recent search, labx"].exists, "deleted search still there")
        print("SEARCH long press to delete: \(!app.buttons["Recent search, labx"].exists)")

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
        showTab(app, "search")
        XCTAssertTrue(app.staticTexts["Lab Movie"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.count > 0)
        // Dragged in the list's upper part (1.28.11): with the library's
        // results first, "Lab Series" can sit under the keyboard, and a
        // swipe that starts there lands on the keyboard.
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.34))
        from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.16)))
        sleep(1)
        print("SEARCH keyboard after scrolling: \(app.keyboards.count > 0 ? "still up" : "dismissed")")
        XCTAssertEqual(app.keyboards.count, 0, "scrolling the results didn't dismiss the keyboard")
    }

    func test3Offline() throws {
        let app = openSearch(["-labSearchOffline"])
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText("dune")
        // IMDb's state is the Search tab's (1.30.5).
        showTab(app, "search")
        let offline = app.staticTexts["You're offline."].firstMatch.waitForExistence(timeout: 5)
        print("SEARCH offline state: \(offline), retry button: \(app.buttons["Try Again"].exists)")
        XCTAssertTrue(offline, "offline state not shown")
        XCTAssertTrue(app.buttons["Try Again"].exists, "no Try Again")
        app.buttons["Try Again"].tap()
        XCTAssertTrue(app.staticTexts["You're offline."].firstMatch.waitForExistence(timeout: 5), "retry lost the offline state")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// 1.30.5: the Shows and Movies pills filter the Search tab's titles one
    /// at a time and clear on a second tap; nothing of yours matches, so the
    /// Library tab points at Search, and the tab chosen so is kept across
    /// launches; a pill is never kept (a new query starts on every title).
    func test4TabsHintAndPills() throws {
        let app = openSearch()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "keyboard didn't come up")

        // Search, no pill: every title.
        field.typeText("lab")
        showTab(app, "search")
        XCTAssertFalse(app.buttons["searchScope:all"].exists, "the old All chip is back")
        let movie = app.staticTexts["Lab Movie"].firstMatch
        let series = app.staticTexts["Lab Series"].firstMatch
        XCTAssertTrue(movie.waitForExistence(timeout: 5), "Lab Movie missing with no pill chosen")
        XCTAssertTrue(series.waitForExistence(timeout: 5), "Lab Series missing with no pill chosen")
        let shows = app.buttons["searchFilter:shows"].firstMatch
        let movies = app.buttons["searchFilter:movies"].firstMatch
        XCTAssertTrue(shows.exists && movies.exists, "no Shows and Movies pills on the Search tab")
        XCTAssertFalse(shows.isSelected || movies.isSelected, "a pill chosen before any was tapped")

        // Shows: the series only.
        shows.tap()
        XCTAssertTrue(waitFor("exists == false", movie), "Shows still lists Lab Movie")
        XCTAssertTrue(series.exists, "Shows lost Lab Series")
        XCTAssertTrue(shows.isSelected, "the Shows pill isn't chosen")
        // Movies takes over: one pill at a time.
        movies.tap()
        XCTAssertTrue(waitFor("exists == false", series), "Movies still lists Lab Series")
        XCTAssertTrue(movie.waitForExistence(timeout: 5), "Movies lost Lab Movie")
        XCTAssertTrue(movies.isSelected && !shows.isSelected, "two pills chosen at once")
        // Movies again: every title.
        movies.tap()
        XCTAssertTrue(series.waitForExistence(timeout: 5), "clearing the pill didn't bring Lab Series back")
        XCTAssertTrue(movie.exists)
        XCTAssertFalse(movies.isSelected, "the Movies pill stayed chosen")
        shows.tap()
        XCTAssertTrue(waitFor("isSelected == true", shows))

        // The pills are the Search tab's only; Library is now the tab kept.
        showTab(app, "library")
        XCTAssertTrue(waitFor("exists == false", shows), "the Shows pill under Library")

        // A new query: nothing called "lab movie" is yours, so Library points at Search.
        clearField(app, typed: 3)
        app.searchFields.firstMatch.typeText("lab movie")
        let hint = app.buttons["searchTabHint"].firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 5), "no hint to the Search tab")
        print("SEARCH hint: \(hint.label)")
        XCTAssertTrue(hint.label.contains("in Search"), "the hint doesn't point at Search: \(hint.label)")
        XCTAssertTrue(app.buttons["searchTab:library"].firstMatch.isSelected, "the hint changed the tab by itself")
        XCTAssertFalse(app.staticTexts["Lab Movie"].exists, "an IMDb title under Library")
        hint.tap()
        XCTAssertTrue(waitFor("isSelected == true", app.buttons["searchTab:search"].firstMatch), "the hint didn't open the Search tab")
        XCTAssertTrue(movie.waitForExistence(timeout: 5), "no titles under Search after the hint")
        XCTAssertTrue(shows.waitForExistence(timeout: 3))
        XCTAssertFalse(shows.isSelected, "the Shows pill was kept for a new query")
        // Shows for a text that names a film only: said so in a row.
        shows.tap()
        XCTAssertTrue(app.staticTexts["No shows match “lab movie”."].waitForExistence(timeout: 5), "no row for a pill with nothing under it")

        // Relaunched: the tab the hint chose is kept, the pill isn't.
        app.terminate()
        let again = openSearch()
        XCTAssertTrue(again.searchFields.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(again.keyboards.firstMatch.waitForExistence(timeout: 5), "keyboard didn't come up after relaunch")
        again.searchFields.firstMatch.typeText("lab")
        let tab = again.buttons["searchTab:search"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "no Search tab after relaunch")
        print("SEARCH tab after relaunch: search chosen \(tab.isSelected)")
        XCTAssertTrue(tab.isSelected, "the Search tab the hint chose wasn't kept across launches")
        let showsAgain = again.buttons["searchFilter:shows"].firstMatch
        XCTAssertTrue(showsAgain.waitForExistence(timeout: 5))
        XCTAssertFalse(showsAgain.isSelected, "the Shows pill was kept across launches")
    }
}
