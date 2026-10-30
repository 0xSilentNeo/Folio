import XCTest

/// The lock button and the "Locked" pill it morphs into (1.20.0): where the
/// close, lock and PiP buttons are before, during and after, that nothing
/// beside the lock moves, that the bottom controls go and come back, that a
/// second tap mid-morph works, and that the pill hides with the controls.
/// The screen is recorded; "LAB …" lines give the seconds for the frames.
final class PlayerLockUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private var t0 = Date()
    private func mark(_ s: String) { print(String(format: "LAB %.2f %@", Date().timeIntervalSince(t0), s)) }

    private func launch(_ o: UIDeviceOrientation, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-labNoEngine", "-noSplash"] + extra
        app.launch()
        XCUIDevice.shared.orientation = o
        t0 = Date()
        XCTAssertTrue(app.buttons["Lock controls"].waitForExistence(timeout: 20), "no lock button")
        sleep(2)
        return app
    }

    private func frame(_ e: XCUIElement) -> String {
        e.exists ? "(\(Int(e.frame.minX)), \(Int(e.frame.minY)), \(Int(e.frame.width)), \(Int(e.frame.height)))\(e.isHittable ? "" : " not hittable")" : "gone"
    }

    private func buttons(_ app: XCUIApplication, _ when: String) -> (close: CGRect, pip: CGRect) {
        let close = app.buttons["Close player"].firstMatch, pip = app.buttons["Picture in Picture"].firstMatch
        let lock = app.buttons["Lock controls"].firstMatch, pill = app.buttons["lockPill"].firstMatch
        let play = app.buttons["Now Playing"].firstMatch
        mark("\(when): close \(frame(close)), lock \(frame(lock)), pill \(frame(pill)), PiP \(frame(pip)), Now Playing \(frame(play))")
        return (close.exists ? close.frame : .null, pip.exists ? pip.frame : .null)
    }

    private func lockAndUnlock(_ app: XCUIApplication, _ label: String) {
        let before = buttons(app, "\(label): unlocked")
        app.buttons["Lock controls"].firstMatch.tap()
        mark("\(label): lock tapped")
        usleep(150_000); _ = buttons(app, "\(label): +0.15 s")
        usleep(350_000); _ = buttons(app, "\(label): +0.5 s")
        sleep(1)
        let locked = buttons(app, "\(label): locked")
        XCTAssertTrue(app.buttons["lockPill"].firstMatch.isHittable, "\(label): no Locked pill")
        XCTAssertFalse(app.buttons["Now Playing"].firstMatch.isHittable, "\(label): bottom controls still there when locked")
        if !before.pip.isNull, !locked.pip.isNull { XCTAssertEqual(before.pip, locked.pip, "\(label): PiP moved") }
        if !before.close.isNull, !locked.close.isNull { XCTAssertEqual(before.close, locked.close, "\(label): close moved") }
        app.buttons["lockPill"].firstMatch.tap()
        mark("\(label): pill tapped")
        sleep(1)
        let after = buttons(app, "\(label): unlocked again")
        XCTAssertTrue(app.buttons["Lock controls"].firstMatch.isHittable, "\(label): no lock button after unlocking")
        XCTAssertTrue(app.buttons["Now Playing"].firstMatch.isHittable, "\(label): bottom controls not back")
        if !before.pip.isNull, !after.pip.isNull { XCTAssertEqual(before.pip, after.pip, "\(label): PiP moved") }
    }

    func test1Portrait() {
        let app = launch(.portrait)
        lockAndUnlock(app, "portrait")
    }

    func test2Landscape() {
        let app = launch(.landscapeLeft)
        lockAndUnlock(app, "landscape")
    }

    /// A second tap while the morph runs turns it straight back.
    func test3TapMidMorph() {
        let app = launch(.portrait)
        app.buttons["Lock controls"].firstMatch.tap()
        mark("lock tapped")
        usleep(120_000)
        let pill = app.buttons["lockPill"].firstMatch
        if pill.exists { pill.tap(); mark("pill tapped 0.12 s in") } else { mark("no pill 0.12 s in") }
        sleep(1)
        _ = buttons(app, "after the second tap")
        XCTAssertTrue(app.buttons["Lock controls"].firstMatch.isHittable, "a tap mid-morph didn't unlock")
    }

    /// Locked, the pill hides with the controls after 4 s; a tap on the
    /// video shows it again.
    func test4AutoHide() {
        let app = launch(.landscapeLeft, ["-labAutoHide"])
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        if !app.buttons["Lock controls"].firstMatch.isHittable { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); sleep(1) }
        app.buttons["Lock controls"].firstMatch.tap()
        mark("locked")
        sleep(6)
        _ = buttons(app, "6 s later")
        XCTAssertFalse(app.buttons["lockPill"].firstMatch.isHittable, "the pill didn't hide with the controls")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        _ = buttons(app, "after a tap on the video")
        XCTAssertTrue(app.buttons["lockPill"].firstMatch.isHittable, "a tap didn't show the pill")
    }
}
