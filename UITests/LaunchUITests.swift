import XCTest

/// Home's launch to interactive: XCTApplicationLaunchMetric waiting until
/// the app responds to input ("waitUntilResponsive"), with four entries of
/// your own and a saved Real-Debrid library of 25 releases (ShotsSeed), so
/// 1.20.0's Real-Debrid section can be compared with the Library tile it
/// replaces. Simulator numbers, for before and after on the same runner —
/// not how fast a phone starts. Each launch also seeds the library again
/// (the same work before and after).
final class LaunchUITests: XCTestCase {
    func testHomeLaunchToInteractive() {
        let app = XCUIApplication()
        app.launchArguments = ["-shots", "-shotsLibrary=4", "-shotsRealDebrid", "-noSplash", "-appearance", "light"]
        // Once first, so the saved summary Home shows on its first frame is
        // there for every measured launch.
        app.launch()
        sleep(4)
        app.terminate()
        let options = XCTMeasureOptions()
        options.iterationCount = 8
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            app.launch()
        }
    }
}
