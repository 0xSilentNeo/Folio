import XCTest

/// "q" on a hardware keyboard (1.20.2): keys go to mpv, whose default "q"
/// binding quits it. The player used to stay up with no mpv behind it (and
/// with the OpenGL or PiP renderer attached, mpv's core went while a render
/// context was still alive). Now the player closes as with its close button,
/// and the app carries on.
final class QuitKeyUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// On the OpenGL renderer: its render context is what mpv must not lose
    /// its core under (and Metal's MoltenVK can't start in an Intel Mac's
    /// simulator).
    func test1QuitKeyClosesThePlayer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestLibrary", "-noSplash", "-uiTest", "-renderer", "gl"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let tile = app.staticTexts["Lab Show"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 25), "library tile not found")
        tile.tap()
        let play = app.descendants(matching: .any)["heroPlay"]
        XCTAssertTrue(play.waitForExistence(timeout: 8), "title page did not open")
        sleep(2)
        play.tap()
        let close = app.buttons["Close player"]
        XCTAssertTrue(close.waitForExistence(timeout: 20), "player did not open")
        sleep(6)                                    // mpv has the file open
        app.typeKey("q", modifierFlags: [])
        // The player's window goes; the title page is what's left.
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: close)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(play.waitForExistence(timeout: 10), "title page not back after q")
        XCTAssertEqual(app.state, .runningForeground, "the app quit or crashed")
        // And a second session still plays.
        sleep(2)
        play.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 20), "player did not open again")
        close.tap()
    }
}
