import XCTest

/// 0.90.0: a Continue Watching card's long-press menu has "Go to Show",
/// which opens the title's page on that episode. The lab's card is a
/// library file (Lab Show S01E01), so the page is the library's, with the
/// episode's row on it.
final class GoToShowUITests: XCTestCase {
    func testGoToShowFromContinueWatching() {
        let app = XCUIApplication()
        app.launchArguments = ["-shots", "-labNoEngine", "-noSplash", "-appearance", "light"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'continue:Lab Show'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "no Continue Watching card")
        card.press(forDuration: 1.2)
        let go = app.buttons["Go to Show"].firstMatch
        XCTAssertTrue(go.waitForExistence(timeout: 5), "no Go to Show in the card's menu")
        // The rest of the menu is still there.
        XCTAssertTrue(app.buttons["Mark as watched"].exists, "Mark as watched left the menu")
        XCTAssertTrue(app.buttons["Remove"].exists, "Remove left the menu")
        go.tap()
        XCTAssertTrue(app.descendants(matching: .any)["heroPlay"].waitForExistence(timeout: 8), "the title page didn't open")
        XCTAssertTrue(app.descendants(matching: .any)["ep:Lab Show S01E01.mp4"].waitForExistence(timeout: 5), "the episode's row isn't on the page")
        // Nothing played: the menu's item opens the page only.
        XCTAssertFalse(app.descendants(matching: .any)["playerClose"].exists, "Go to Show started the player")
    }
}
