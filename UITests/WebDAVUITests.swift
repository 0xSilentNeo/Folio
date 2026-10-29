import XCTest

/// The WebDAV browser against the lab server (`-labDAV`, a canned PROPFIND
/// answer). Prints the row order ("DAVORDER …") and every menu item's state
/// ("DAVMENU …": type, label, enabled, value) so the run's test.log shows
/// what is really disabled and what only looks it.
final class WebDAVUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func openFolder() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-labDAV", "-noSplash"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let tab = app.tabBars.buttons["Network"].exists ? app.tabBars.buttons["Network"] : app.buttons["Network"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "no Network tab")
        tab.tap()
        let server = app.staticTexts["Lab DAV"].firstMatch
        XCTAssertTrue(server.waitForExistence(timeout: 10), "lab server not listed")
        server.tap()
        XCTAssertTrue(row(app, "Lab Show - Episode 1.mkv").waitForExistence(timeout: 10), "folder listing not shown")
        sleep(1)
        return app
    }

    private func row(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "dav:" + name).firstMatch
    }

    /// Row names top to bottom.
    @discardableResult
    private func order(_ app: XCUIApplication, _ label: String) -> [String] {
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'dav:'")).allElementsBoundByIndex
        var seen = Set<String>()
        let names = rows.filter { $0.exists && $0.frame.height > 0 }
            .sorted { $0.frame.minY < $1.frame.minY }
            .map { String($0.identifier.dropFirst(4)) }
            .filter { seen.insert($0).inserted }
        print("DAVORDER \(label): \(names.joined(separator: " | "))")
        return names
    }

    /// Every element of an open menu: type, label, enabled, value.
    private func dumpMenu(_ app: XCUIApplication, _ label: String) {
        let items = app.collectionViews.descendants(matching: .any).allElementsBoundByIndex
            .filter { $0.exists && !$0.label.isEmpty && ($0.elementType == .button || $0.elementType == .switch || $0.elementType == .cell) }
        for e in items {
            print("DAVMENU \(label): type=\(e.elementType.rawValue) label='\(e.label)' enabled=\(e.isEnabled) selected=\(e.isSelected) value='\(e.value.map { "\($0)" } ?? "")'")
        }
        if items.isEmpty { print("DAVMENU \(label): nothing found; tree:\n\(app.debugDescription)") }
    }

    func test1MenuAndOrder() throws {
        let app = openFolder()
        order(app, "as opened")
        let menu = app.descendants(matching: .any).matching(identifier: "davSortMenu").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "no sort menu button")
        menu.tap()
        sleep(1)
        dumpMenu(app, "sort menu")
        // Does "Clean titles" act when tapped? (A row's label changes with it.)
        let clean = app.collectionViews.descendants(matching: .any).matching(NSPredicate(format: "label == 'Clean titles'")).firstMatch
        if clean.exists {
            let before = clean.value.map { "\($0)" } ?? ""
            clean.tap()
            sleep(1)
            menu.tap(); sleep(1)
            let again = app.collectionViews.descendants(matching: .any).matching(NSPredicate(format: "label == 'Clean titles'")).firstMatch
            print("DAVMENU clean titles tap: before='\(before)' after='\(again.value.map { "\($0)" } ?? "")' selected=\(again.isSelected)")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()   // close the menu
            sleep(1)
        }
    }
}
