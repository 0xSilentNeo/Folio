import XCTest

/// 1.25.0: Settings → Notifications. A group's check turns it off and on,
/// the personality is picked, and Test is there.
final class NotifyUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testNotificationsPage() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-openNotify"]
        app.launch()

        let trending = app.buttons["notifyGroup.trending"]
        XCTAssertTrue(trending.waitForExistence(timeout: 15), "no Trending now row")
        XCTAssertEqual(trending.label, "Trending now, on")
        trending.tap()
        XCTAssertTrue(app.buttons["Trending now, off"].waitForExistence(timeout: 5), "Trending now didn't turn off")
        app.buttons["notifyGroup.trending"].tap()
        XCTAssertTrue(app.buttons["Trending now, on"].waitForExistence(timeout: 5), "Trending now didn't turn back on")

        // Every group has its row.
        for g in ["watching", "newReleases", "recommendations", "library", "briefing", "fun", "downloads"] {
            XCTAssertTrue(app.buttons["notifyGroup.\(g)"].exists, "no row for \(g)")
        }

        // Subtle switches Just for fun off; Balanced brings it back.
        let subtle = app.buttons["notifyTone.subtle"]
        for _ in 0..<4 where !subtle.isHittable { app.swipeUp() }
        subtle.tap()
        for _ in 0..<4 where !app.staticTexts["Off in Subtle"].exists { app.swipeDown() }
        XCTAssertTrue(app.staticTexts["Off in Subtle"].waitForExistence(timeout: 5), "Just for fun doesn't say it's off in Subtle")
        let balanced = app.buttons["notifyTone.balanced"]
        for _ in 0..<4 where !balanced.isHittable { app.swipeUp() }
        balanced.tap()

        let test = app.switches["notifyTest"]
        for _ in 0..<6 where !test.exists { app.swipeUp() }
        XCTAssertTrue(test.waitForExistence(timeout: 5), "no Test switch")
        XCTAssertTrue(app.buttons["notifySendNext"].exists)
        XCTAssertTrue(app.buttons["notifySent"].exists)
    }
}
