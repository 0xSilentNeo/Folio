import XCTest
@testable import Folio

/// Per-show memory (1.20.3, 2 Nov): tracks found by what they are, show
/// keys, and the store's cap, merging and file.
@MainActor
final class ShowMemoryTests: XCTestCase {
    private func t(_ id: Int, _ type: String, lang: String?, title: String? = nil, codec: String? = nil, channels: Int? = nil,
                   selected: Bool = false, external: Bool = false, forced: Bool = false, sdh: Bool = false) -> MediaTrack {
        MediaTrack(id: id, type: type, title: title, lang: lang, codec: codec, profile: nil, selected: selected, external: external,
                   isDefault: false, channels: nil, channelCount: channels, dvProfile: nil, width: nil, height: nil,
                   forced: forced, hearingImpaired: sdh)
    }

    // MARK: Tracks

    /// The next episode numbers its tracks the other way round: found by language, not number.
    func testAudioByLanguageNotIndex() {
        let e1 = [t(1, "audio", lang: "eng", title: "Surround", codec: "eac3", channels: 6), t(2, "audio", lang: "jpn", title: "Stereo", codec: "aac", channels: 2)]
        let choice = AudioChoice(e1[1])
        let e2 = [t(1, "audio", lang: "ja", title: "Stereo", codec: "aac", channels: 2), t(2, "audio", lang: "en", title: "Surround", codec: "eac3", channels: 6)]
        XCTAssertEqual(TrackMatch.audio(choice, among: e2)?.id, 1)
    }

    func testAudioPrefersSameTitleThenCodec() {
        let choice = AudioChoice(lang: "eng", title: "Atmos", codec: "truehd", channels: 8)
        let tracks = [t(1, "audio", lang: "eng", title: "Stereo", codec: "aac", channels: 2),
                      t(2, "audio", lang: "eng", title: "5.1", codec: "truehd", channels: 6),
                      t(3, "audio", lang: "eng", title: "Atmos", codec: "eac3", channels: 8)]
        XCTAssertEqual(TrackMatch.audio(choice, among: tracks)?.id, 3)
        let noTitle = AudioChoice(lang: "eng", title: nil, codec: "truehd", channels: 8)
        XCTAssertEqual(TrackMatch.audio(noTitle, among: tracks)?.id, 2)
    }

    func testAudioCommentaryOnlyForCommentary() {
        let tracks = [t(1, "audio", lang: "eng", title: "Director's Commentary", codec: "ac3"), t(2, "audio", lang: "eng", title: nil, codec: "eac3")]
        XCTAssertEqual(TrackMatch.audio(AudioChoice(lang: "eng", title: nil, codec: "ac3", channels: nil), among: tracks)?.id, 2)
        XCTAssertEqual(TrackMatch.audio(AudioChoice(tracks[0]), among: tracks)?.id, 1)
    }

    func testAudioMissingLanguageGivesNothing() {
        let tracks = [t(1, "audio", lang: "eng"), t(2, "audio", lang: "fre")]
        XCTAssertNil(TrackMatch.audio(AudioChoice(lang: "jpn", title: nil, codec: nil, channels: nil), among: tracks))
        // Untagged: only a recognisably same track.
        let untagged = [t(1, "audio", lang: nil, title: "Main", codec: "aac"), t(2, "audio", lang: nil, title: "Other", codec: "opus")]
        XCTAssertEqual(TrackMatch.audio(AudioChoice(lang: nil, title: "Other", codec: nil, channels: nil), among: untagged)?.id, 2)
        XCTAssertNil(TrackMatch.audio(AudioChoice(lang: nil, title: nil, codec: "flac", channels: nil), among: untagged))
    }

    /// A full English track was chosen: never the forced one, whatever its number.
    func testSubtitleForcedAware() {
        let tracks = [t(3, "sub", lang: "eng", title: "Forced", forced: true),
                      t(4, "sub", lang: "eng", title: "Full"),
                      t(5, "sub", lang: "eng", title: "SDH")]
        XCTAssertEqual(TrackMatch.subtitle(SubtitleChoice(lang: "en", title: "English"), among: tracks)?.id, 4)
        XCTAssertEqual(TrackMatch.subtitle(SubtitleChoice(lang: "en", forced: true), among: tracks)?.id, 3)
        XCTAssertEqual(TrackMatch.subtitle(SubtitleChoice(lang: "en", sdh: true), among: tracks)?.id, 5)
        // Forced by its title alone counts too.
        XCTAssertTrue(TrackMatch.isForced(t(1, "sub", lang: "eng", title: "English [Forced]")))
        XCTAssertTrue(TrackMatch.isSDH(t(1, "sub", lang: "eng", title: "English (SDH)")))
        XCTAssertFalse(TrackMatch.isSDH(t(1, "sub", lang: "eng", title: "English")))
        // Only a forced track in that language: nothing (it would leave most lines untranslated).
        XCTAssertNil(TrackMatch.subtitle(SubtitleChoice(lang: "en"), among: [tracks[0]]))
    }

