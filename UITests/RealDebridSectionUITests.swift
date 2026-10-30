import XCTest

/// Home's Real-Debrid section (1.20.0) with the lab's saved library
/// (ShotsSeed: 25 releases, two titles with a second, older release; no
/// server is asked anything): below Library, Library counting only your own
/// files, no Real-Debrid tile in Library, the row newest first, a release
/// opening its folder's page, See all opening the library, Offline, an
/// empty Library, and the largest text. "LAB …" lines give the frames.
final class RealDebridSectionUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private var t0 = Date()
    private func mark(_ s: String) { print(String(format: "LAB %.2f %@", Date().timeIntervalSince(t0), s)) }

    private func launch(_ entries: Int, _ extra: [String] = ["-shotsRealDebrid"]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-shots", "-shotsLibrary=\(entries)", "-libTrace", "-noSplash", "-appearance", "light"] + extra
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        t0 = Date()
        sleep(4)
        return app
    }

    private func f(_ e: XCUIElement) -> String {
        e.exists ? "(\(Int(e.frame.minX)), \(Int(e.frame.minY)), \(Int(e.frame.width)), \(Int(e.frame.height)))" : "gone"
    }

    private var releases: NSPredicate { NSPredicate(format: "identifier BEGINSWITH 'rd:'") }

    /// Scrolls Home down until See all is on screen.
    private func reveal(_ app: XCUIApplication) {
        let seeAll = app.buttons["realDebridSeeAll"].firstMatch
        var n = 0
        while !(seeAll.exists && seeAll.isHittable), n < 6 { app.swipeUp(velocity: .slow); n += 1 }
        XCTAssertTrue(seeAll.waitForExistence(timeout: 5), "no Real-Debrid section")
        sleep(1)
    }

    /// The releases on screen, left to right.
    private func visible(_ app: XCUIApplication) -> [XCUIElement] {
        // By frame: isHittable fails outright on a release the lazy row has
        // let go of (run 41084826672: "Activation point invalid").
        let window = app.windows.firstMatch.frame
        return app.buttons.matching(releases).allElementsBoundByIndex
            .filter { $0.exists && !$0.frame.isEmpty && window.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    func test1Shown() {
        let app = launch(4)
        let library = app.staticTexts["Library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 5), "no Library header")
        // Library counts your own files only: four entries.
        let count = app.staticTexts["4"].firstMatch
        mark("Library header \(f(library)), count \(f(count))")
        XCTAssertTrue(count.exists, "Library's count isn't 4")
        XCTAssertFalse(app.descendants(matching: .any)["home:Real-Debrid"].exists, "a Real-Debrid entry is still in Library")
        reveal(app)
        let title = app.staticTexts["Real-Debrid"].firstMatch
        mark("section header \(f(title)), See all \(f(app.buttons["realDebridSeeAll"].firstMatch))")
        XCTAssertGreaterThan(title.frame.minY, library.frame.minY, "Real-Debrid isn't below Library")

        // The row, swiped to its end: newest first, every title once.
        var seen: [String] = []
        for _ in 0..<10 {
            let v = visible(app)
            for e in v { let t = String(e.identifier.dropFirst(3)); if !seen.contains(t) { seen.append(t) } }
            guard let last = v.last else { break }
            let before = seen.count
            last.swipeLeft(velocity: .slow)
            sleep(1)
            for e in visible(app) { let t = String(e.identifier.dropFirst(3)); if !seen.contains(t) { seen.append(t) } }
            if seen.count == before { break }
        }
        mark("row, left to right: \(seen.count) titles — \(seen.joined(separator: "; "))")
        XCTAssertEqual(seen.first, "The Gentlemen", "the newest release isn't first")
        XCTAssertLessThanOrEqual(seen.count, 20, "more than 20 in the row")

        // Back to the start, open the newest release.
        for _ in 0..<6 { visible(app).first?.swipeRight(velocity: .fast) }
        sleep(1)
        let first = app.buttons["rd:The Gentlemen"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 3), "The Gentlemen not back in view")
        first.tap()
        let bar = app.navigationBars["The Gentlemen"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "The Gentlemen's folder page didn't open")
        mark("release opened: \(f(bar))")
        sleep(2)
        app.navigationBars.buttons.firstMatch.tap()
        sleep(2)

        // See all: the library.
        reveal(app)
        app.buttons["realDebridSeeAll"].firstMatch.tap()
        let lib = app.navigationBars["Real-Debrid"].firstMatch
        XCTAssertTrue(lib.waitForExistence(timeout: 5), "See all didn't open the library")
        mark("See all opened: \(f(lib))")
        sleep(2)
        app.navigationBars.buttons.firstMatch.tap()
        sleep(2)
    }

    func test2Offline() {
        let app = launch(4, ["-shotsRealDebridOffline"])
        reveal(app)
        let info = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Offline'")).firstMatch
        mark("offline: \(f(info)) \(info.exists ? info.label : "")")
        XCTAssertTrue(info.exists, "the section doesn't say Offline")
        XCTAssertFalse(visible(app).isEmpty, "the row is gone while offline")
    }

    func test3NoFilesOfYourOwn() {
        let app = launch(0)
        let empty = app.staticTexts["Your library is empty"].firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 5), "no empty Library")
        reveal(app)
        let title = app.staticTexts["Real-Debrid"].firstMatch
        mark("empty Library \(f(empty)), Real-Debrid \(f(title))")
        XCTAssertGreaterThan(title.frame.minY, empty.frame.minY, "Real-Debrid isn't below the empty Library")
    }

    func test4LargestText() {
        let app = launch(4, ["-shotsRealDebrid", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        reveal(app)
        let window = app.windows.firstMatch.frame
        let title = app.staticTexts["Real-Debrid"].firstMatch, seeAll = app.buttons["realDebridSeeAll"].firstMatch
        let v = visible(app)
        mark("largest text: header \(f(title)), See all \(f(seeAll)), \(v.count) releases on screen: " + v.map { "\($0.identifier) \(f($0))" }.joined(separator: "; "))
        for e in [title, seeAll] + v where e.exists {
            XCTAssertTrue(e.frame.maxX <= window.maxX + 1 || v.contains(e), "\(e.identifier) runs past the screen's edge")
        }
        XCTAssertFalse(title.frame.intersects(seeAll.frame), "Real-Debrid and See all overlap")
    }
}
