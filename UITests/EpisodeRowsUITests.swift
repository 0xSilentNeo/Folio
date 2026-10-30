import XCTest

/// Episode rows on a title page with long episode titles (30 Oct screenshot:
/// "The Crossroa…", "Beggars Ba…"), in List and Details, at the default and
/// a large text size. The screen is recorded; "LAB …" lines give the seconds
/// and each title's frame.
final class EpisodeRowsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private var t0 = Date()
    private func mark(_ s: String) { print(String(format: "LAB %.2f %@", Date().timeIntervalSince(t0), s)) }
    private let title = "The Crossroads Where Everything We Knew Comes Apart"

    private func rows(_ size: String?) {
        let app = XCUIApplication()
        app.launchArguments = ["-shots", "-shotsEpisodeTitle=\(title)", "-noSplash", "-appearance", "light"]
            + (size.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? [])
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        t0 = Date()
        let show = app.buttons["home:Lab Show"].firstMatch
        guard show.waitForExistence(timeout: 20) else { XCTFail("no Lab Show on Home"); return }
        show.tap()
        sleep(3)
        for mode in ["List", "Details"] {
            let menu = app.buttons["viewModeMenu"].firstMatch
            guard menu.waitForExistence(timeout: 5) else { XCTFail("no view menu on the title page"); return }
            menu.tap(); sleep(1)
            app.buttons[mode].firstMatch.tap(); sleep(2)
            let texts = app.staticTexts.matching(NSPredicate(format: "label == %@", title)).allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
            mark("\(size ?? "default text"), \(mode): \(texts.count) episode title(s) on screen at " + texts.map { "(\(Int($0.frame.minX)), \(Int($0.frame.minY)), \(Int($0.frame.width)), \(Int($0.frame.height)))" }.joined(separator: " "))
            app.swipeUp(); sleep(2)
            mark("\(size ?? "default text"), \(mode): scrolled to the episodes")
            app.swipeDown(); sleep(1)
        }
        app.terminate()
    }

    func test1Default() { rows(nil) }
    func test2LargeText() { rows("UICTContentSizeCategoryAccessibilityL") }
}
