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

    /// The sort menu's items: label (title and the order under the checked one), selected.
    private func sortItems(_ app: XCUIApplication, _ when: String) {
        let items = app.collectionViews.descendants(matching: .any).allElementsBoundByIndex
            .filter { e in e.exists && ["Recently Added", "Name", "Size"].contains(where: { e.label.hasPrefix($0) }) }
        print("DAVSORT \(when): " + items.map { "\($0.label)\($0.isSelected || "\($0.value ?? "")" == "1" ? " [checked]" : "") enabled=\($0.isEnabled)" }.joined(separator: " | "))
    }

    /// Every control's state and the order through each sort, picked once
    /// (its own direction) and again (turned round). There's no separate
    /// direction button any more.
    func test1MenusAndOrder() throws {
        let app = openFolder()
        order(app, "as opened")
        let sortMenu = app.descendants(matching: .any).matching(identifier: "librarySortMenu").firstMatch
        let more = app.descendants(matching: .any).matching(identifier: "davMoreMenu").firstMatch
        for (name, e) in [("sort menu", sortMenu), ("more menu", more)] {
            XCTAssertTrue(e.waitForExistence(timeout: 5), "no \(name) button")
            print("DAVBUTTON \(name): enabled=\(e.isEnabled) label='\(e.label)'")
        }
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "davSortDirection").firstMatch.exists, "the separate direction button is back")
        func pick(_ sort: String) {
            sortMenu.tap(); sleep(1)
            sortItems(app, "before picking \(sort)")
            let choice = app.collectionViews.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", sort)).firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 3), "\(sort) not in the sort menu")
            choice.tap(); sleep(1)
        }
        for sort in ["Name", "Recently Added", "Size"] {
            pick(sort)
            order(app, "\(sort) picked: \(sortMenu.label)")
            pick(sort)
            order(app, "\(sort) picked again: \(sortMenu.label)")
        }
        sortMenu.tap(); sleep(1)
        sortItems(app, "at the end")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap(); sleep(1)
        // The More menu's toggles act.
        more.tap(); sleep(1)
        dumpMenu(app, "more menu")
        let onlyMedia = app.collectionViews.descendants(matching: .any).matching(NSPredicate(format: "label == 'Only media files'")).firstMatch
        XCTAssertTrue(onlyMedia.waitForExistence(timeout: 3), "no Only media files")
        XCTAssertTrue(onlyMedia.isEnabled, "Only media files is disabled")
        onlyMedia.tap(); sleep(1)
        let shown = order(app, "only media files on")
        XCTAssertFalse(shown.contains("notes.txt"), "Only media files did nothing")
        more.tap(); sleep(1)
        app.collectionViews.descendants(matching: .any).matching(NSPredicate(format: "label == 'Only media files'")).firstMatch.tap()
        sleep(1)
        // Relaunch: the last choice (Size, turned round) is still there.
        app.terminate()
        let again = openFolder()
        order(again, "after relaunch")
        print("DAVBUTTON after relaunch: sort='\(again.descendants(matching: .any).matching(identifier: "librarySortMenu").firstMatch.label)'")
    }
}
