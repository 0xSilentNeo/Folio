import XCTest
@testable import Folio

/// 1.27.0's fixes that can be checked without the UI.
@MainActor
final class Fixes1270Tests: XCTestCase {
    // MARK: Audio output note

    func testChannelsInMPVLayouts() {
        XCTAssertEqual(AudioRoute.channels(in: "mono"), 1)
        XCTAssertEqual(AudioRoute.channels(in: "stereo"), 2)
        XCTAssertEqual(AudioRoute.channels(in: "5.1(side)"), 6)
        XCTAssertEqual(AudioRoute.channels(in: "7.1"), 8)
        XCTAssertEqual(AudioRoute.channels(in: "4.0"), 4)
        XCTAssertNil(AudioRoute.channels(in: "quad"))
    }

    /// TrueHD 5.1 on the iPhone's speaker: says why it's stereo (9 Nov report).
    func testMixdownOnTheSpeakerSaysWhy() {
        let speaker = AudioRoute(name: "iPhone speaker", maxChannels: 2, spatial: false)
        XCTAssertEqual(speaker.output(layout: "stereo"), "Stereo · iPhone speaker")
        let why = speaker.mixdown(track: 6, output: "stereo", surroundOn: true)
        XCTAssertEqual(why, "5.1 mixed down to stereo: the iPhone speaker takes 2 channels. AirPlay or HDMI to a surround system gets all 6.")
    }

    func testNoMixdownNoteWhenAllChannelsPlay() {
        let hdmi = AudioRoute(name: "HDMI", maxChannels: 8, spatial: false)
        XCTAssertNil(hdmi.mixdown(track: 6, output: "5.1(side)", surroundOn: true))
        XCTAssertNil(hdmi.mixdown(track: 2, output: "stereo", surroundOn: true))
        XCTAssertNil(hdmi.mixdown(track: nil, output: "stereo", surroundOn: true))
    }

    func testMixdownWithSpatialAudioOffPointsToTheSetting() {
        let hdmi = AudioRoute(name: "HDMI", maxChannels: 8, spatial: false)
        XCTAssertEqual(hdmi.mixdown(track: 8, output: "stereo", surroundOn: false),
                       "7.1 mixed down to stereo: Spatial Audio is off in Audio & Subtitles.")
    }

    // MARK: Addons

    private func addon(_ json: String) throws -> InstalledAddon {
        try JSONDecoder().decode(InstalledAddon.self, from: Data(json.utf8))
    }

    private let manifest = #"{"id":"org.test","name":"Test","version":"1.0","resources":["stream"],"types":["movie"],"catalogs":[{"type":"movie","id":"top","name":"Popular"},{"type":"movie","id":"find","extra":[{"name":"search","isRequired":true}]}]}"#

    /// Lists saved before the switch read as on; off is saved and read back.
    func testAddonSwitchSurvivesSaving() throws {
        var a = try addon(#"{"transportURL":"https://a.test/manifest.json","manifest":\#(manifest)}"#)
        XCTAssertTrue(a.enabled)
        a.enabled = false
        let back = try JSONDecoder().decode(InstalledAddon.self, from: JSONEncoder().encode(a))
        XCTAssertFalse(back.enabled)
        a.enabled = true
        XCTAssertNil(a.isOff)
    }

    /// Discover shows catalogs that need no search words.
    func testOnlyBrowsableCatalogsGoToDiscover() throws {
        let a = try addon(#"{"transportURL":"https://a.test/manifest.json","manifest":\#(manifest)}"#)
        XCTAssertEqual(a.manifest.catalogs.filter(\.isBrowsable).map(\.id), ["top"])
        XCTAssertEqual(CatalogRow.title(a.manifest.catalogs[0]), "Popular · Movies")
    }

    func testAddonAnswerLine() {
        let now = Date()
        XCTAssertEqual(AddonHealth.describe(.init(ms: 420, ok: true, at: now, what: "streams")), "Streams in 420 ms")
        XCTAssertEqual(AddonHealth.describe(.init(ms: 2400, ok: true, at: now, what: "catalog")), "Catalog in 2.4 s")
        XCTAssertEqual(AddonHealth.describe(.init(ms: 20000, ok: false, at: now, what: "streams")), "Streams failed after 20.0 s")
    }

    // MARK: Play in Folio

    func testOnlyNetworkStreamsArePlayable() {
        XCTAssertTrue(SharedPlayLink.isPlayable(URL(string: "https://example.com/a.mkv")!))
        XCTAssertTrue(SharedPlayLink.isPlayable(URL(string: "smb://nas/share/a.mkv")!))
        XCTAssertFalse(SharedPlayLink.isPlayable(URL(string: "file:///private/a.mkv")!))
        XCTAssertFalse(SharedPlayLink.isPlayable(URL(string: "edl://a;b")!))
        XCTAssertFalse(SharedPlayLink.isPlayable(URL(string: "https:///nohost")!))
    }

    /// Messages and Notes share text: the first playable link in it.
    func testFirstLinkInSharedText() {
        XCTAssertEqual(SharedPlayLink.firstLink(in: "  https://cdn.test/v.m3u8 ")?.absoluteString, "https://cdn.test/v.m3u8")
        XCTAssertEqual(SharedPlayLink.firstLink(in: "watch this https://cdn.test/v.mp4 tonight")?.absoluteString, "https://cdn.test/v.mp4")
        XCTAssertNil(SharedPlayLink.firstLink(in: "no link here"))
    }

    /// A link left by the extension plays only while fresh.
    func testSharedLinkGoesStale() {
        let now = Date()
        let link = SharedPlayLink(url: "https://cdn.test/v.mp4", title: nil, at: now.addingTimeInterval(-100), id: "x")
        XCTAssertTrue(SharedPlayLink.accepts(link, maxAge: 120, now: now))
        XCTAssertFalse(SharedPlayLink.accepts(link, maxAge: 60, now: now))
        var bad = link
        bad.url = "lavfi://sine"
        XCTAssertFalse(SharedPlayLink.accepts(bad, maxAge: 120, now: now))
        XCTAssertEqual(link.openURL?.absoluteString, "folio://shared?id=x")
    }

    // MARK: First run

    func testWelcomeOnlyOnAFirstInstall() {
        XCTAssertTrue(FirstRun.isFirstInstall(lastShown: nil, usedBefore: false))
        XCTAssertFalse(FirstRun.isFirstInstall(lastShown: nil, usedBefore: true))
        XCTAssertFalse(FirstRun.isFirstInstall(lastShown: "1.26.3", usedBefore: false))
    }
}
