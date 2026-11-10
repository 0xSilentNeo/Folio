import XCTest
import UIKit
@testable import Folio

/// 1.28.2: PiP and Fill, subtitles when zoomed, the share sheet without an
/// App Group, clear glass widgets.
@MainActor
final class Fixes1282Tests: XCTestCase {
    private let screen = CGSize(width: 956, height: 440)      // iPhone 17 Pro Max in landscape, points

    // MARK: Subtitles when the picture is zoomed

    /// A 16:9 film filled on the 2.17:1 screen loses its top and bottom,
    /// not its sides: text keeps mpv's own side margin.
    func testFillCroppingTopAndBottomKeepsTheSideMargin() {
        let video = CGSize(width: 3840, height: 2160)
        let ratio: CGFloat = 956 / (440 * 16 / 9)
        XCTAssertEqual(PlayerModel.subtitleMarginX(scale: ratio, video: video, view: screen), 25)
        XCTAssertEqual(PlayerModel.subtitleMarginX(scale: 1, video: video, view: screen), 25)
    }

    /// A 2.39:1 film filled on the same screen loses its sides: libass wraps
    /// within what's on screen, not the whole frame's width.
    func testFillCroppingTheSidesWrapsTextWithinTheScreen() {
        let video = CGSize(width: 3840, height: 1606)
        let fitW = min(screen.width, screen.height * video.width / video.height)   // 956: Fit fills the width
        let fill = (screen.height * video.width / video.height) / fitW             // ~1.1
        let m = PlayerModel.subtitleMarginX(scale: fill, video: video, view: screen)
        // 4.5% of the frame's width off each side, in mpv's 720-high units, plus its own 25.
        XCTAssertEqual(m, 25 + Int(((1 - 1 / fill) / 2 * (video.width / video.height) * 720).rounded()))
        XCTAssertGreaterThan(m, 90)
        XCTAssertEqual(PlayerModel.subtitleMarginX(scale: 1, video: video, view: screen), 25, "Fit: nothing off the sides")
        XCTAssertEqual(PlayerModel.subtitleMarginX(scale: 6, video: video, view: screen), 300, "capped at mpv's limit")
        // mpv.conf's own margin is kept as the base.
        XCTAssertEqual(PlayerModel.subtitleMarginX(scale: 1, video: video, view: screen, base: 40), 40)
        XCTAssertEqual(PlayerModel.subtitleMarginX(scale: fill, video: video, view: screen, base: 40), m + 15)
    }

    /// The video layer's scale is the whole framing now (Fill, a pinch, a
    /// step of the zoom): the same placement as Fill gave before.
    func testTheLayersScaleFramesSubtitlesAsFillDid() {
        let video = CGSize(width: 3840, height: 2160)
        let ratio: CGFloat = 956 / (440 * 16 / 9)
        let byScale = PlayerModel.subtitleFraming(gl: true, fill: false, fillRatio: 1, pinch: ratio, video: video, view: screen)
        let byFill = PlayerModel.subtitleFraming(gl: true, fill: true, fillRatio: ratio, pinch: 1, video: video, view: screen)
        XCTAssertEqual(byScale.scale, byFill.scale, accuracy: 0.0001)
        XCTAssertEqual(byScale.visible, byFill.visible, accuracy: 0.0001)
        // Halfway through the zoom: part of the way up.
        let half = PlayerModel.subtitleFraming(gl: true, fill: false, fillRatio: 1, pinch: (1 + ratio) / 2, video: video, view: screen)
        let p = PlayerModel.subtitlePlacement(userPos: 100, userScale: 1, framing: half, follow: true, gl: true)
        XCTAssertTrue((91...100).contains(p.pos))
    }

    // MARK: The share sheet without an App Group

    /// A link the extension left before 1.28.2 still reads (no bookmark).
    func testAnOlderSharedLinkStillDecodes() throws {
        let old = #"{"url":"https://example.com/a.mkv","at":0,"id":"x"}"#
        let link = try JSONDecoder().decode(SharedPlayLink.self, from: Data(old.utf8))
        XCTAssertNil(link.bookmark)
        XCTAssertEqual(link.url, "https://example.com/a.mkv")
    }

