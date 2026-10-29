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

    /// Every control's state and the order through each sort and direction.
    func test1MenusAndOrder() throws {
        let app = openFolder()
        order(app, "as opened")
        let sortMenu = app.descendants(matching: .any).matching(identifier: "davSortMenu").firstMatch
        let direction = app.descendants(matching: .any).matching(identifier: "davSortDirection").firstMatch
        let more = app.descendants(matching: .any).matching(identifier: "davMoreMenu").firstMatch
        for (name, e) in [("sort menu", sortMenu), ("direction", direction), ("more menu", more)] {
            XCTAssertTrue(e.waitForExistence(timeout: 5), "no \(name) button")
            print("DAVBUTTON \(name): enabled=\(e.isEnabled) label='\(e.label)'")
        }
        // Each sort as picked (it starts in its own direction), then reversed.
        for sort in ["Name", "Recently Added", "Size"] {
            sortMenu.tap(); sleep(1)
            dumpMenu(app, "sort menu (before picking \(sort))")
            let choice = app.collectionViews.buttons[sort].firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 3), "\(sort) not in the sort menu")
            choice.tap(); sleep(1)
            order(app, "\(sort), \(direction.label)")
            direction.tap(); sleep(1)
            order(app, "\(sort), \(direction.label)")
        }
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
        // Relaunch: the last choice (Size, reversed) is still there.
        app.terminate()
        let again = openFolder()
        order(again, "after relaunch")
        let dir2 = again.descendants(matching: .any).matching(identifier: "davSortDirection").firstMatch
        print("DAVBUTTON after relaunch: direction='\(dir2.label)' sort='\(again.descendants(matching: .any).matching(identifier: "davSortMenu").firstMatch.label)'")
    }
}