    func testSubtitlePrefersExternalWhenExternalWasChosen() {
        let tracks = [t(2, "sub", lang: "eng", title: "English"), t(7, "sub", lang: "en", title: "eng", external: true)]
        XCTAssertEqual(TrackMatch.subtitle(SubtitleChoice(lang: "eng", title: "English · OpenSubtitles 1", external: true), among: tracks)?.id, 7)
        XCTAssertEqual(TrackMatch.subtitle(SubtitleChoice(lang: "eng", title: "English"), among: tracks)?.id, 2)
        XCTAssertNil(TrackMatch.subtitle(.turnedOff, among: tracks))
    }

    func testLanguageSpellings() {
        XCTAssertEqual(TrackMatch.language("eng"), "en")
        XCTAssertEqual(TrackMatch.language("EN"), "en")
        XCTAssertEqual(TrackMatch.language("en-US"), "en")
        XCTAssertEqual(TrackMatch.language("ger"), "de")
        XCTAssertEqual(TrackMatch.language("deu"), "de")
        XCTAssertEqual(TrackMatch.language("fre"), "fr")
        XCTAssertEqual(TrackMatch.language("pob"), "pt-br")
        XCTAssertEqual(TrackMatch.language("pt-BR"), "pt-br")
        XCTAssertEqual(TrackMatch.language("por"), "pt")
        XCTAssertEqual(TrackMatch.language("nob"), "no")
        XCTAssertNil(TrackMatch.language("und"))
        XCTAssertNil(TrackMatch.language(""))
        XCTAssertNil(TrackMatch.language(nil))
    }

    // MARK: Keys

    func testKeysForEpisodesOfOneShow() {
        let e1 = MediaItem(url: "/x/Media/The.Office.US.S02E01.1080p.WEB.mkv", title: "", source: .local)
        let e2 = MediaItem(url: "/x/Media/The Office US S02E07 720p.mkv", title: "", source: .local)
        let k1 = ShowKey.make(item: e1, imdb: nil), k2 = ShowKey.make(item: e2, imdb: nil)
        XCTAssertNotNil(k1)
        XCTAssertEqual(k1?.keys.last, k2?.keys.last)
        XCTAssertTrue(k1!.keys.allSatisfy { $0.hasPrefix("show:") })
        // With an IMDb id it comes first.
        XCTAssertEqual(ShowKey.make(item: e1, imdb: "tt0386676")?.keys.first, "imdb:tt0386676")
    }

    func testFilmKeyHasYear() {
        let f = MediaItem(url: "/x/Media/Dune.Part.Two.2024.2160p.mkv", title: "", source: .local)
        let k = ShowKey.make(item: f, imdb: nil)
        XCTAssertEqual(k?.keys, ["film:dune part two|2024"])
    }

    func testAddonKeys() {
        var ep = MediaItem(url: "https://x/y.mkv", title: "Frieren", subtitle: "S1 · E5", source: .addon(name: "Torrentio"))
        ep.historyKey = "addon:kitsu:46474:5"
        ep.addonRef = "series|kitsu:46474|kitsu:46474:5"
        XCTAssertEqual(ShowKey.make(item: ep, imdb: nil)?.keys, ["addon:kitsu:46474"])
        ep.addonRef = "series|tt22248376|tt22248376:1:5"
        XCTAssertEqual(ShowKey.make(item: ep, imdb: "tt22248376")?.keys, ["imdb:tt22248376"])
        XCTAssertEqual(ShowKey.make(item: ep, imdb: nil), nil)
    }

    // MARK: Store

    private func key(_ k: String...) -> ShowKey { ShowKey(keys: k, name: k.first ?? "") }

    func testStoreRemembersAndFinds() {
        let s = ShowMemoryStore(url: nil)
        s.update(key("show:lab show")) { $0.settings.audio = AudioChoice(lang: "jpn", title: nil, codec: nil, channels: nil) }
        XCTAssertEqual(s.entry(for: ["show:lab show|2020", "show:lab show"])?.settings.audio?.lang, "jpn")
        XCTAssertNil(s.entry(for: ["show:other"]))
    }

