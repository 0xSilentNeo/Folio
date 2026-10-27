import XCTest
import ObjectiveC

/// Drives the player with real touches in the CI simulator while the screen
/// is recorded: open each panel from its toolbar button, close it by tapping
/// where the (hidden) pill was, drag and tap the Now Playing segmented
/// control, close by tapping outside.
final class PanelUITests: XCTestCase {
    func test0PanelsAndTabs() throws {
        let app = launchPlayer()
        let outside = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45))

        tapPill(app, "Tracks")                                               // open
        XCTAssertTrue(shows(app, "Audio", within: 4), "Tracks panel did not open")
        sleep(2)
        tapPill(app, "Settings"); sleep(1)
        XCTAssertFalse(shows(app, "Audio"), "Tracks did not close on a tap where the pill was")
        if #available(iOS 27, *) {
            // 1.16.0, native morph on iOS 27: another button's spot switches to its panel.
            // (-nativePanelMorph NO arrives as the string "NO", so this test runs the native path.)
            XCTAssertTrue(shows(app, "Playback", within: 3), "a tap on Settings while Tracks was open did not switch (iOS 27)")
        } else {
            XCTAssertFalse(shows(app, "Playback"), "a tap where the pill was opened Settings (hidden button)")
            tapPill(app, "Settings")                                         // now a real tap on Settings
            XCTAssertTrue(shows(app, "Playback", within: 3), "Settings did not open")
        }
        sleep(1)
        tapPill(app, "Settings"); sleep(1)                                   // its own spot → close
        XCTAssertFalse(shows(app, "Playback"), "Settings did not close on its own spot")

        tapPill(app, "Now Playing")
        XCTAssertTrue(shows(app, "NOW PLAYING", within: 4), "Now Playing panel did not open")
        sleep(2)
        let seg = app.segmentedControls.firstMatch
        XCTAssertTrue(seg.waitForExistence(timeout: 5), "segmented control not found")
        if seg.exists {
            let first = seg.buttons.element(boundBy: 0), last = seg.buttons.element(boundBy: 2), mid = seg.buttons.element(boundBy: 1)
            first.press(forDuration: 0.4, thenDragTo: last); sleep(2)  // drag the thumb across
            mid.tap(); sleep(2)                                        // tap
            first.tap(); sleep(2)
            XCTAssertTrue(shows(app, "NOW PLAYING"), "using the segmented control closed the panel")
        }
        outside.tap(); sleep(1)                                        // tap outside → close
        XCTAssertFalse(shows(app, "NOW PLAYING"), "panel did not close on outside tap")
        tapPill(app, "Tracks")
        XCTAssertTrue(shows(app, "Audio", within: 3), "Tracks did not open")
        sleep(1)
        outside.tap(); sleep(1)
        XCTAssertFalse(shows(app, "Audio"), "Tracks did not close on an outside tap")
    }

    /// iOS 26 (SwiftUI glass panels): a tap while a panel is still moving
    /// works at once. Open, then 0.15 s later tap outside (closes); 0.15 s into
    /// that close, tap the button again (reopens).
    func test12TapsWhileMoving() throws {
        let app = launchPlayer()
        let names: [(String, String)] = [("Tracks", "Audio"), ("Settings", "Playback"), ("Now Playing", "NOW PLAYING")]
        var closed = 0, reopened = 0
        let outside = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45))
        for i in 0..<6 {
            let (b, marker) = names[i % 3]
            tapPill(app, b)
            usleep(150_000)
            outside.tap()                                              // mid-opening → closes
            usleep(600_000)
            if !shows(app, marker) { closed += 1 } else { print("MOVING close miss \(b)") }
            tapPill(app, b)
            usleep(250_000)
            outside.tap()                                              // close…
            usleep(150_000)
            tapPill(app, b)                                            // …and 0.15 s into it, reopen
            if shows(app, marker, within: 1.5) { reopened += 1 } else { print("MOVING reopen miss \(b)") }
            outside.tap()
            sleep(1)
        }
        print("MOVING closed \(closed)/6 reopened \(reopened)/6")
        XCTAssertEqual(closed, 6, "a tap outside while a panel was opening was lost")
        XCTAssertEqual(reopened, 6, "a tap on the button while a panel was closing was lost")
    }

    /// Native menu morph (system popover, 1.15.0 default): opens and closes
    /// from each button; a tap where another button is just closes.
    func test13NativeMorph() throws {
        let app = launchPlayer(native: true)
        let outside = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45))
        for (b, marker) in [("Tracks", "Audio"), ("Settings", "Playback"), ("Now Playing", "NOW PLAYING")] {
            tapPill(app, b)
            XCTAssertTrue(shows(app, marker, within: 4), "\(b) did not open (native morph)")
            sleep(2)
            outside.tap(); sleep(2)
            XCTAssertFalse(shows(app, marker), "\(b) did not close (native morph)")
        }
    }

    /// 1.15.0 (#6, app glass): a button tapped while the last panel is still
    /// closing opens its own panel — the glass reshapes, no second tap needed.
    func test14SwitchWhileClosing() throws {
        let app = launchPlayer()
        let outside = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45))
        let pairs: [(String, String, String, String)] = [("Tracks", "Audio", "Settings", "Playback"), ("Settings", "Playback", "Now Playing", "NOW PLAYING"), ("Now Playing", "NOW PLAYING", "Tracks", "Audio")]
        var ok = 0
        for (a, am, b, bm) in pairs {
            tapPill(app, a)
            XCTAssertTrue(shows(app, am, within: 3), "\(a) did not open")
            sleep(1)
            outside.tap()                                              // starts closing
            usleep(120_000)
            tapPill(app, b)                                            // mid-close → straight into b
            if shows(app, bm, within: 2) { ok += 1 } else { print("SWITCH miss \(a) → \(b)") }
            sleep(1)
            outside.tap(); sleep(1)
        }
        print("SWITCH while closing \(ok)/\(pairs.count)")
        XCTAssertEqual(ok, pairs.count, "a button tapped while a panel was closing did not open its panel")
    }

    /// 1.15.0 (#5): Settings closes with a pull down every time — a plain pull,
    /// and a pull right after flicking the list back to the top.
    func test15SettingsPullDown() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestLibrary", "-noSplash"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.staticTexts["Lab Show"].firstMatch.waitForExistence(timeout: 25), "library not found")
        sleep(1)
        var ok = 0
        let tries = 6
        for i in 0..<tries {
            app.buttons["Settings"].firstMatch.tap()
            XCTAssertTrue(app.staticTexts["General"].waitForExistence(timeout: 5), "Settings did not open")
            sleep(1)
            let mid = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            if i % 2 == 1 {
                // Flick up a little, flick back to the top, then pull at once.
                mid.press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)), withVelocity: .fast, thenHoldForDuration: 0)
                usleep(150_000)
                mid.press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)), withVelocity: .fast, thenHoldForDuration: 0)
                usleep(250_000)
            }
            mid.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)), withVelocity: .default, thenHoldForDuration: 0)
            sleep(2)
            if !app.staticTexts["General"].exists || !app.staticTexts["General"].isHittable { ok += 1 } else {
                print("PULL miss on try \(i)")
                app.navigationBars.buttons.element(boundBy: 0).tap(); sleep(2)
            }
        }
        print("PULL closed \(ok)/\(tries)")
        XCTAssertEqual(ok, tries, "a pull down did not close Settings")
    }

    /// 1.15.0 (#9): a page that is going away takes no taps. Back, then a tap
    /// where its Play button was, must not start playback.
    func test16NoTapsOnLeavingPage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestLibrary", "-noSplash"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let tile = app.staticTexts["Lab Show"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 25), "library tile not found")
        var played = 0
        for delay in [50_000, 150_000, 300_000] as [useconds_t] {
            sleep(1); tile.tap()
            let play = app.descendants(matching: .any)["heroPlay"]
            XCTAssertTrue(play.waitForExistence(timeout: 6), "title page did not open")
            sleep(1)
            let spot = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: play.frame.midX, dy: play.frame.midY))
            app.buttons["Back"].tap()
            usleep(delay)
            spot.tap()
            if app.buttons["Close player"].waitForExistence(timeout: 3) {
                played += 1
                print("LEAVING page played after \(delay) µs")
                app.buttons["Close player"].tap(); sleep(3)
                if app.buttons["Back"].exists { app.buttons["Back"].tap() }
            }
            sleep(2)
            if app.buttons["Back"].exists { app.buttons["Back"].tap(); sleep(2) }
        }
        XCTAssertEqual(played, 0, "a tap on a page that was going away started playback")
    }

    private func launchPlayer(_ extra: [String] = [], native: Bool = false, captureNow: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-labNoEngine", "-nativePanelMorph", native ? "YES" : "NO"] + extra
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 20), "toolbar button not found")
        // Wait for the rotation to finish: spots taken in portrait missed in
        // landscape (25 Oct replay run: the Tracks tap hit the video).
        let end = Date().addingTimeInterval(10)
        while Date() < end {
            let w = app.windows.firstMatch.frame
            if w.width > w.height { break }
            usleep(200_000)
        }
        sleep(2)
        spots = [:]
        if captureNow { captureSpots(app) }
        return app
    }

    /// A replay run (-panelStress) opens panels on its own, which hides their
    /// buttons; it captures the spots after the replay instead.
    private func captureSpots(_ app: XCUIApplication) {
        for n in ["Tracks", "Settings", "Now Playing"] {
            let f = app.buttons[n].frame
            spots[n] = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.midY))
        }
    }

    /// Where each pill button is, captured once: tapped like a finger (the
    /// accessibility tree can lag behind a non-animated close).
    private var spots: [String: XCUICoordinate] = [:]
    private func tapPill(_ app: XCUIApplication, _ name: String) {
        // Where the button is now, when it's on screen (it can move with a
        // rotation); otherwise where it was (hidden while its panel is open).
        let e = app.buttons[name]
        if e.exists, e.isHittable, e.frame.width > 0 {
            spots[name] = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: e.frame.midX, dy: e.frame.midY))
        }
        spots[name]!.tap()
    }
    /// The panel's content is on screen (the built panel is kept in memory
    /// between openings, so `exists` alone can lag).
    private func shows(_ app: XCUIApplication, _ marker: String, within t: TimeInterval = 0) -> Bool {
        let e = app.staticTexts[marker]
        let end = Date().addingTimeInterval(t)
        repeat {
            // isHittable on an element without a usable frame (mid-transition) is an XCTest
            // failure in itself ("Activation point invalid"), so check the frame first.
            // The element can vanish between these queries ("Failed to get matching snapshot");
            // that is not a test failure here, just "not showing".
            var visible = false
            let options = XCTExpectedFailure.Options()
            options.isStrict = false
            XCTExpectFailure("panel content can leave mid-query", options: options) {
                visible = e.exists && !e.frame.isEmpty && app.windows.firstMatch.frame.intersects(e.frame) && e.isHittable
            }
            if visible { return true }
            if t > 0 { usleep(100_000) }
        } while Date() < end
        return false
    }

    /// Long press on the player's Settings button (the recording shows whether
    /// the glass lights up and grows while held).
    func test1PressPlayerToolbar() throws {
        let app = launchPlayer()
        app.buttons["Settings"].press(forDuration: 1.2)
        XCTAssertTrue(app.staticTexts["Playback"].waitForExistence(timeout: 4), "Settings did not open after a long press")
        sleep(2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap(); sleep(2)
    }

    /// Ten quick open/close cycles: every tap must open its panel.
    func test4RapidTaps() throws {
        let app = launchPlayer()
        let names: [(String, String)] = [("Tracks", "Audio"), ("Settings", "Playback"), ("Now Playing", "NOW PLAYING")]
        var ok = 0
        for i in 0..<10 {
            let (button, marker) = names[i % 3]
            tapPill(app, button)
            if shows(app, marker, within: 2) { ok += 1 } else { print("RAPID miss at \(i) (\(button))") }
            usleep(400_000)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap()
            usleep(700_000)
        }
        print("RAPID opened \(ok)/10")
        XCTAssertEqual(ok, 10, "some taps did not open their panel")
    }

    /// Lock button next to PiP: locks the controls, Unlock restores them.
    func test5LockButton() throws {
        let app = launchPlayer()
        let lock = app.buttons["Lock controls"]
        XCTAssertTrue(lock.waitForExistence(timeout: 5), "lock button missing")
        lock.tap()
        XCTAssertTrue(app.buttons["Unlock"].waitForExistence(timeout: 4), "Unlock did not appear")
        XCTAssertFalse(app.buttons["Settings"].exists, "controls still shown while locked")
        sleep(1)
        app.buttons["Unlock"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 4), "controls did not come back")
        sleep(1)
    }

    /// The tap sequence from the freeze log, replayed at its real timing.
    /// Afterwards the screen must match the last tap (Settings open) and the
    /// player must still respond: outside tap closes, Tracks opens and closes.
    func test6RapidSwitchReplay() throws { try replay([]) }

    /// Same replay without the settle delay between transitions. Fails (UIKit
    /// transition never completes); kept for comparison, rename to test… to run.
    func comparisonReplayNoSettle() throws { try replay(["-panelNoSettle"]) }

    private func replay(_ extra: [String], native: Bool = false) throws {
        let app = launchPlayer(["-panelStress"] + extra, native: native, captureNow: false)
        sleep(22)                                                 // replay: 3.5 s after landscape settles, lasts 11.6 s
        XCTAssertTrue(shows(app, "Playback", within: 4), "Settings (last tap) is not showing")
        XCTAssertFalse(shows(app, "NOW PLAYING"), "an orphaned Now Playing panel is on screen")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap(); sleep(2)
        XCTAssertFalse(shows(app, "Playback"), "panel did not close after the replay (stuck)")
        captureSpots(app)
        tapPill(app, "Tracks")
        XCTAssertTrue(shows(app, "Audio", within: 4), "player unresponsive after the replay")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap(); sleep(2)
        XCTAssertFalse(shows(app, "Audio"), "Tracks did not close")
    }

    /// Title page: open it, play an episode, close the player, then Back must
    /// return to Home; and the edge swipe must work too.
    func test8TitlePageBack() throws { try titlePageBack([]) }

    /// The ⋯ button on a title page, tapped off-centre (where a finger often
    /// lands on the circle, not on the thin glyph) — must open its menu every time.
    func test11MoreButtonEdgeTaps() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestLibrary", "-noSplash"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let tile = app.staticTexts["Lab Show"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 25), "library tile not found")
        sleep(1); tile.tap()
        let more = app.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 6), "More button not found")
        sleep(2)
        print("MORE frame \(more.frame)")
        var ok = 0
        let spots: [CGVector] = [CGVector(dx: 0.2, dy: 0.5), CGVector(dx: 0.8, dy: 0.5), CGVector(dx: 0.5, dy: 0.2), CGVector(dx: 0.5, dy: 0.8), CGVector(dx: 0.25, dy: 0.25)]
        for (i, v) in spots.enumerated() {
            more.coordinate(withNormalizedOffset: v).tap()
            if app.buttons["Delete file"].waitForExistence(timeout: 2) || app.staticTexts["Delete file"].exists { ok += 1 } else { print("MORE miss at spot \(i) \(v)") }
            sleep(1)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()   // dismiss the menu
            sleep(1)
        }
        print("MORE opened \(ok)/\(spots.count)")
        XCTAssertEqual(ok, spots.count, "the More button missed taps")
    }


    private func titlePageBack(_ extra: [String]) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestLibrary"] + extra
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let tile = app.staticTexts["Lab Show"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 25), "library tile not found")
        sleep(2)
        tile.tap()
        let back = app.buttons["Back"]
        XCTAssertTrue(back.waitForExistence(timeout: 6), "title page did not open")
        sleep(1)
        // Baseline: Back before anything was played.
        print("BACK frame \(back.frame) hittable=\(back.isHittable)")
        back.tap(); sleep(2)
        XCTAssertFalse(app.buttons["Back"].exists, "Back did not work even before playing")
        if app.buttons["Back"].exists { app.buttons["Back"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); sleep(2) }
        if !app.buttons["Back"].exists { tile.tap(); XCTAssertTrue(back.waitForExistence(timeout: 6), "title page did not reopen"); sleep(1) }
        let play = app.descendants(matching: .any)["heroPlay"]
        XCTAssertTrue(play.waitForExistence(timeout: 5), "play button not found")
        play.tap()
        let close = app.buttons["Close player"]
        XCTAssertTrue(close.waitForExistence(timeout: 20), "player did not open")
        sleep(10)                                                  // let it play and save progress
        close.tap()
        sleep(4)                                                   // history updates → Home rebuilds underneath
        XCTAssertTrue(back.waitForExistence(timeout: 6), "title page gone after closing the player")
        back.tap()
        sleep(2)
        if app.buttons["Back"].exists {
            // Diagnose: does any touch reach the page? (logged by the app)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); sleep(1)
        }
        XCTAssertFalse(app.buttons["Back"].exists, "Back did not leave the title page")
        XCTAssertTrue(app.staticTexts["Lab Show"].firstMatch.waitForExistence(timeout: 4), "not back on Home")

        // Again, leaving with the edge swipe this time.
        app.staticTexts["Lab Show"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 6), "title page did not open (2nd time)")
        sleep(1)
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 2, dy: app.frame.height * 0.3))
        start.press(forDuration: 0.02, thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width * 0.8, dy: app.frame.height * 0.3)),
                    withVelocity: .default, thenHoldForDuration: 0)
        sleep(2)
        if app.buttons["Back"].exists {
            print("SWIPE edge drag did not go back; trying a swipe from the middle")
            app.swipeRight(); sleep(2)
        }
        XCTAssertFalse(app.buttons["Back"].exists, "edge swipe did not leave the title page")
    }

    /// The 1.12.0 black screen (24 Oct, 19:08:20): a panel finishes opening and
    /// the user taps outside at once. Ten times, at different delays around
    /// the end of the opening: each single tap must close the panel, and no
    /// panel may be left up (full screen or otherwise).
    func test9TapOutsideAsItOpens() throws {
        let app = launchPlayer()
        var closedFirstTap = 0
        for i in 0..<10 {
            tapPill(app, "Settings")
            usleep(UInt32(150_000 + i * 40_000))                       // 0.15 … 0.51 s after the tap
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap()
            sleep(3)                                                   // opening + closing morph
            if !shows(app, "Playback") { closedFirstTap += 1 } else {
                print("OUTSIDE still open after one tap at \(150 + i * 40) ms")
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap(); sleep(1)
            }
            XCTAssertFalse(shows(app, "Playback"), "panel stuck on screen (round \(i))")
        }
        print("OUTSIDE closed with one tap \(closedFirstTap)/10")
        XCTAssertEqual(closedFirstTap, 10, "an outside tap during/at the end of opening did not close the panel")
    }

    /// One outside tap closes a fully open panel, and the pill comes back fast
    /// enough that a button tap 0.3 s later opens the next panel.
    func test10OneTapCloseThenOpen() throws {
        let app = launchPlayer()
        var ok = 0
        let names: [(String, String)] = [("Tracks", "Audio"), ("Settings", "Playback"), ("Now Playing", "NOW PLAYING")]
        for i in 0..<9 {
            let (button, marker) = names[i % 3]
            tapPill(app, button)
            XCTAssertTrue(shows(app, marker, within: 3), "\(button) did not open")
            sleep(1)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap()
            let t0 = Date()
            var closed = false
            while Date().timeIntervalSince(t0) < 2.5 { if !shows(app, marker) { closed = true; break }; usleep(100_000) }
            if closed { ok += 1; print(String(format: "ONETAP %@ closed %.1f s after one tap", button, Date().timeIntervalSince(t0))) }
            else { print("ONETAP \(button) still open 2.5 s after one tap") }
            sleep(1)
        }
        print("ONETAP closed \(ok)/9")
        XCTAssertEqual(ok, 9, "one outside tap did not close the panel")
    }

    /// The lost tap from the 24 Oct recording: close with an outside tap, then
    /// 0.5 s later tap a button. Every one of 20 such taps must open its panel.
    func test7CloseThenTapHalfSecond() throws {
        let app = launchPlayer()
        let names: [(String, String)] = [("Settings", "Playback"), ("Now Playing", "NOW PLAYING"), ("Tracks", "Audio")]
        var ok = 0
        for i in 0..<20 {
            let (button, marker) = names[i % 3]
            tapPill(app, button)
            let opened = shows(app, marker, within: 3)
            if opened { ok += 1 } else { print("HALFSEC miss at \(i) (\(button))") }
            sleep(1)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap()   // outside → close
            usleep(500_000)                                                            // the timing from the recording
        }
        print("HALFSEC opened \(ok)/20")
        XCTAssertEqual(ok, 20, "some taps after a close were lost")
    }

    // MARK: Native menu morph (system popover) — 1.15.1

    /// XCUITest waits for the app's animations to settle before every tap, so a
    /// tap "0.15 s into the close" really landed after the whole morph (25 Oct
    /// lab: the app logged it 1.3 s late). These tests tap like a finger: no wait.
    private var swizzled: [(Method, IMP)] = []
    private func tapsDontWaitForAnimations() {
        guard swizzled.isEmpty, let cls = NSClassFromString("XCUIApplicationProcess") else { return }
        let one: @convention(block) (AnyObject, Bool) -> Void = { _, _ in }
        let two: @convention(block) (AnyObject, Bool, Bool) -> Void = { _, _, _ in }
        for (name, block) in [("waitForQuiescenceIncludingAnimationsIdle:", one as Any), ("waitForQuiescenceIncludingAnimationsIdle:isPreEvent:", two as Any)] {
            guard let m = class_getInstanceMethod(cls, NSSelectorFromString(name)) else { continue }
            swizzled.append((m, method_getImplementation(m)))
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
    }

    override func tearDown() {
        for (m, imp) in swizzled { method_setImplementation(m, imp) }
        swizzled = []
        super.tearDown()
    }

    /// A button tapped while the last panel is still closing opens its panel
    /// (UIKit holds the tap until the morph ends; it must not be lost). Once
    /// 0.15 s and once 0.4 s into the close; also the same button again.
    func test17NativeSwitchWhileClosing() throws {
        let app = launchPlayer(native: true)
        tapsDontWaitForAnimations()
        let outside = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45))
        let pairs: [(String, String, String, String)] = [
            ("Tracks", "Audio", "Settings", "Playback"), ("Settings", "Playback", "Now Playing", "NOW PLAYING"),
            ("Now Playing", "NOW PLAYING", "Tracks", "Audio"), ("Settings", "Playback", "Settings", "Playback"),
        ]
        var ok = 0, total = 0
        for delay: UInt32 in [150_000, 400_000] {
            for (a, am, b, bm) in pairs {
                total += 1
                tapPill(app, a)
                XCTAssertTrue(shows(app, am, within: 4), "\(a) did not open (native)")
                sleep(2)
                outside.tap()                                          // starts the close morph
                usleep(delay)
                let t0 = Date()
                tapPill(app, b)                                        // mid-close
                // UIKit holds the tap until the close morph is nearly over (iOS 26 and 27
                // simulators), then the open morph runs: allow both.
                if shows(app, bm, within: 5) {
                    ok += 1
                    print(String(format: "NATIVE SWITCH %@ → %@ (%d ms into the close): showing %.0f ms after the tap", a, b, delay / 1000, Date().timeIntervalSince(t0) * 1000))
                } else { print("NATIVE SWITCH miss \(a) → \(b) at \(delay / 1000) ms") }
                sleep(2)
                if shows(app, bm) { outside.tap() }                    // close it (only if open)
                sleep(2)
            }
        }
        print("NATIVE SWITCH while closing \(ok)/\(total)")
        XCTAssertEqual(ok, total, "a button tapped while a native panel was closing did not open its panel")
    }

    /// An outside tap while a panel is still opening closes it with that one
    /// tap (acted on as soon as the opening morph ends).
    func test18NativeTapOutsideWhileOpening() throws {
        let app = launchPlayer(native: true)
        tapsDontWaitForAnimations()
        let outside = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45))
        var ok = 0
        for i in 0..<6 {
            let (b, marker) = [("Tracks", "Audio"), ("Settings", "Playback"), ("Now Playing", "NOW PLAYING")][i % 3]
            tapPill(app, b)
            usleep(UInt32(150_000 + i * 60_000))                       // 0.15 … 0.45 s into the open
            outside.tap()
            let t0 = Date()
            var closed = false
            while Date().timeIntervalSince(t0) < 3 { if !shows(app, marker) { closed = true; break }; usleep(100_000) }
            if closed { ok += 1; print(String(format: "NATIVE MOVING %@: closed %.0f ms after the outside tap", b, Date().timeIntervalSince(t0) * 1000)) }
            else { print("NATIVE MOVING \(b) still open 3 s after the outside tap"); outside.tap() }
            sleep(2)
        }
        print("NATIVE MOVING closed \(ok)/6")
        XCTAssertEqual(ok, 6, "an outside tap while a native panel was opening did not close it")
    }

    /// test7's lost-tap timing with the native morph: close, then 0.5 s later
    /// tap a button; every tap opens its panel.
    func test19NativeCloseThenTapHalfSecond() throws {
        let app = launchPlayer(native: true)
        tapsDontWaitForAnimations()
        let names: [(String, String)] = [("Settings", "Playback"), ("Now Playing", "NOW PLAYING"), ("Tracks", "Audio")]
        var ok = 0
        for i in 0..<9 {
            let (button, marker) = names[i % 3]
            let t0 = Date()
            tapPill(app, button)
            if shows(app, marker, within: 3) { ok += 1; print(String(format: "NATIVE HALFSEC %@: showing %.0f ms after the tap", button, Date().timeIntervalSince(t0) * 1000)) }
            else { print("NATIVE HALFSEC miss at \(i) (\(button))") }
            sleep(1)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap()
            usleep(500_000)
        }
        sleep(2)
        print("NATIVE HALFSEC opened \(ok)/9")
        XCTAssertEqual(ok, 9, "some taps after a native close were lost")
    }

    /// The freeze-log tap sequence with the native morph: it must end on the
    /// last tap's panel and leave the player responsive.
    func test20NativeRapidSwitchReplay() throws { try replay([], native: true) }

    /// 1.16.1 (device log, 7 cases since 1.14.1): a back swipe that starts on
    /// the title page's Play button started playback while the page went back.
    /// Swipes right from the Play button, several speeds and lengths: the page
    /// may go back, but the player must never open.
    func test31SwipeBackFromPlay() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestLibrary"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let tile = app.staticTexts["Lab Show"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 25), "library tile not found")
        sleep(2)
        var played = 0, wentBack = 0
        let swipes: [(CGFloat, XCUIGestureVelocity)] = [(60, .fast), (120, .fast), (220, .fast), (60, .default), (220, .default), (30, .fast)]
        for (i, (dist, speed)) in swipes.enumerated() {
            if !app.buttons["Back"].exists {
                tile.tap()
                XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 6), "title page did not open (\(i))")
                sleep(2)
            }
            let play = app.descendants(matching: .any)["heroPlay"]
            guard play.waitForExistence(timeout: 5) else { XCTFail("play button not found (\(i))"); return }
            let f = play.frame
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let from = origin.withOffset(CGVector(dx: f.minX + 24, dy: f.midY))
            let to = origin.withOffset(CGVector(dx: f.minX + 24 + dist, dy: f.midY + 4))
            from.press(forDuration: 0.01, thenDragTo: to, withVelocity: speed, thenHoldForDuration: 0)
            sleep(3)
            let close = app.buttons["Close player"]
            if close.exists {
                played += 1
                print("SWIPEPLAY \(i) dist=\(Int(dist)) → the player opened")
                close.tap(); sleep(3)
            } else {
                print("SWIPEPLAY \(i) dist=\(Int(dist)) → no playback, page \(app.buttons["Back"].exists ? "stayed" : "went back")")
            }
            if !app.buttons["Back"].exists { wentBack += 1 }
        }
        print("SWIPEPLAY played \(played)/\(swipes.count), went back \(wentBack)")
        XCTAssertEqual(played, 0, "a back swipe starting on Play started playback")
    }

    /// 1.17.0 swipe actions. Thumbnails (the default view) on Home and on a
    /// title page: a swipe to the left lays Delete and Watched over the tile
    /// and doesn't open anything; Delete asks first and Cancel keeps the
    /// title. List view on Home: the system row swipe, both directions.
    func test32SwipeActions() throws {
        var app = XCUIApplication()
        app.launchArguments = ["-uiTestLibrary", "-libraryView", "grid", "-heroView", "grid"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        var tile = app.staticTexts["Lab Show"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 25), "library tile not found")
        sleep(2)

        // Home, Thumbnails
        tile.swipeLeft(); sleep(1)
        print("SWIPE home grid: Back=\(app.buttons["Back"].exists) Delete=\(app.buttons["Delete"].exists) Watched=\(app.buttons["Watched"].exists)")
        XCTAssertFalse(app.buttons["Back"].exists, "the swipe opened the title page")
        XCTAssertTrue(app.buttons["Watched"].waitForExistence(timeout: 2), "no Watched after swiping a Home tile left")
        app.buttons["Watched"].tap(); sleep(1)
        let eye = app.images["Watched"].firstMatch
        print("SWIPE home grid: eye after Watched = \(eye.exists)")
        XCTAssertTrue(eye.exists, "no eye on the tile after Watched")
        tile.swipeLeft(); sleep(1)
        XCTAssertTrue(app.buttons["Unwatched"].waitForExistence(timeout: 2), "Watched did not turn into Unwatched")
        app.buttons["Delete"].tap(); sleep(1)
        cancelDelete(app, "home grid")
        XCTAssertTrue(tile.exists, "Cancel deleted the title")

        // Title page, Thumbnails (tapped by position: after the dialog XCUITest
        // could not compute the label's hit point, 26 Oct run)
        let f = tile.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.minY - 40)).tap()
        if !app.buttons["Back"].waitForExistence(timeout: 4) {
            print("SWIPE first tap after the dialog did not open the page; tapping again")
            sleep(2)
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.minY - 40)).tap()
        }
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 6), "title page did not open")
        sleep(2)
        let ep = app.buttons["ep:Lab Show S01E02.mp4"]
        if !ep.waitForExistence(timeout: 4) { app.swipeUp(); sleep(1) }
        XCTAssertTrue(ep.exists, "episode tile not found")
        ep.swipeLeft(); sleep(1)
        print("SWIPE title grid: player=\(app.buttons["Close player"].exists) Delete=\(app.buttons["Delete"].exists) Watched=\(app.buttons["Watched"].exists)")
        XCTAssertFalse(app.buttons["Close player"].exists, "the swipe played the episode")
        XCTAssertTrue(app.buttons["Delete"].exists, "no Delete after swiping an episode left")
        app.buttons["Delete"].tap(); sleep(1)
        cancelDelete(app, "title grid")
        XCTAssertTrue(app.buttons["ep:Lab Show S01E02.mp4"].exists, "Cancel deleted the episode")
        app.terminate()

        // Home, List view: system swipe actions
        app = XCUIApplication()
        app.launchArguments = ["-uiTestLibrary", "-libraryView", "list"]
        app.launch()
        tile = app.staticTexts["Lab Show"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 25), "library row not found")
        sleep(2)
        tile.swipeLeft(); sleep(1)
        let asked = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Delete all'")).firstMatch
        if !asked.exists, app.buttons["Delete"].exists { app.buttons["Delete"].tap(); sleep(1) }
        print("SWIPE home list left: asked=\(asked.exists)")
        cancelDelete(app, "home list")
        XCTAssertTrue(app.staticTexts["Lab Show"].firstMatch.exists, "Cancel deleted the row (list)")
        tile.swipeRight(); sleep(1)
        let right = app.buttons["Unwatched"].exists ? "Unwatched" : app.buttons["Watched"].exists ? "Watched" : "none"
        print("SWIPE home list right: \(right)")
        XCTAssertNotEqual(right, "none", "no Watched / Unwatched after swiping a row right")
    }

    /// The delete question must show; then cancel it (Cancel button, or a tap
    /// outside when the dialog is a popover).
    private func cancelDelete(_ app: XCUIApplication, _ tag: String) {
        let q = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Delete'")).firstMatch
        print("SWIPE \(tag): question=\(q.exists) \(q.exists ? q.label : "")")
        XCTAssertTrue(q.waitForExistence(timeout: 3), "Delete did not ask first (\(tag))")
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap() }
        sleep(1)
    }

    /// 26 Oct device recording: a swipe that started on an episode row played
    /// the episode while the page zoomed back to Home. Swipes right, down and
    /// diagonally from an episode row: the player must never open. The app
    /// log says when a swipe would have counted as a tap ("ignored (the
    /// finger moved …").
    func test36SwipeFromEpisodeRow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestLibrary", "-heroView", "details"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let tile = app.staticTexts["Lab Show"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 25), "library tile not found")
        sleep(2)
        var played = 0, wentBack = 0
        let moves: [(CGFloat, CGFloat, XCUIGestureVelocity)] = [(120, 0, .fast), (220, 0, .fast), (0, 180, .fast), (0, 320, .fast),
                                                               (160, 160, .fast), (60, 0, .default), (220, 40, .default)]
        for (i, (dx, dy, speed)) in moves.enumerated() {
            if !app.buttons["Back"].exists {
                let f = app.staticTexts["Lab Show"].firstMatch.frame
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.midY)).tap()
                XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 6), "title page did not open (\(i))")
                sleep(2)
            }
            let ep = app.buttons["ep:Lab Show S01E02.mp4"]
            guard ep.waitForExistence(timeout: 5) else { XCTFail("episode row not found (\(i))"); return }
            let f = ep.frame
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let from = origin.withOffset(CGVector(dx: f.minX + 40, dy: f.midY))
            let to = origin.withOffset(CGVector(dx: f.minX + 40 + dx, dy: f.midY + dy))
            from.press(forDuration: 0.01, thenDragTo: to, withVelocity: speed, thenHoldForDuration: 0)
            sleep(3)
            let close = app.buttons["Close player"]
            let back = !app.buttons["Back"].exists
            if close.exists {
                played += 1
                print("SWIPEROW \(i) (\(Int(dx)),\(Int(dy))) → the player opened")
                close.tap(); sleep(3)
            } else {
                print("SWIPEROW \(i) (\(Int(dx)),\(Int(dy))) → no playback, page \(back ? "went back" : "stayed")")
            }
            if back { wentBack += 1 }
        }
        print("SWIPEROW played \(played)/\(moves.count), went back \(wentBack)")
        XCTAssertEqual(played, 0, "a swipe starting on an episode row started playback")
    }

    /// 27 Oct report: a tap to the right of a menu closes it late, a tap to
    /// its left at once. Taps around an open Tracks menu; the app log has each
    /// touch ("[touch] down") and what closed the menu, with times.
    func test37TapOutsideLatency() throws { try tapOutsideLatency(relay: false) }
    func test38TapOutsideLatencyRelay() throws { try tapOutsideLatency(relay: true) }

    private func tapOutsideLatency(relay: Bool) throws {
        let app = launchPlayer(["-touchLog"] + (relay ? ["-relayAlways"] : []), native: true)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let w = app.frame.width, h = app.frame.height
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss.SSS"
        let spots = ["left of the menu, 40 pt", "right of the menu, 20 pt", "right screen edge", "above the menu",
                     "video, left", "video, centre", "right of the menu, low", "left of the menu, 10 pt"]
        func at(_ name: String, _ f: CGRect) -> CGPoint {
            switch name {
            case "left of the menu, 40 pt": return CGPoint(x: f.minX - 40, y: f.midY)
            case "right of the menu, 20 pt": return CGPoint(x: min(w - 4, f.maxX + 20), y: f.midY)
            case "right screen edge": return CGPoint(x: w - 8, y: f.midY)
            case "above the menu": return CGPoint(x: f.midX, y: max(6, f.minY - 30))
            case "video, left": return CGPoint(x: w * 0.15, y: h * 0.5)
            case "video, centre": return CGPoint(x: w * 0.5, y: h * 0.4)
            case "right of the menu, low": return CGPoint(x: min(w - 4, f.maxX + 20), y: f.maxY - 20)
            default: return CGPoint(x: f.minX - 10, y: f.midY)
            }
        }
        for (i, name) in spots.enumerated() {
            tapPill(app, "Tracks")
            guard shows(app, "Audio", within: 5) else { XCTFail("Tracks did not open (\(i))"); continue }
            sleep(2)
            let pop = app.popovers.firstMatch
            let f = pop.exists ? pop.frame : .zero
            let p = at(name, f)
            print("TAPOUT \(relay ? "relay" : "player") \(i) \(name): menu \(f.integral), tap (\(Int(p.x)), \(Int(p.y))) issued \(fmt.string(from: Date()))")
            origin.withOffset(CGVector(dx: p.x, dy: p.y)).tap()
            sleep(3)
            let still = shows(app, "Audio")
            print("TAPOUT \(relay ? "relay" : "player") \(i) closed: \(!still)")
            if still { origin.withOffset(CGVector(dx: w * 0.3, dy: h * 0.5)).tap(); sleep(3) }
        }
    }

    /// Measurement only (app log, "relay lab"): menus opened right after a
    /// close and switched while open, driven from inside the app; with the
    /// relay anchored to the button's rectangle, to the bar item, and off.
    func test33RelayLabRect() throws {
        _ = launchPlayer(["-relayLab", "-menuRelay", "YES", "-relaySource", "rect"], native: true, captureNow: false)
        sleep(30)
    }
    func test34RelayLabItem() throws {
        _ = launchPlayer(["-relayLab", "-menuRelay", "YES", "-relaySource", "item"], native: true, captureNow: false)
        sleep(30)
    }
    func test35RelayLabOff() throws {
        _ = launchPlayer(["-relayLab", "-menuRelay", "NO"], native: true, captureNow: false)
        sleep(30)
    }

    /// Measurement only (results in the app log): the toolbar width iOS needs
    /// for the three panel buttons, and where its glass sits.
    func test30ToolbarProbe() throws {
        _ = launchPlayer(["-toolbarProbe"], native: true, captureNow: false)
        sleep(50)
    }

    /// 1.16.0, iOS 27: with a panel fully open, one tap on
    /// another button opens that panel. Before iOS 27 the tap only closes the
    /// open panel (as in 1.15).
    func test21NativeSwitchWhileOpen() throws {
        let app = launchPlayer(native: true)
        tapsDontWaitForAnimations()
        let pairs: [(String, String, String, String)] = [
            ("Tracks", "Audio", "Settings", "Playback"), ("Settings", "Playback", "Now Playing", "NOW PLAYING"),
            ("Now Playing", "NOW PLAYING", "Tracks", "Audio"),
        ]
        var ok = 0
        for (a, am, b, bm) in pairs {
            tapPill(app, a)
            XCTAssertTrue(shows(app, am, within: 4), "\(a) did not open (native)")
            sleep(2)
            let t0 = Date()
            tapPill(app, b)
            if #available(iOS 27, *) {
                if shows(app, bm, within: 3) {
                    ok += 1
                    print(String(format: "NATIVE OPENSWITCH %@ → %@: showing %.0f ms after the tap", a, b, Date().timeIntervalSince(t0) * 1000))
                } else { print("NATIVE OPENSWITCH miss \(a) → \(b)") }
            } else {
                sleep(2)
                if !shows(app, am) && !shows(app, bm) { ok += 1 } else { print("NATIVE OPENSWITCH (iOS 26) \(a): not just closed") }
                sleep(1)
                continue        // nothing is open: an outside tap would hide the controls
            }
            sleep(2)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap(); sleep(2)
        }
        print("NATIVE OPENSWITCH \(ok)/\(pairs.count)")
        XCTAssertEqual(ok, pairs.count)
    }

    /// The relay layer (PanelRelay) switched on: does UIKit present from it? (lab)
    func test23NativeSwitchRelay() throws {
        let app = launchPlayer(["-menuRelay", "YES"], native: true)
        tapsDontWaitForAnimations()
        let pairs: [(String, String, String, String)] = [
            ("Tracks", "Audio", "Settings", "Playback"), ("Settings", "Playback", "Now Playing", "NOW PLAYING"),
        ]
        for (a, am, b, bm) in pairs {
            tapPill(app, a)
            XCTAssertTrue(shows(app, am, within: 4), "\(a) did not open")
            sleep(2)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap()   // close
            usleep(500_000)                                                         // visibly gone, still "presented"
            let t0 = Date()
            tapPill(app, b)
            let ok = shows(app, bm, within: 4)
            print(String(format: "RELAY %@ after closing %@: %@ %.0f ms after the tap", b, a, ok ? "showing" : "missing", Date().timeIntervalSince(t0) * 1000))
            sleep(2)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap(); sleep(2)
        }
    }

    /// 1.16.0, iOS 27: a tap on another button while a panel is still opening
    /// ends with the second panel on screen (the first goes out, animated).
    func test22NativeSwitchWhileOpening() throws {
        let app = launchPlayer(native: true)
        tapsDontWaitForAnimations()
        guard #available(iOS 27, *) else { print("NATIVE OPENINGSWITCH skipped before iOS 27"); return }
        let pairs: [(String, String, String, String)] = [
            ("Tracks", "Audio", "Settings", "Playback"), ("Settings", "Playback", "Now Playing", "NOW PLAYING"),
            ("Now Playing", "NOW PLAYING", "Tracks", "Audio"),
        ]
        var ok = 0
        for (a, _, b, bm) in pairs {
            tapPill(app, a)
            usleep(250_000)
            let t0 = Date()
            tapPill(app, b)
            if shows(app, bm, within: 3) {
                ok += 1
                print(String(format: "NATIVE OPENINGSWITCH %@ → %@: showing %.0f ms after the tap", a, b, Date().timeIntervalSince(t0) * 1000))
            } else { print("NATIVE OPENINGSWITCH miss \(a) → \(b)") }
            sleep(2)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap(); sleep(2)
        }
        print("NATIVE OPENINGSWITCH \(ok)/\(pairs.count)")
        XCTAssertEqual(ok, pairs.count)
    }
}

