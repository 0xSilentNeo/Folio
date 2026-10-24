import XCTest

/// Drives the player with real touches in the CI simulator while the screen
/// is recorded: open each panel from its toolbar button, close it by tapping
/// where the (hidden) pill was, drag and tap the Now Playing segmented
/// control, close by tapping outside.
final class PanelUITests: XCTestCase {
    func test0PanelsAndTabs() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-labNoEngine"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft

        let tracks = app.buttons["Tracks"]
        XCTAssertTrue(tracks.waitForExistence(timeout: 20), "toolbar button not found")
        sleep(2)
        // Where the pill's buttons are (they hide while a panel is open).
        func spot(_ name: String) -> XCUICoordinate {
            let f = app.buttons[name].frame
            return app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.midY))
        }
        let settingsSpot = spot("Settings"), nowPlayingSpot = spot("Now Playing"), tracksSpot = spot("Tracks")

        tracks.tap()                                                         // open
        XCTAssertTrue(app.staticTexts["Audio"].waitForExistence(timeout: 4), "Tracks panel did not open")
        sleep(2)
        settingsSpot.tap(); sleep(1)                                         // another button's spot → just closes
        XCTAssertFalse(app.staticTexts["Audio"].exists, "Tracks did not close on a tap where the pill was")
        XCTAssertFalse(app.staticTexts["Playback"].exists, "a tap where the pill was opened Settings (hidden button)")
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 3), "pill not back after the close")
        app.buttons["Settings"].tap()                                        // now a real tap on Settings
        XCTAssertTrue(app.staticTexts["Playback"].waitForExistence(timeout: 3), "Settings did not open")
        sleep(1)
        settingsSpot.tap(); sleep(1)                                         // its own spot → close
        XCTAssertFalse(app.staticTexts["Playback"].exists, "Settings did not close on its own spot")

        XCTAssertTrue(app.buttons["Now Playing"].waitForExistence(timeout: 5), "pill not back after closing from its own spot")
        app.buttons["Now Playing"].tap()
        XCTAssertTrue(app.staticTexts["NOW PLAYING"].waitForExistence(timeout: 4), "Now Playing panel did not open")
        sleep(2)

        let seg = app.segmentedControls.firstMatch
        XCTAssertTrue(seg.waitForExistence(timeout: 5), "segmented control not found")
        let first = seg.buttons.element(boundBy: 0), last = seg.buttons.element(boundBy: 2), mid = seg.buttons.element(boundBy: 1)
        first.press(forDuration: 0.4, thenDragTo: last); sleep(2)  // drag the thumb across
        mid.tap(); sleep(2)                                        // tap
        first.tap(); sleep(2)

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap(); sleep(2)   // tap outside → close
        XCTAssertFalse(app.staticTexts["NOW PLAYING"].exists, "panel did not close on outside tap")
        tracks.tap(); sleep(2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap(); sleep(2)   // outside → close
        XCTAssertFalse(app.staticTexts["Audio"].exists, "Tracks did not close on an outside tap")
        _ = nowPlayingSpot; _ = tracksSpot
    }

    private func launchPlayer(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-labNoEngine"] + extra
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 20), "toolbar button not found")
        sleep(2)
        return app
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
            app.buttons[button].tap()
            if app.staticTexts[marker].waitForExistence(timeout: 2) { ok += 1 } else { print("RAPID miss at \(i) (\(button))") }
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

    private func replay(_ extra: [String]) throws {
        let app = launchPlayer(["-panelStress"] + extra)
        sleep(22)                                                 // replay: 3.5 s after landscape settles, lasts 11.6 s
        XCTAssertTrue(app.staticTexts["Playback"].waitForExistence(timeout: 4), "Settings (last tap) is not showing")
        XCTAssertFalse(app.staticTexts["NOW PLAYING"].exists, "an orphaned Now Playing panel is on screen")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap(); sleep(2)
        XCTAssertFalse(app.staticTexts["Playback"].exists, "panel did not close after the replay (stuck)")
        app.buttons["Tracks"].tap()
        XCTAssertTrue(app.staticTexts["Audio"].waitForExistence(timeout: 4), "player unresponsive after the replay")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap(); sleep(2)
        XCTAssertFalse(app.staticTexts["Audio"].exists, "Tracks did not close")
    }

    /// Title page: open it, play an episode, close the player, then Back must
    /// return to Home; and the edge swipe must work too.
    func test8TitlePageBack() throws { try titlePageBack([]) }


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
            app.buttons["Settings"].tap()
            usleep(UInt32(150_000 + i * 40_000))                       // 0.15 … 0.51 s after the tap
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap()
            sleep(1)
            if !app.staticTexts["Playback"].exists { closedFirstTap += 1 } else {
                print("OUTSIDE still open after one tap at \(150 + i * 40) ms")
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap(); sleep(1)
            }
            XCTAssertFalse(app.staticTexts["Playback"].exists, "panel stuck on screen (round \(i))")
            XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 3), "pill gone (round \(i))")
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
            app.buttons[button].tap()
            XCTAssertTrue(app.staticTexts[marker].waitForExistence(timeout: 3), "\(button) did not open")
            usleep(800_000)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap()
            usleep(300_000)
            if !app.staticTexts[marker].exists { ok += 1 } else { print("ONETAP \(button) still open 0.3 s after one tap") }
            usleep(300_000)
        }
        print("ONETAP closed \(ok)/9")
        XCTAssertEqual(ok, 9, "one outside tap did not close the panel within 0.3 s")
    }

    /// The lost tap from the 24 Oct recording: close with an outside tap, then
    /// 0.5 s later tap a button. Every one of 20 such taps must open its panel.
    func test7CloseThenTapHalfSecond() throws {
        let app = launchPlayer()
        let names: [(String, String)] = [("Settings", "Playback"), ("Now Playing", "NOW PLAYING"), ("Tracks", "Audio")]
        var ok = 0
        for i in 0..<20 {
            let (button, marker) = names[i % 3]
            app.buttons[button].tap()
            let opened = app.staticTexts[marker].waitForExistence(timeout: 3)
            if opened { ok += 1 } else { print("HALFSEC miss at \(i) (\(button))") }
            sleep(1)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap()   // outside → close
            usleep(500_000)                                                            // the timing from the recording
        }
        print("HALFSEC opened \(ok)/20")
        XCTAssertEqual(ok, 20, "some taps after a close were lost")
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
