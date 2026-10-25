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
        tapPill(app, "Settings"); sleep(1)                                   // another button's spot → just closes
        XCTAssertFalse(shows(app, "Audio"), "Tracks did not close on a tap where the pill was")
        XCTAssertFalse(shows(app, "Playback"), "a tap where the pill was opened Settings (hidden button)")
        tapPill(app, "Settings")                                             // now a real tap on Settings
        XCTAssertTrue(shows(app, "Playback", within: 3), "Settings did not open")
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

    private func launchPlayer(_ extra: [String] = [], native: Bool = false) -> XCUIApplication {
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
        for n in ["Tracks", "Settings", "Now Playing"] {
            let f = app.buttons[n].frame
            spots[n] = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.midY))
        }
        return app
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
            if e.exists && e.isHittable { return true }
            if t > 0 { usleep(100_000) }
        } while Date() < end
        return false
    }

    /// Long press on the player's Settings button (the recording shows whether
    /// the glass lights up and grows while held, like Outplayer's).
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
        let app = launchPlayer(["-panelStress"] + extra, native: native)
        sleep(22)                                                 // replay: 3.5 s after landscape settles, lasts 11.6 s
        XCTAssertTrue(shows(app, "Playback", within: 4), "Settings (last tap) is not showing")
        XCTAssertFalse(shows(app, "NOW PLAYING"), "an orphaned Now Playing panel is on screen")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap(); sleep(2)
        XCTAssertFalse(shows(app, "Playback"), "panel did not close after the replay (stuck)")
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
    /// without waiting out the close morph (it is fast-forwarded). Once 0.15 s
    /// and once 0.4 s into the close; also the same button again.
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
                if shows(app, bm, within: 3) {
                    ok += 1
                    print(String(format: "NATIVE SWITCH %@ → %@ (%d ms into the close): showing %.0f ms after the tap", a, b, delay / 1000, Date().timeIntervalSince(t0) * 1000))
                } else { print("NATIVE SWITCH miss \(a) → \(b) at \(delay / 1000) ms") }
                sleep(2)
                outside.tap(); sleep(2)
            }
        }
        print("NATIVE SWITCH while closing \(ok)/\(total)")
        XCTAssertEqual(ok, total, "a button tapped while a native panel was closing did not open its panel")
    }

    /// An outside tap while a panel is still opening closes it with that one
    /// tap, soon (the open is fast-forwarded, then the close morph runs).
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