/// Discover → title page, the path that crashed 1.12.0 on device. The IMDb
/// cache is seeded (`-labDiscover`), so no network is needed.
final class DiscoverUITests: XCTestCase {
    func testOpenTitlesFromDiscover() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-labDiscover", "-noSplash"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let tab = app.tabBars.buttons["Discover"].exists ? app.tabBars.buttons["Discover"] : app.buttons["Discover"]
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "Discover tab not found")
        tab.tap()
        for name in ["Lab Movie", "Lab Series"] {
            let tile = app.staticTexts[name].firstMatch
            XCTAssertTrue(tile.waitForExistence(timeout: 15), "\(name) tile not in the grid")
            sleep(1)
            tile.tap()
            sleep(6)                                                   // let the page load, decipher, lay out
            XCTAssertEqual(app.state, .runningForeground, "app is gone after opening \(name)")
            print("TITLEPAGE \(name) alive=\(app.state == .runningForeground)")
            XCTAssertTrue(app.descendants(matching: .any)["heroPlay"].waitForExistence(timeout: 5), "\(name): play button missing")
            app.swipeUp(); sleep(2)                                    // scroll to cast + links
            XCTAssertEqual(app.state, .runningForeground, "app is gone after scrolling \(name)")
            let back = app.navigationBars.buttons.firstMatch
            if back.exists { back.tap() } else { app.swipeRight() }
            sleep(2)
        }
    }
}


