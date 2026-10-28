import XCTest

/// Wasted-work audit: what stays alive after it stops being useful. The
/// results are in app.log, which the lab run publishes.
final class AuditUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    /// Play from a title page and close the player, twice. Each close should
    /// be followed in app.log by "player model freed" and "player screen
    /// state freed"; a missing line means that session is still held.
    func test1PlayerFreedAfterClose() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestLibrary", "-noSplash"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let tile = app.staticTexts["Lab Show"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 25), "library tile not found")
        tile.tap()
        let play = app.descendants(matching: .any)["heroPlay"]
        XCTAssertTrue(play.waitForExistence(timeout: 8), "title page did not open")
        for round in 1...2 {
            sleep(2)
            play.tap()
            let close = app.buttons["Close player"]
            XCTAssertTrue(close.waitForExistence(timeout: 20), "player did not open (round \(round))")
            sleep(8)
            print("AUDIT close \(round) \(Date().timeIntervalSince1970)")
            close.tap()
            sleep(5)
            XCTAssertTrue(play.waitForExistence(timeout: 6), "title page gone after closing (round \(round))")
        }
    }
}
