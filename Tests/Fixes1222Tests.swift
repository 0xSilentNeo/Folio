import XCTest
@testable import Folio

/// The 4 Nov report's fixes (1.22.2).
@MainActor
final class Fixes1222Tests: XCTestCase {
    // MARK: Kids passcode: chosen once, kept

    private var savedPasscode: String?
    private var savedOn = false

    override func setUp() {
        super.setUp()
        savedPasscode = Keychain.get(KidsProfile.passcodeAccount)
        savedOn = UserDefaults.standard.bool(forKey: SettingsKey.kidsProfile)
    }

    override func tearDown() {
        Keychain.set(savedPasscode, for: KidsProfile.passcodeAccount)
        if savedOn { KidsProfile.shared.turnOn() } else { KidsProfile.shared.turnOff() }
        super.tearDown()
    }

    func testThePasscodeStaysAcrossTurningOnAndOff() {
        let kids = KidsProfile.shared
        Keychain.set(nil, for: KidsProfile.passcodeAccount)
        XCTAssertFalse(kids.hasPasscode)
        kids.turnOn()                                   // no passcode yet: stays off
        XCTAssertFalse(kids.isOn)
        kids.turnOn(passcode: "2580")
        XCTAssertTrue(kids.isOn)
        kids.turnOff()
        kids.turnOn()                                   // the second time: no new passcode asked for
        XCTAssertTrue(kids.isOn)
        XCTAssertEqual(kids.check("2580"), .right)
        kids.turnOff()
        kids.changePasscode(to: "1397")                 // changed while off
        XCTAssertEqual(kids.check("1397"), .right)
        if case .right = kids.check("2580") { XCTFail("the old passcode still works") }
        XCTAssertEqual(kids.check("1397"), .right)      // and the wrong try is forgotten
    }

    // MARK: Player side margins

    func testMarginsAreOneScale() {
        let w: CGFloat = 956                            // iPhone 17 Pro Max, landscape
        XCTAssertEqual(PlayerScreen.sideMargin(fullWidth: w, controlsWidth: 0.8), 78)
        XCTAssertEqual(PlayerScreen.sideMargin(fullWidth: w, controlsWidth: 0.9), 39)
        XCTAssertEqual(PlayerScreen.sideMargin(fullWidth: w, controlsWidth: 0.6), 156)
        XCTAssertEqual(PlayerScreen.sideMargin(fullWidth: w, controlsWidth: 1.0), 16)
        let steps = stride(from: 0.6, through: 1.0, by: 0.05).map { PlayerScreen.sideMargin(fullWidth: w, controlsWidth: $0) }
        XCTAssertEqual(steps, steps.sorted(by: >), "wider controls never mean bigger margins: \(steps)")
    }

    // MARK: OpenGL PiP frames

    func testPiPFramesKeepTheVideosSize() {
        XCTAssertTrue(PiPFrameSize.pick(videoW: 1920, videoH: 1080) == (1920, 1080))
        XCTAssertTrue(PiPFrameSize.pick(videoW: 1280, videoH: 720) == (1280, 720))
        XCTAssertTrue(PiPFrameSize.pick(videoW: 3840, videoH: 2160) == (1920, 1080))
        XCTAssertTrue(PiPFrameSize.pick(videoW: 3840, videoH: 1608) == (1920, 804))
    }

    // MARK: Episodes not out yet

    func testEpisodesNotOutYet() {
        let now = ISO8601DateFormatter().date(from: "2026-11-04T05:00:00Z")!
        func v(_ r: String?) -> MetaVideo { var x = MetaVideo(id: "tt1:2:1", title: "E", season: 2, episode: 1); x.released = r; return x }
        XCTAssertTrue(v("2027-01-01").airsLater(now: now))
        XCTAssertTrue(v("2026-11-28T08:00:00.000Z").airsLater(now: now))
        XCTAssertFalse(v("2025-11-07").airsLater(now: now))
        XCTAssertFalse(v("2026-11-04T04:00:00Z").airsLater(now: now))
        XCTAssertFalse(v(nil).airsLater(now: now))
        XCTAssertFalse(v("soon").airsLater(now: now))
    }

    // MARK: Shows that have ended

    func testEndedShows() {
        var m = MetaItem(id: "tt0944947", type: "series", name: "Game of Thrones", poster: nil, description: nil, releaseInfo: "2011", imdbRating: nil, genres: nil)
        XCTAssertFalse(m.hasEnded)
        m.endYear = 2019
        XCTAssertTrue(m.hasEnded)
        m.endYear = nil
        m.releaseInfo = "2011–2019"
        XCTAssertTrue(m.hasEnded)
        m.releaseInfo = "2025–"
        XCTAssertFalse(m.hasEnded)
        // Kept in the saved copy.
        m.endYear = 2019
        let back = try? JSONDecoder().decode(MetaItem.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back?.endYear, 2019)
    }

    // MARK: The signing profile's App Groups

    func testProfileGroups() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Entitlements</key><dict>
        <key>com.apple.security.application-groups</key><array><string>group.com.example.shared</string></array>
        </dict></dict></plist>
        """
        var data = Data([0x30, 0x82, 0x10, 0x00])      // the signature's bytes around it
        data.append(Data(plist.utf8))
        data.append(Data([0xA0, 0x82, 0x01]))
        XCTAssertEqual(FolioGroup.profileGroups(fromProfile: data), ["group.com.example.shared"])
        XCTAssertEqual(FolioGroup.profileGroups(fromProfile: Data([1, 2, 3])), [])
    }
}
