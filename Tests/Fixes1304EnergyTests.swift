import XCTest
import UIKit
import AVKit
@testable import Folio

/// 1.30.4: what a video costs while it plays (the 14 Nov report: 41% of the
/// battery in three hours of a 1080p remux over 5G).
final class Fixes1304EnergyTests: XCTestCase {
    private let phone = (2868, 1320)        // a 17 Pro Max in landscape, in pixels

    // MARK: The Metal renderer's frame size

    /// 1080p shown at 1.22×: frames of its own 1920×1080, which the video
    /// layer scales, in Efficient and Balanced. It was 2346×1320, scaled up
    /// by mpv in two passes (Balanced: 3.1 of its 3.8 ms a frame).
    func testA1080pVideoOnAPhoneIsDrawnAtItsOwnSize() {
        for mode in [PictureMode.efficient, .balanced] {
            let s = MetalFrameRenderer.frameSize(view: phone, video: (1920, 1080), pip: nil,
                                                 nativeBelow: mode.nativeFramesBelow(custom: false))
            XCTAssertTrue(s == (1920, 1080), "\(mode.rawValue): \(s)")
        }
    }

    /// Enhanced, and anything that needs mpv to scale (Anime4K, your
    /// shaders, mpv.conf's scalers): as before.
    func testEnhancedAndCustomScalingKeepMpvsScaling() {
        let enhanced = MetalFrameRenderer.frameSize(view: phone, video: (1920, 1080), pip: nil,
                                                    nativeBelow: PictureMode.enhanced.nativeFramesBelow(custom: false))
        XCTAssertTrue(enhanced == (2346, 1320), "\(enhanced)")
        for mode in PictureMode.allCases {
            XCTAssertEqual(mode.nativeFramesBelow(custom: true), 0, mode.rawValue)
        }
    }

    /// 720p at 1.83×: mpv still scales it, so Balanced's sharper scaler
    /// shows and the subtitles are drawn at the screen's size.
    func testA720pVideoIsStillScaledByMpv() {
        for mode in [PictureMode.efficient, .balanced] {
            let s = MetalFrameRenderer.frameSize(view: phone, video: (1280, 720), pip: nil,
                                                 nativeBelow: mode.nativeFramesBelow(custom: false))
            XCTAssertTrue(s == (2346, 1320), "\(mode.rawValue): \(s)")
        }
    }

    /// An 11" iPad (2420×1668) shows 1080p at 1.26×: past Balanced's limit
    /// (mpv's catmull_rom, 2420×1360), within Efficient's (the video's size).
    func testBalancedKeepsItsScalerSoonerThanEfficient() {
        let ipad = (2420, 1668)
        let balanced = MetalFrameRenderer.frameSize(view: ipad, video: (1920, 1080), pip: nil,
                                                    nativeBelow: PictureMode.balanced.nativeFramesBelow(custom: false))
        XCTAssertTrue(balanced == (2420, 1360), "\(balanced)")
        let efficient = MetalFrameRenderer.frameSize(view: ipad, video: (1920, 1080), pip: nil,
                                                     nativeBelow: PictureMode.efficient.nativeFramesBelow(custom: false))
        XCTAssertTrue(efficient == (1920, 1080), "\(efficient)")
    }

    /// A scope film keeps its exact size, an odd height too: rounded to
    /// 802 lines, mpv would scale 803 to 802 every frame.
    func testScopeFilmsKeepTheirExactSize() {
        XCTAssertTrue(MetalFrameRenderer.frameSize(view: phone, video: (1920, 803), pip: nil, nativeBelow: 1.5) == (1920, 803))
        XCTAssertTrue(MetalFrameRenderer.frameSize(view: phone, video: (1920, 800), pip: nil, nativeBelow: 1.5) == (1920, 800))
    }

    /// Bigger than the view (4K): fitted down by mpv as before, and the
    /// frames are smaller than the video's.
    func testLargerVideosAreStillFittedDown() {
        let s = MetalFrameRenderer.frameSize(view: phone, video: (3840, 2160), pip: nil, nativeBelow: 1.5)
        XCTAssertTrue(s == (2346, 1320), "\(s)")
    }

