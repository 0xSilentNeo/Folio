import XCTest
@testable import Folio

/// 1.30.0: the iPad's layout by its window's width (PageLayout), where the
/// tab bar is (TabChrome), and the player's own keys (PlayerShortcut).
@MainActor
final class IPadLayout1300Tests: XCTestCase {
    // MARK: PageLayout

    /// An iPhone gets what it had before 1.30.0 at every width, its
    /// landscape included: the old formulas, written out here.
    func testPhoneLayoutIsUnchanged() {
        for w: CGFloat in [320, 375, 393, 402, 430, 440, 667, 700, 701, 852, 874, 932, 956] {
            let l = PageLayout(width: w, pad: false)
            let margin: CGFloat = w > 700 ? 28 : 20
            XCTAssertFalse(l.regular, "\(w)")
            XCTAssertEqual(l.margin, margin, "\(w)")
            XCTAssertEqual(l.posterColumns, max(3, Int((w - margin * 2 + 14) / 124)), "\(w)")
            XCTAssertEqual(l.thumbColumns, max(2, Int((w - margin * 2 + 14) / 184)), "\(w)")
            XCTAssertEqual(l.discoverColumns, max(3, Int((w - margin * 2 + 12) / 122)), "\(w)")
            XCTAssertEqual(l.continueCardWidth, w > 700 ? 320 : min(340, w - margin * 2 - 44), "\(w)")
            XCTAssertEqual(l.readableSide(20), 20, "\(w)")
            XCTAssertEqual(l.readableSide(16), 16, "\(w)")
            XCTAssertNil(l.readableListInset, "\(w)")
        }
    }

    /// Slide Over, a third or half of a Split View, the page beside an open
    /// sidebar: as narrow as a phone, and laid out as one.
    func testNarrowPadWindowFallsBackToThePhoneLayout() {
        for w: CGFloat in [320, 375, 507, 514, 597, 678, 700] {
            XCTAssertEqual(PageLayout(width: w, pad: true), PageLayout(width: w, pad: false), "\(w)")
            let l = PageLayout(width: w, pad: true)
            XCTAssertFalse(l.regular)
            XCTAssertEqual(l.margin, 20)
            XCTAssertNil(l.readableListInset)
        }
    }

    func testPadColumnsAndMargins() {
        // 11-inch upright, on its side, and a 13-inch on its side.
        let upright = PageLayout(width: 834, pad: true)
        XCTAssertTrue(upright.regular)
        XCTAssertEqual(upright.margin, 28)
        XCTAssertEqual(upright.posterColumns, 5)
        XCTAssertEqual(upright.thumbColumns, 3)
        XCTAssertEqual(upright.discoverColumns, 5)

        let side = PageLayout(width: 1194, pad: true)
        XCTAssertEqual(side.margin, 44)
        XCTAssertEqual(side.posterColumns, 7)
        XCTAssertEqual(side.thumbColumns, 4)
        XCTAssertEqual(side.discoverColumns, 7)

        let large = PageLayout(width: 1366, pad: true)
        XCTAssertEqual(large.posterColumns, 8)
        XCTAssertEqual(large.thumbColumns, 5)
    }

    /// No tiny posters and no giant ones, at any iPad window width.
    func testPadTilesStayASensibleSize() {
        for w in stride(from: CGFloat(701), through: 1400, by: 7) {
            let l = PageLayout(width: w, pad: true)
            let inner = w - l.margin * 2
            let poster = (inner - CGFloat(l.posterColumns - 1) * 14) / CGFloat(l.posterColumns)
            XCTAssertGreaterThanOrEqual(poster, 134, "\(w)")
            XCTAssertLessThan(poster, 175, "\(w)")
            let thumb = (inner - CGFloat(l.thumbColumns - 1) * 14) / CGFloat(l.thumbColumns)
            XCTAssertGreaterThanOrEqual(thumb, 226, "\(w)")
            XCTAssertLessThan(thumb, 350, "\(w)")
            let discover = (inner - CGFloat(l.discoverColumns - 1) * 12) / CGFloat(l.discoverColumns)
            XCTAssertGreaterThanOrEqual(discover, 134, "\(w)")
            XCTAssertLessThan(discover, 175, "\(w)")
            XCTAssertGreaterThanOrEqual(l.continueCardWidth, 340, "\(w)")
            XCTAssertLessThanOrEqual(l.continueCardWidth, 420, "\(w)")
        }
    }

    func testReadableColumn() {
        // Upright there is little to trim; on its side the column is centred.
        XCTAssertEqual(PageLayout(width: 834, pad: true).readableSide(28), 37)
        XCTAssertEqual(PageLayout(width: 1194, pad: true).readableSide(28), 217)
        XCTAssertEqual(PageLayout(width: 1194, pad: true).readableSide(16), 217)
        XCTAssertEqual(PageLayout(width: 1194 - 217 * 2, pad: true).width, PageLayout.readableWidth)
        // A window barely wider than the column keeps the page's own margin.
        XCTAssertEqual(PageLayout(width: 780, pad: true).readableSide(28), 28)
        // A list keeps its own margins until the column is clearly narrower.
        XCTAssertNil(PageLayout(width: 790, pad: true).readableListInset)
        XCTAssertEqual(PageLayout(width: 834, pad: true).readableListInset, 37)
        XCTAssertEqual(PageLayout(width: 1194, pad: true).readableListInset, 217)
    }

