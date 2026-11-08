import XCTest

/// 1.25.0: Settings → Notifications. A group's page turns it off and on,
/// the personality is picked, and Test's page opens from its row.
final class NotifyUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testNotificationsPage() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestLibrary", "-openNotify"]  // no clip playing underneath
        app.launch()

        // 1.26.1: a group's row says On or Off and opens its page, where its switch is.
        let trending = app.buttons["notifyGroup.trending"]
        XCTAssertTrue(trending.waitForExistence(timeout: 15), "no Trending now row")
        XCTAssertEqual(trending.value as? String, "On")
        trending.tap()
        let toggle = app.switches["notifyGroupToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Trending now's page didn't open")
        flip(toggle, to: "0")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["notifyGroup.trending"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["notifyGroup.trending"].value as? String, "Off", "Trending now didn't turn off")
        app.buttons["notifyGroup.trending"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        flip(toggle, to: "1")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["notifyGroup.trending"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["notifyGroup.trending"].value as? String, "On", "Trending now didn't turn back on")

        // Every group has its row.
        for g in ["watching", "newReleases", "recommendations", "library", "briefing", "fun", "downloads"] {
            let row = app.buttons["notifyGroup.\(g)"]
            for _ in 0..<3 where !row.exists { app.swipeUp() }
            XCTAssertTrue(row.exists, "no row for \(g)")
        }

        // Subtle switches Just for fun off; Balanced brings it back. The
        // personality is a checkmark list: its rows are buttons.
        func tone(_ raw: String, _ title: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", "notifyTone.\(raw)", title)).firstMatch
        }
        let fun = app.buttons["notifyGroup.fun"]
        let subtle = tone("subtle", "Subtle")
        for _ in 0..<4 where !subtle.isHittable { app.swipeUp() }
        subtle.tap()
        XCTAssertTrue(subtle.isSelected, "Subtle isn't checked")
        for _ in 0..<4 where !fun.isHittable { app.swipeDown() }
        XCTAssertTrue(fun.label.contains("Off in Subtle"), "Just for fun doesn't say it's off in Subtle: \(fun.label)")
        let balanced = tone("balanced", "Balanced")
        for _ in 0..<4 where !balanced.isHittable { app.swipeUp() }
        balanced.tap()
        XCTAssertTrue(balanced.isSelected, "Balanced isn't checked")

        // 1.26.1: Test has its own page; while it's on, a row at the top opens it.
        for _ in 0..<4 where !app.buttons["notifyTestRow"].isHittable { app.swipeDown() }
        app.buttons["notifyTestRow"].tap()
        let test = app.switches["notifyTest"]
        XCTAssertTrue(test.waitForExistence(timeout: 5), "no Test switch")
        XCTAssertTrue(app.buttons["notifySendNext"].exists)
        XCTAssertTrue(app.buttons["notifySent"].exists)
    }

    /// A Form switch: tap its knob, on the trailing edge (the middle of the row is
    /// its label, which doesn't flip it), and check it flipped.
    private func flip(_ toggle: XCUIElement, to value: String) {
        let knob = toggle.switches.firstMatch.exists ? toggle.switches.firstMatch : toggle
        knob.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let flipped = NSPredicate(format: "value == %@", value)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: flipped, object: toggle)], timeout: 3), .completed,
                       "the switch didn't flip to \(value): \(String(describing: toggle.value))")
    }
}
