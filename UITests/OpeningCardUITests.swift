import XCTest

/// The opening card over the player (0.90.0). Its picture filled the card by
/// asking for its own size, and the whole player grew to it: with a 2:3
/// poster in a landscape window the player was about 1,240 pt tall, and its
/// buttons and time bar were off the screen until the file had loaded (18 Nov
/// log). `-labHoldOpening` keeps the card up, with a 2:3 picture, long enough
/// to look.
final class OpeningCardUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    func test1ControlsStayOnScreenUnderTheCard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-noSplash", "-renderer", "gl", "-labHoldOpening=20"]
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        let card = app.descendants(matching: .any)["openingCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 30), "the opening card didn't come up")
        sleep(2)                                    // the lab file has loaded behind it
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "opening-card-landscape"
        shot.lifetime = .keepAlways
        add(shot)
        // The player's own controls and the card's words are inside the
        // window, as they are without the card. (The card's own frame isn't
        // looked at: it takes in its picture, which is cut to the window.)
        let close = app.buttons["Close player"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "no close button")
        func inside(_ turn: String) {
            let window = app.windows.firstMatch.frame.insetBy(dx: -1, dy: -1)
            XCTAssertTrue(card.exists, "\(turn): the card went before it was looked at")
            for (name, e) in [("Close", close), ("the time bar", app.otherElements["Playback position"]),
                              ("Back 10 seconds", app.buttons["Back 10 seconds"]), ("the card's spinner", app.otherElements["Loading"]),
                              ("the card's title", app.staticTexts["Lab clip"])] {
                XCTAssertTrue(e.exists, "\(turn): \(name) isn't there")
                XCTAssertTrue(window.contains(e.frame), "\(turn): \(name) is off the screen: \(e.frame) in \(window)")
            }
            XCTAssertTrue(close.isHittable, "\(turn): Close can't be tapped under the card")
        }
        inside("landscape")
        // The same turned upright.
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        inside("upright")
        // The card goes when its hold is over, and the player is still there.
        XCTAssertTrue(card.waitForNonExistence(timeout: 30), "the card stayed")
        XCTAssertTrue(close.exists)
        close.tap()
    }
}
