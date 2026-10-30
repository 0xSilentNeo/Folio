import XCTest

/// Home's Library layouts with different numbers of entries, before and after
/// turning the phone, in Thumbnails, List and Details (31 Oct screenshot: the
/// "Mixed" folder drawn over Classroom of the Elite, running off the screen).
/// Every entry's frame is printed ("LAB …"); an entry overlapping another or
/// past the screen's edge fails the test. The app runs with `-libTrace`, so
/// app.log has the grid's width, columns and every tile's place.
final class HomeGridUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private var t0 = Date()
    private func mark(_ s: String) { print(String(format: "LAB %.2f %@", Date().timeIntervalSince(t0), s)) }

    private func launch(_ entries: Int, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-shots", "-shotsLibrary=\(entries)", "-libTrace", "-noSplash", "-appearance", "light"] + extra
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        t0 = Date()
        sleep(4)
        return app
    }

    private func layout(_ app: XCUIApplication, _ name: String) {
        let menu = app.buttons["viewModeMenu"].firstMatch
        guard menu.waitForExistence(timeout: 5) else { XCTFail("no view menu"); return }
        menu.tap()
        sleep(1)
        let item = app.buttons[name].firstMatch
        guard item.waitForExistence(timeout: 3) else { XCTFail("\(name) not in the view menu"); return }
        item.tap()
        sleep(2)
    }

    private func turn(_ app: XCUIApplication, _ o: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = o
        sleep(3)
    }

    /// Every Home entry on screen, with its frame. Fails on overlaps and on
    /// entries that run past the screen's edges.
    private func check(_ app: XCUIApplication, _ when: String) {
        let window = app.windows.firstMatch.frame
        var frames: [String: CGRect] = [:]
        for e in app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'home:'")).allElementsBoundByIndex {
            guard e.exists else { continue }
            let f = e.frame
            guard !f.isEmpty, f.intersects(window) else { continue }
            let id = String(e.identifier.dropFirst("home:".count))
            if let old = frames[id], old.width * old.height >= f.width * f.height { continue }
            frames[id] = f
        }
        let list = frames.sorted { ($0.value.minY, $0.value.minX) < ($1.value.minY, $1.value.minX) }
        mark("\(when): window \(Int(window.width))×\(Int(window.height)), \(list.count) entries on screen — "
             + list.map { "\($0.key) (\(Int($0.value.minX)), \(Int($0.value.minY)), \(Int($0.value.width)), \(Int($0.value.height)))" }.joined(separator: "; "))
        for (i, a) in list.enumerated() {
            if a.value.maxX > window.maxX + 1 || a.value.minX < window.minX - 1 {
                XCTFail("\(when): \(a.key) runs past the screen's edge: \(a.value) in \(window)")
            }
            for b in list[(i + 1)...] {
                let o = a.value.intersection(b.value)
                if !o.isNull, o.width > 2, o.height > 2 {
                    XCTFail("\(when): \(a.key) and \(b.key) overlap by \(Int(o.width))×\(Int(o.height)) pt")
                }
            }
        }
    }

    private func turnRound(_ app: XCUIApplication, _ label: String) {
        check(app, "\(label), portrait")
        turn(app, .landscapeLeft)
        check(app, "\(label), landscape")
        turn(app, .portrait)
        check(app, "\(label), back to portrait")
    }

    /// Four entries (as in the screenshot) in each layout, turned to
    /// landscape and back.
    func test1FourEntriesTurned() {
        let app = launch(4)
        turnRound(app, "4 entries, Thumbnails")
        layout(app, "List")
        turnRound(app, "4 entries, List")
        layout(app, "Details")
        turnRound(app, "4 entries, Details")
        layout(app, "Thumbnails")
        turnRound(app, "4 entries, Thumbnails again")
    }

    /// 0, 1, 3 and many entries (long names among them), turned.
    func test2Counts() {
        for n in [0, 1, 3, 15] {
            let app = launch(n)
            turnRound(app, "\(n) entries, Thumbnails")
            app.terminate()
        }
    }

    /// The 31 Oct screenshot came after the player was closed in landscape
    /// (that day's log: closed at 01:39:34, screenshot at 01:44): Home was
    /// turned while the player covered it. Played from Continue Watching
    /// (Home right under the player) and from a title page (Home under that).
    func test4PlayerClosedInLandscape() {
        let app = launch(4, ["-labNoEngine"])
        check(app, "before playing, portrait")
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'continue:'")).firstMatch
        guard card.waitForExistence(timeout: 5) else { XCTFail("no Continue Watching card"); return }
        card.tap()
        playTurnAndClose(app, "from Continue Watching")
        check(app, "from Continue Watching, closed in landscape")
        turn(app, .portrait)
        check(app, "from Continue Watching, back to portrait")

        let tile = app.descendants(matching: .any)["home:Lab Show"].firstMatch
        guard tile.waitForExistence(timeout: 5) else { XCTFail("no Lab Show tile"); return }
        tile.tap()
        let play = app.descendants(matching: .any)["heroPlay"].firstMatch
        guard play.waitForExistence(timeout: 8) else { XCTFail("no Play on the title page"); return }
        play.tap()
        playTurnAndClose(app, "from a title page")
        let back = app.buttons["Back"].firstMatch
        if back.waitForExistence(timeout: 5) { back.tap() } else { app.navigationBars.buttons.firstMatch.tap() }
        sleep(2)
        check(app, "from a title page, closed in landscape, back on Home")
        turn(app, .portrait)
        check(app, "from a title page, back to portrait")
    }

    private func playTurnAndClose(_ app: XCUIApplication, _ label: String) {
        let close = app.buttons["Close player"].firstMatch
        guard close.waitForExistence(timeout: 15) else { XCTFail("\(label): the player didn't open"); return }
        mark("\(label): playing")
        turn(app, .landscapeLeft)
        if !close.isHittable { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); sleep(1) }
        close.tap()
        sleep(3)
        mark("\(label): player closed in landscape")
    }

    /// The largest text size, four entries, turned.
    func test3LargestText() {
        let app = launch(4, ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        turnRound(app, "4 entries, largest text, Thumbnails")
        layout(app, "Details")
        turnRound(app, "4 entries, largest text, Details")
        layout(app, "Thumbnails")
    }
}