/// Taps that land WHILE a panel is still animating, like a person's. The UI
/// test runner normally waits for every animation to finish before it taps,
/// which is why the earlier tests passed while taps on the phone were lost
/// (15-13-07 recording: a tap ~0.2 s after a close showed the pill's press
/// highlight and did nothing). Here that wait is switched off.
final class TapDuringAnimationTests: XCTestCase {
    private var saved: [(Method, IMP)] = []

    override func setUp() {
        super.setUp()
        guard let cls = NSClassFromString("XCUIApplicationProcess") else { print("MIDTAP no XCUIApplicationProcess"); return }
        let one: @convention(block) (AnyObject, Bool) -> Void = { _, _ in }
        let two: @convention(block) (AnyObject, Bool, Bool) -> Void = { _, _, _ in }
        for (name, block) in [("waitForQuiescenceIncludingAnimationsIdle:", one as Any), ("waitForQuiescenceIncludingAnimationsIdle:isPreEvent:", two as Any)] {
            guard let m = class_getInstanceMethod(cls, NSSelectorFromString(name)) else { continue }
            saved.append((m, method_getImplementation(m)))
            method_setImplementation(m, imp_implementationWithBlock(block))
            print("MIDTAP idle wait off: \(name)")
        }
    }

    override func tearDown() {
        for (m, imp) in saved { method_setImplementation(m, imp) }
        saved = []
        super.tearDown()
    }