    // MARK: TabChrome

    func testWhereTheTabBarIs() {
        XCTAssertTrue(TabChrome.atBottom(regularWidth: false, pad: false, iOS18: true))
        XCTAssertTrue(TabChrome.atBottom(regularWidth: true, pad: false, iOS18: true))     // a large phone on its side
        XCTAssertTrue(TabChrome.atBottom(regularWidth: false, pad: true, iOS18: true))     // Slide Over
        XCTAssertTrue(TabChrome.atBottom(regularWidth: true, pad: true, iOS18: false))     // iPadOS 17
        XCTAssertFalse(TabChrome.atBottom(regularWidth: true, pad: true, iOS18: true))
    }

    // MARK: PlayerShortcut

    func testFoliosKeys() {
        XCTAssertEqual(PlayerShortcut.claimed(mpvName: "SPACE"), .playPause)
        XCTAssertEqual(PlayerShortcut.claimed(mpvName: "LEFT"), .back)
        XCTAssertEqual(PlayerShortcut.claimed(mpvName: "RIGHT"), .forward)
        XCTAssertEqual(PlayerShortcut.claimed(mpvName: "UP"), .volumeUp)
        XCTAssertEqual(PlayerShortcut.claimed(mpvName: "DOWN"), .volumeDown)
        XCTAssertEqual(PlayerShortcut.claimed(mpvName: "f"), .fill)
        XCTAssertEqual(PlayerShortcut.claimed(mpvName: "n"), .next)
        XCTAssertEqual(PlayerShortcut.claimed(mpvName: "ESC"), .close)
    }

    /// Everything else is still mpv's (input.conf): other keys, and Folio's
    /// keys with a modifier.
    func testOtherKeysStayWithMpv() {
        for name in ["Shift+LEFT", "Shift+RIGHT", "Ctrl+LEFT", "Alt+UP", "Meta+f", "F", "N", "m", "s", "j", "9", "0", "ENTER", "TAB", "PGUP", "[", "]", "."] {
            XCTAssertNil(PlayerShortcut.claimed(mpvName: name), name)
        }
    }

    func testEveryShortcutHasItsOwnKeyAndName() {
        XCTAssertEqual(Set(PlayerShortcut.allCases.map(\.input)).count, PlayerShortcut.allCases.count)
        XCTAssertEqual(Set(PlayerShortcut.allCases.map(\.title)).count, PlayerShortcut.allCases.count)
        XCTAssertTrue(PlayerShortcut.allCases.allSatisfy { !$0.title.isEmpty })
    }

    func testVolumeSteps() {
        XCTAssertEqual(PlayerShortcut.volume(0.5, up: true), 0.5625)
        XCTAssertEqual(PlayerShortcut.volume(0.5, up: false), 0.4375)
        XCTAssertEqual(PlayerShortcut.volume(0.98, up: true), 1)
        XCTAssertEqual(PlayerShortcut.volume(0.03, up: false), 0)
    }

    func testEscClosesWhatIsOnTop() {
        typealias S = PlayerShortcut
        XCTAssertEqual(S.escapeTarget(locked: false, panel: false, console: false, card: false, sheet: false), .player)
        XCTAssertEqual(S.escapeTarget(locked: false, panel: true, console: false, card: true, sheet: false), .panel)
        XCTAssertEqual(S.escapeTarget(locked: false, panel: false, console: true, card: true, sheet: false), .console)
        XCTAssertEqual(S.escapeTarget(locked: false, panel: false, console: false, card: true, sheet: false), .card)
        XCTAssertEqual(S.escapeTarget(locked: false, panel: false, console: true, card: true, sheet: true), .sheet)
        // Locked: Esc doesn't close the player.
        XCTAssertEqual(S.escapeTarget(locked: true, panel: false, console: false, card: false, sheet: false), .nothing)
        XCTAssertEqual(S.escapeTarget(locked: true, panel: false, console: false, card: false, sheet: true), .sheet)
    }

    func testOnePressCountsOnce() {
        var d = PlayerShortcut.Dedupe()
        // The press, then the same key as a key command a moment later.
        XCTAssertTrue(d.shouldPerform(.forward, fromPress: true, at: 10))
        XCTAssertFalse(d.shouldPerform(.forward, fromPress: false, at: 10.004))
        // A held key's repeats, all from the key command.
        XCTAssertTrue(d.shouldPerform(.forward, fromPress: false, at: 10.5))
        XCTAssertTrue(d.shouldPerform(.forward, fromPress: false, at: 10.53))
        // Another key at once is another key.
        XCTAssertTrue(d.shouldPerform(.playPause, fromPress: true, at: 10.54))
        // Two quick presses of one key, both as presses.
        XCTAssertTrue(d.shouldPerform(.playPause, fromPress: true, at: 10.56))
    }
}
