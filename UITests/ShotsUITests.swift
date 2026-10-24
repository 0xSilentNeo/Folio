import XCTest

/// Screenshot tour for checking Light and Dark appearance (CI workflow
/// "Screenshots"). The app seeds its own content (`-shots`: a series and a
/// film with one dark and one very bright picture, Continue Watching, the
/// Discover cache), so no network is needed. The simulator itself is set to
/// Dark by the workflow: the Light run therefore also checks that the app's
/// own setting wins over the system's.
///
/// Every screen is saved as `<mode>-<nn>-<name>.png` (an attachment, and in
/// $SHOTS_DIR when set). Launch times are printed as `LAUNCH <mode> <epoch>`
/// so frames of the launch animation can be cut from the screen recording.
final class ShotsUITests: XCTestCase {
    private var mode = ""
    private var n = 0

    override func setUp() { continueAfterFailure = true }

    func test1Light() { tour("light") }
    func test2Dark() { tour("dark") }
    func test3Automatic() { tour("system", short: true) }
    func test4PlayerStaysDark() {
        mode = "light"; n = 90
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-labNoEngine", "-appearance", "light", "-noSplash"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 25), "player controls not found")
        sleep(2)
        shot("player")
        app.buttons["Tracks"].tap(); sleep(2)
        shot("player-tracks")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap(); sleep(1)
        XCUIDevice.shared.orientation = .portrait
    }

    private func tour(_ m: String, short: Bool = false) {
        mode = m; n = 0
        let app = XCUIApplication()
        app.launchArguments = ["-shots", "-appearance", m]
        print(String(format: "LAUNCH %@ %.3f", m, Date().timeIntervalSince1970))
        app.launch()
        XCUIDevice.shared.orientation = .portrait

        // Home
        guard let showTile = libraryTile(app, "Lab Show") else { XCTFail("library tile not found"); return }
        sleep(2)
        shot("home")

        // Title page (zooms out of the poster; a burst while it moves).
        showTile.tap()
        burst("title-zoom", count: 3)
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 8), "title page did not open")
        sleep(2)
        shot("title")
        if short { return }
        app.swipeUp(); sleep(1)
        shot("title-episodes")
        app.swipeUp(); sleep(1)
        shot("title-cast")
        back(app)

        if let movie = libraryTile(app, "Bright Movie") {
            movie.tap()
            XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 8), "film page did not open")
            sleep(2)
            shot("title-bright")
            back(app)
        }

        app.swipeUp(); sleep(1)
        shot("home-library")
        app.swipeDown(); app.swipeDown(); sleep(1)

        // Add menu and the Open URL sheet.
        app.buttons["Add"].tap(); sleep(1)
        shot("add-menu")
        let openURL = app.buttons["Open URL"]
        if openURL.waitForExistence(timeout: 3) {
            openURL.tap(); sleep(2)
            shot("open-url")
            if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
            sleep(1)
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        }

        // Settings
        app.buttons["Settings"].tap(); sleep(2)
        shot("settings")
        for page in ["General", "Playback", "Library"] {
            let row = app.staticTexts[page].firstMatch
            guard row.waitForExistence(timeout: 4) else { continue }
            row.tap(); sleep(2)
            shot("settings-" + page.lowercased())
            back(app)
        }
        back(app)

        // Discover
        tab(app, "Discover").tap()
        XCTAssertTrue(app.staticTexts["Lab Movie"].waitForExistence(timeout: 15), "Discover grid empty")
        sleep(2)
        shot("discover")
        app.staticTexts["Lab Series"].firstMatch.tap()
        burst("discover-zoom", count: 3)
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 8), "Discover title page did not open")
        sleep(3)
        shot("discover-title")
        app.swipeUp(); sleep(1)
        shot("discover-title-episodes")
        back(app)
        app.staticTexts["Lab Movie"].firstMatch.tap()
        if app.buttons["Back"].waitForExistence(timeout: 8) { sleep(3); shot("discover-title-bright"); back(app) }
        if app.buttons["Search"].exists {
            app.buttons["Search"].tap(); sleep(2)
            shot("discover-search")
            back(app)
        }

        // Network
        tab(app, "Network").tap(); sleep(2)
        shot("network")
        tab(app, "Home").tap(); sleep(1)
    }

    // MARK: Helpers

    /// The library grid's tile (not the Continue Watching card, which plays).
    private func libraryTile(_ app: XCUIApplication, _ name: String) -> XCUIElement? {
        let q = app.staticTexts.matching(NSPredicate(format: "label == %@", name))
        let end = Date().addingTimeInterval(25)
        while Date() < end {
            let all = q.allElementsBoundByIndex.filter { $0.exists && $0.frame.height > 0 }
            // Tiles are below the 16:9 Continue Watching card: take the lowest on screen.
            if let tile = all.filter({ $0.isHittable }).max(by: { $0.frame.minY < $1.frame.minY }), all.count >= (name == "Lab Show" ? 2 : 1) { return tile }
            usleep(300_000)
        }
        return q.allElementsBoundByIndex.last
    }

    private func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.tabBars.buttons[name].exists ? app.tabBars.buttons[name] : app.buttons[name].firstMatch
    }

    private func back(_ app: XCUIApplication) {
        let b = app.navigationBars.buttons.element(boundBy: 0)
        if app.buttons["Back"].exists { app.buttons["Back"].tap() } else if b.exists { b.tap() }
        sleep(1)
    }

    private func burst(_ name: String, count: Int) {
        for i in 0..<count { shot("\(name)-\(i)", bump: false) }
        n += 1
    }

    private func shot(_ name: String, bump: Bool = true) {
        let s = XCUIScreen.main.screenshot()
        let file = String(format: "%@-%02d-%@", mode, n, name)
        if bump { n += 1 }
        let a = XCTAttachment(screenshot: s)
        a.name = file
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"] {
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(file + ".png"))
        }
        print("SHOT \(file)")
    }
}
