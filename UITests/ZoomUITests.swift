import XCTest

/// Fit ↔ Fill on the video layer (1.28.2: a scale of the view, the layer
/// always whole), and closing the player. Screenshots are kept in the
/// result, for the picture at each step; the close is timed.
final class ZoomUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func test1PinchToFillAndBackThenClose() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-noSplash", "-renderer", "gl"]
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 30), "player didn't open")
        sleep(4)
        shot(app, "1-fit")
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // Pinch out: Fill.
        app.windows.firstMatch.pinch(withScale: 1.6, velocity: 2)
        usleep(150_000); shot(app, "2-fill-settling")
        sleep(1); shot(app, "3-fill")
        // Pinch in: Fit.
        app.windows.firstMatch.pinch(withScale: 0.6, velocity: -2)
        usleep(150_000); shot(app, "4-fit-settling")
        sleep(1); shot(app, "5-fit")
        // A turn of the phone in Fill keeps the picture filled and centred.
        app.windows.firstMatch.pinch(withScale: 1.6, velocity: 2)
        sleep(1)
        XCUIDevice.shared.orientation = .portrait
        sleep(2); shot(app, "6-fill-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2); shot(app, "7-fill-landscape")
        _ = middle
        // Close: the player should be gone well within a second.
        let close = app.buttons["Close player"]
        if !close.isHittable { app.tap(); sleep(1) }
        let start = Date()
        close.tap()
        let gone = close.waitForNonExistence(timeout: 5)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        print("ZOOMTEST close took \(ms) ms (gone: \(gone))")
        XCTAssertTrue(gone, "player didn't close")
        shot(app, "8-closed")
    }
}