    /// The oldest show goes once there are more than the cap.
    func testStoreCapDropsOldest() {
        let s = ShowMemoryStore(url: nil, limit: 3)
        for i in 1...4 { s.update(key("show:\(i)")) { $0.settings.subDelay = Double(i) } }
        XCTAssertEqual(s.entries.count, 3)
        XCTAssertNil(s.entry(for: ["show:1"]))
        XCTAssertNotNil(s.entry(for: ["show:4"]))
        // Touching a show makes it recent again.
        s.update(key("show:2")) { $0.settings.panscan = 1 }
        s.update(key("show:5")) { $0.settings.panscan = 0 }
        XCTAssertNotNil(s.entry(for: ["show:2"]))
        XCTAssertNil(s.entry(for: ["show:3"]))
    }

    /// A file's name was all there was; later its IMDb id is known too: one entry.
    func testStoreMergesKeys() {
        let s = ShowMemoryStore(url: nil)
        s.update(key("show:lab show")) { $0.settings.subDelay = 0.5 }
        s.update(key("imdb:tt1", "show:lab show")) { $0.settings.audioDelay = -0.1 }
        XCTAssertEqual(s.entries.count, 1)
        let e = s.entry(for: ["imdb:tt1"])
        XCTAssertEqual(e?.settings.subDelay, 0.5)
        XCTAssertEqual(e?.settings.audioDelay, -0.1)
        // Two entries the keys both point to become one.
        s.update(key("imdb:tt2")) { $0.settings.panscan = 1 }
        s.update(key("show:other")) { $0.settings.anime4k = "a" }
        s.update(key("imdb:tt2", "show:other")) { _ in }
        XCTAssertEqual(s.entries.count, 2)
        XCTAssertEqual(s.entry(for: ["show:other"])?.settings.panscan, 1)
        XCTAssertEqual(s.entry(for: ["imdb:tt2"])?.settings.anime4k, "a")
    }

    func testFileDelayWinsOverShowDelay() {
        let s = ShowMemoryStore(url: nil, fileLimit: 2)
        let k = key("show:lab")
        s.setSubDelay(0.3, file: "a", for: k)
        s.setSubDelay(-0.2, file: "b", for: k)
        let e = s.entry(for: ["show:lab"])!
        XCTAssertEqual(e.subDelay(file: "a"), 0.3)
        XCTAssertEqual(e.subDelay(file: "b"), -0.2)
        XCTAssertNil(e.subDelay(file: "c"))
        XCTAssertEqual(e.settings.subDelay, -0.2)        // the show's: the latest
        s.setSubDelay(0.1, file: "c", for: k)
        XCTAssertNil(s.entry(for: ["show:lab"])!.subDelay(file: "a"))   // capped per show
    }

    func testForget() {
        let s = ShowMemoryStore(url: nil)
        s.update(key("show:a")) { $0.settings.panscan = 1 }
        s.update(key("show:b")) { $0.settings.panscan = 1 }
        s.forget(s.entry(for: ["show:a"])!.id)
        XCTAssertNil(s.entry(for: ["show:a"]))
        XCTAssertNotNil(s.entry(for: ["show:b"]))
        s.forgetAll()
        XCTAssertTrue(s.entries.isEmpty)
    }

    /// Written as JSON and read back by a new store.
    func testStoreFileRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("show-memory-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let s = ShowMemoryStore(url: url)
        s.update(key("imdb:tt9", "show:x")) {
            $0.settings.subtitle = SubtitleChoice(lang: "eng", title: "Full", forced: false, sdh: true)
            $0.settings.anime4k = "aa"
        }
        s.setSubDelay(1.25, file: "file-1", for: key("imdb:tt9"))
        s.flush()
        let data = try Data(contentsOf: url)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let again = ShowMemoryStore(url: url)
        let e = again.entry(for: ["show:x"])
        XCTAssertEqual(e?.settings.subtitle?.sdh, true)
        XCTAssertEqual(e?.settings.anime4k, "aa")
        XCTAssertEqual(e?.subDelay(file: "file-1"), 1.25)
    }

    /// 1.22.0's speed, always-skip and second subtitle: settings saved by
    /// 1.20.3 still read, and two entries merge the new fields too.
    func testNewFieldsReadOldSettingsAndMerge() throws {
        let old = try JSONDecoder().decode(ShowSettings.self, from: Data(#"{"subDelay":0.5,"anime4k":"modeA"}"#.utf8))
        XCTAssertEqual(old.subDelay, 0.5)
        XCTAssertNil(old.speed)
        XCTAssertNil(old.autoSkip)
        var a = ShowSettings(); a.speed = 1.25
        var b = ShowSettings(); b.autoSkip = ["intro"]; b.speed = 2; b.secondSubtitle = SubtitleChoice(lang: "ja")
        let merged = a.filled(from: b)
        XCTAssertEqual(merged.speed, 1.25)
        XCTAssertEqual(merged.autoSkip, ["intro"])
        XCTAssertEqual(merged.secondSubtitle?.lang, "ja")
    }
}