    /// A video passed by bookmark has no link and no file in the App Group,
    /// and is accepted; an empty bookmark isn't.
    func testAVideoByBookmarkIsAccepted() throws {
        let now = Date()
        let byMark = SharedPlayLink(url: "", at: now, id: "a", bookmark: Data([1, 2, 3]))
        XCTAssertTrue(SharedPlayLink.accepts(byMark, maxAge: 120, now: now))
        let empty = SharedPlayLink(url: "", at: now, id: "b", bookmark: Data())
        XCTAssertFalse(SharedPlayLink.accepts(empty, maxAge: 120, now: now))
        let late = SharedPlayLink(url: "", at: now.addingTimeInterval(-600), id: "c", bookmark: Data([1]))
        XCTAssertFalse(SharedPlayLink.accepts(late, maxAge: 120, now: now))
        // Round trip, as through the Keychain.
        let back = try JSONDecoder().decode(SharedPlayLink.self, from: JSONEncoder().encode(byMark))
        XCTAssertEqual(back, byMark)
    }

    func testTheImportLinkOpensAddFiles() {
        XCTAssertEqual(SharedPlayLink.importURL.scheme, "folio")
        XCTAssertEqual(SharedPlayLink.importURL.host, "import")
    }

    /// A bookmark to nothing doesn't open (Add files instead).
    func testABrokenBookmarkDoesntResolve() {
        XCTAssertNil(SharedInbox.resolve(Data([0, 1, 2, 3])))
    }

    // MARK: Less work on the way back

    /// Tracking alerts are left alone on return only when the plan is the
    /// same: same alerts, same minute, same words.
    func testTheAlertPlanSignatureSeesEveryChange() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let a = PlannedAlert(id: "airing.x.1", showID: "x", fire: at, title: "MobLand", body: "S2 · E9 is out")
        XCTAssertEqual(AiringNotifications.signature([a]), AiringNotifications.signature([a]))
        var later = a; later.fire = at.addingTimeInterval(120)
        var reworded = a; reworded.body = "S2 · E9 is out now"
        XCTAssertNotEqual(AiringNotifications.signature([a]), AiringNotifications.signature([later]))
        XCTAssertNotEqual(AiringNotifications.signature([a]), AiringNotifications.signature([reworded]))
        XCTAssertNotEqual(AiringNotifications.signature([a]), AiringNotifications.signature([]))
        // Seconds don't matter: planned again a moment later, the same.
        var moment = a; moment.fire = at.addingTimeInterval(0.4)
        XCTAssertEqual(AiringNotifications.signature([a]), AiringNotifications.signature([moment]))
    }

    // MARK: Clear glass widgets

    /// One look in light and dark mode; iOS's Clear and Tinted as before.
    func testOneGlassLookInLightAndDark() {
        XCTAssertEqual(WidgetPalette(scheme: .light, mode: .fullColor).kind, .glass)
        XCTAssertEqual(WidgetPalette(scheme: .dark, mode: .fullColor).kind, .glass)
        XCTAssertEqual(WidgetPalette(scheme: .dark, mode: .accented).kind, .accented)
        let light = WidgetPalette(scheme: .light, mode: .fullColor), dark = WidgetPalette(scheme: .dark, mode: .fullColor)
        XCTAssertEqual(light.ink, dark.ink)
        XCTAssertEqual(light.pill, dark.pill)
    }

    /// The veil is as clear as the picture allows: light over a dark
    /// picture, deeper over a bright one, never past 0.44.
    func testTheVeilFollowsThePicturesBrightness() {
        func plain(_ c: UIColor) -> UIImage {
            let f = UIGraphicsImageRendererFormat(); f.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: f).image { ctx in
                c.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
        }
        let black = WidgetImages.veil(for: plain(.black)), white = WidgetImages.veil(for: plain(.white))
        let grey = WidgetImages.veil(for: plain(UIColor(white: 0.5, alpha: 1)))
        XCTAssertEqual(black, 0.14, accuracy: 0.01)
        XCTAssertEqual(white, 0.44, accuracy: 0.01)
        XCTAssertTrue(black < grey && grey < white)
    }
}