    /// PiP's size still wins; with no limit given, the old sizes.
    func testPiPsSizeAndTheOldDefault() {
        XCTAssertTrue(MetalFrameRenderer.frameSize(view: phone, video: (1920, 1080), pip: (960, 540), nativeBelow: 1.5) == (960, 540))
        XCTAssertTrue(MetalFrameRenderer.frameSize(view: phone, video: (1920, 1080), pip: nil) == (2346, 1320))
        XCTAssertTrue(MetalFrameRenderer.frameSize(view: (1320, 2868), video: nil, pip: nil, nativeBelow: 1.5) == (1320, 2868))
    }

    // MARK: mpv.conf's own scaling

    func testMpvConfScalersAndShadersAreSeen() {
        XCTAssertTrue(PictureMode.confSetsScaling("scale=ewa_lanczossharp\n"))
        XCTAssertTrue(PictureMode.confSetsScaling("  --glsl-shaders=~~/shaders/FSRCNNX.glsl"))
        XCTAssertTrue(PictureMode.confSetsScaling("[anime]\nprofile = high-quality"))
        XCTAssertTrue(PictureMode.confSetsScaling("cscale=lanczos # chroma"))
    }

    func testCommentsAndOtherOptionsAreNotScaling() {
        XCTAssertFalse(PictureMode.confSetsScaling(""))
        XCTAssertFalse(PictureMode.confSetsScaling("#scale=ewa_lanczossharp\n  # profile=high-quality\nsub-auto=fuzzy\nprofile-desc=Anime\ndscale-radius=2"))
    }

    /// The mpv.conf Folio ships has every scaler commented out.
    func testTheBundledMpvConfLeavesScalingToFolio() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "mpv.conf", withExtension: nil, subdirectory: "defaults"))
        XCTAssertFalse(PictureMode.confSetsScaling(try String(contentsOf: url, encoding: .utf8)))
    }

    // MARK: Bursts or a trickle

    /// 26.4 Mb/s arriving in every 2-s slot: the radio never rests.
    func testATrickleHasDataInEverySlot() {
        let line = NetSlots.line(cell: Array(repeating: 6_600_000, count: 15), wifi: [], seconds: 30)
        XCTAssertEqual(line, "net cellular 26.4 Mb/s (data in 15 of 15 2-s slots)")
    }

    /// The same bytes in three bursts: data in 3 of the 15 slots.
    func testBurstsHaveDataInAFewSlots() {
        let cell: [UInt64] = [33_000_000, 33_000_000, 33_000_000] + Array(repeating: 1_000, count: 12)
        XCTAssertEqual(NetSlots.line(cell: cell, wifi: [], seconds: 30), "net cellular 26.4 Mb/s (data in 3 of 15 2-s slots)")
    }

    /// Nothing worth saying: no text; a quiet radio is left out.
    func testQuietRadiosAreLeftOut() {
        XCTAssertNil(NetSlots.line(cell: [0, 0, 0], wifi: [500, 0, 900], seconds: 6))
        XCTAssertNil(NetSlots.line(cell: [], wifi: [], seconds: 0))
        let wifiOnly = NetSlots.line(cell: [10, 20], wifi: [4_000_000, 0], seconds: 4)
        XCTAssertEqual(wifiOnly, "net Wi-Fi 8.0 Mb/s (data in 1 of 2 2-s slots)")
    }

    func testTheInterfaceCountersCanBeRead() {
        let a = NetSlots.counters(), b = NetSlots.counters()
        // 32-bit counters that wrap: a difference is always defined.
        _ = b.cell &- a.cell
        _ = b.wifi &- a.wifi
    }

    // MARK: The AirPlay button

    @MainActor
    func testTheRoutePickersButtonIsFoundInside() {
        let root = UIView(), inner = UIView(), button = UIButton(type: .system)
        root.addSubview(inner)
        inner.addSubview(button)
        XCTAssertTrue(RoutePickerLauncher.control(in: root) === button)
        // No button: any control.
        let plain = UIView(), slider = UISlider()
        plain.addSubview(slider)
        XCTAssertTrue(RoutePickerLauncher.control(in: plain) === slider)
        XCTAssertNil(RoutePickerLauncher.control(in: UIView()))
    }

    /// What this iOS's own picker view has inside: without a control,
    /// Folio's button hands over to iOS's (RoutePickerLauncher.giveUp).
    @MainActor
    func testThisIOSsRoutePickerHasAControl() throws {
        let picker = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.layoutIfNeeded()
        try XCTSkipIf(RoutePickerLauncher.control(in: picker) == nil,
                      "AVRoutePickerView has no control inside on iOS \(UIDevice.current.systemVersion): the system button is used")
    }
}
