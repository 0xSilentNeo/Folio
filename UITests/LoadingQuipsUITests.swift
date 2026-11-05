import XCTest

/// A series opened from Discover: while its episodes load, the loading
/// lines show (1.22.5). Live IMDb data, so it's slow enough to see.
final class LoadingQuipsUITests: XCTestCase {
    func test1SeriesPageShowsTheLines() {
        let app = XCUIApplication()
        app.launchArguments = ["-noSplash", "-appearance", "dark", "-labSlowTitle"]
        app.launch()
        app.buttons["Discover"].firstMatch.tap()
        let series = app.buttons["Series"].firstMatch
        XCTAssertTrue(series.waitForExistence(timeout: 10))
        series.tap()
        sleep(3)
        // The grid's first poster, below For you and the services.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.72)).tap()
        let quips = app.descendants(matching: .any)["loadingQuips"]
        XCTAssertTrue(quips.waitForExistence(timeout: 4), "no loading lines on a slow page")
        sleep(4)
    }
}