    private func run(style: String, assert: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-labNoEngine", "-panelTransition", style]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 20), "toolbar button not found")
        sleep(3)
        let f = app.buttons["Settings"].frame
        let settings = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.midY))
        let outside = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45))
        func open(within t: TimeInterval) -> Bool {
            let e = app.staticTexts["Playback"], end = Date().addingTimeInterval(t)
            repeat { if e.exists && e.isHittable { return true }; usleep(50_000) } while Date() < end
            return false
        }
        var ok = 0
        let delays: [UInt32] = [150, 250, 350, 500, 700, 150, 250, 350, 500, 700]
        for (i, d) in delays.enumerated() {
            settings.tap()
            guard open(within: 3) else { print("MIDTAP \(style) round \(i): first open failed"); outside.tap(); sleep(2); continue }
            sleep(2)
            outside.tap()                                   // dismiss…
            usleep(d * 1000)                                // …and tap the button again this soon after
            settings.tap()
            let t0 = Date()
            if open(within: 1.5) { ok += 1; print(String(format: "MIDTAP %@ round %d: tap %d ms after close → open in %.0f ms", style, i, d, Date().timeIntervalSince(t0) * 1000)) }
            else { print("MIDTAP \(style) round \(i): tap \(d) ms after close was LOST") }
            sleep(2)
            outside.tap()
            sleep(2)
        }
        print("MIDTAP \(style) opened \(ok)/\(delays.count)")
        if assert { XCTAssertEqual(ok, delays.count, "taps during the close animation were lost (\(style))") }
    }

    func testQuick() { run(style: "quick", assert: true) }
    func testMorphForComparison() { run(style: "morphFrozen", assert: false) }
}
