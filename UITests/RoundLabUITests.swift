import XCTest

/// Reproductions for the 1.19.0 round, run in the UI lab with the screen
/// recorded and `-libTrace` on, so app.log has the zoom sources, picture
/// loads, Discover requests and the panel's opening row. Each step prints
/// "LAB <step>" with the seconds since the test started.
final class RoundLabUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private var t0 = Date()
    private func mark(_ s: String) { print(String(format: "LAB %.2f %@", Date().timeIntervalSince(t0), s)) }

    // MARK: Item 2: a title's poster after its page goes back

    private func home(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-shots", "-libTrace", "-noSplash", "-appearance", "light"] + extra
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        t0 = Date()
        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 20), "Home's library not shown")
        sleep(3)
        return app
    }

    private func openAndBack(_ app: XCUIApplication, _ label: String) {
        let title = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Lab Show'")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "no Lab Show on Home")
        mark("\(label): open")
        title.tap()
        sleep(3)
        let back = app.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "no Back button")
        mark("\(label): back")
        back.tap()
        sleep(4)
        mark("\(label): settled")
    }

    private func layout(_ app: XCUIApplication, _ name: String) {
        let menu = app.buttons["viewModeMenu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "no view menu")
        menu.tap()
        sleep(1)
        let item = app.buttons[name].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3), "\(name) not in the view menu")
        mark("layout → \(name)")
        item.tap()
        sleep(2)
    }

    func test1ZoomBackFreshLaunch() {
        let app = home()
        openAndBack(app, "thumbnails, no layout switch")
    }

    func test2ZoomBackAfterLayoutSwitch() {
        let app = home()
        layout(app, "Details")
        layout(app, "Thumbnails")
        openAndBack(app, "thumbnails after details")
        layout(app, "Details")
        openAndBack(app, "details")
        layout(app, "List")
        openAndBack(app, "list")
        layout(app, "Thumbnails")
        openAndBack(app, "thumbnails again")
    }

    // MARK: Item 8: the playlist opens on the playing episode

    private func nowPlaying(start: Int) {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-labNoEngine", "-libTrace", "-uiTestQueue=10,\(start)"]
        app.launch()
        t0 = Date()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Now Playing"].waitForExistence(timeout: 20), "no Now Playing button")
        sleep(3)
        mark("playing E\(start): open Now Playing")
        app.buttons["Now Playing"].tap()
        sleep(2)
        let window = app.windows.firstMatch.frame
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'S01E'")).allElementsBoundByIndex
            .filter { $0.exists && !$0.frame.isEmpty && window.intersects($0.frame) && $0.isHittable }
            .map { "\($0.label.prefix(6))@\(Int($0.frame.minY))" }
        mark("playing E\(start): rows on screen \(rows)")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        sleep(1)
    }

    func test3PlaylistOpensOnPlayingEpisode() {
        nowPlaying(start: 1)
        nowPlaying(start: 6)
    }

    // MARK: Item 9 and 6: a provider page

    func test4ProviderTabs() {
        let app = XCUIApplication()
        app.launchArguments = ["-libTrace", "-noSplash", "-appearance", "light"]
        app.launch()
        t0 = Date()
        XCUIDevice.shared.orientation = .portrait
        let tab = app.tabBars.buttons["Discover"].exists ? app.tabBars.buttons["Discover"] : app.buttons["Discover"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "no Discover tab")
        tab.tap()
        sleep(3)
        let prime = app.staticTexts["Prime Video"].firstMatch
        XCTAssertTrue(prime.waitForExistence(timeout: 10), "no Prime Video")
        mark("open Prime Video")
        prime.tap()
        let movies = app.segmentedControls.buttons["Movies"].firstMatch, shows = app.segmentedControls.buttons["Shows"].firstMatch
        XCTAssertTrue(movies.waitForExistence(timeout: 5), "no Movies tab")
        // Switch while the first load is still out, then back.
        usleep(300_000); mark("Movies (Shows still loading)"); movies.tap()
        usleep(500_000); mark("Shows"); shows.tap()
        sleep(8); mark("Shows after 8 s")
        movies.tap(); sleep(8); mark("Movies after 8 s")
        shows.tap(); sleep(4); mark("Shows again")
    }

    func test5ProviderHeaders() {
        let app = XCUIApplication()
        app.launchArguments = ["-libTrace", "-noSplash", "-appearance", "light"]
        app.launch()
        t0 = Date()
        XCUIDevice.shared.orientation = .portrait
        let tab = app.tabBars.buttons["Discover"].exists ? app.tabBars.buttons["Discover"] : app.buttons["Discover"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "no Discover tab")
        tab.tap()
        sleep(3)
        for name in ["Netflix", "Prime Video", "HBO Max", "Disney+", "Apple TV+", "Paramount+", "Hulu", "Peacock", "Crunchyroll"] {
            let p = app.staticTexts[name].firstMatch
            if !p.isHittable { app.scrollViews.firstMatch.swipeLeft() }
            guard p.waitForExistence(timeout: 3) else { mark("\(name) not found"); continue }
            p.tap()
            sleep(2)
            let back = app.navigationBars.buttons.firstMatch
            mark("\(name): back button \(back.frame)")
            back.tap()
            sleep(1)
        }
    }

    // MARK: Item 3: how the Files app sorts (iOS's own app)

    func test6FilesAppSort() {
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.launch()
        t0 = Date()
        sleep(4)
        if files.tabBars.buttons["Browse"].exists { files.tabBars.buttons["Browse"].tap(); sleep(2) }
        else if files.buttons["Browse"].exists { files.buttons["Browse"].tap(); sleep(2) }
        let onPhone = files.staticTexts["On My iPhone"].firstMatch
        if onPhone.waitForExistence(timeout: 5) { onPhone.tap(); sleep(2) }
        let more = files.buttons["OverflowBarButtonItem"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), "no More button")
        /// The sort items of the open menu: identifier, label, selected.
        func sortItems(_ when: String) {
            let items = files.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'DOC.sortMenuButton'")).allElementsBoundByIndex
            mark("\(when): " + items.map { "\($0.identifier) '\($0.label)'\($0.isSelected ? " selected" : "")" }.joined(separator: " | "))
        }
        func pick(_ key: String) {
            more.tap(); sleep(2)
            sortItems("menu before picking \(key)")
            let item = files.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "DOC.sortMenuButton.\(key)")).firstMatch
            guard item.exists else { mark("no \(key) item"); return }
            mark("pick \(key)")
            item.tap(); sleep(2)
        }
        for key in ["dateModified", "dateModified", "dateModified", "name", "name", "size", "size"] { pick(key) }
        more.tap(); sleep(2)
        sortItems("menu at the end")
    }
}
