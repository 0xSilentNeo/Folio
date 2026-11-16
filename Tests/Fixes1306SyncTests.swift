import XCTest
import SwiftUI
@testable import Folio

/// 1.30.6: an anime scrobble waits for the id its service sends by, a
/// Keychain that can't be read leaves the kids profile on, a passcode pad
/// still opening counts as up, the Airing widgets empty in the kids profile,
/// a newer "new version" banner replaces an older one, and a preset writes
/// only what it changes and its shader list only with the shaders.
@MainActor
final class Fixes1306SyncTests: XCTestCase {

    // MARK: Anime ids for sync

    /// A `mal:` episode finished offline: MyAnimeList's id known, ids.moe
    /// (which gives AniList's) not reached. The AniList job waits.
    func testTheIDAServiceSendsByIsWaitedFor() {
        var mal = AnimeHint(title: "Sousou no Frieren", episode: 5)
        mal.malId = 52991
        XCTAssertEqual(SkipService.idLookup(mal, failed: true, need: .anilist), .unreachable, "AniList's id could still come")
        XCTAssertEqual(SkipService.idLookup(mal, failed: true, need: .mal), .found(mal), "MyAnimeList's job has its id")
        XCTAssertEqual(SkipService.idLookup(mal, failed: false, need: .anilist), .found(mal), "answered without one: skipped as before")
        var al = AnimeHint(title: "Sousou no Frieren", episode: 5)
        al.anilistId = 154587
        XCTAssertEqual(SkipService.idLookup(al, failed: true, need: .mal), .unreachable)
        XCTAssertEqual(SkipService.idLookup(al, failed: true, need: .anilist), .found(al))
        var both = al
        both.malId = 52991
        XCTAssertEqual(SkipService.idLookup(both, failed: true, need: .mal), .found(both))
        let none = AnimeHint(title: "Sousou no Frieren", episode: 5)
        XCTAssertEqual(SkipService.idLookup(none, failed: false, need: .anilist), .notFound)
        XCTAssertEqual(SkipService.idLookup(none, failed: true, need: .mal), .unreachable)
        XCTAssertEqual(SkipService.idLookup(al, failed: true), .found(al), "without a service, as in 1.30.4")
    }

    // MARK: The kids profile and the Keychain

    func testOnlyNotFoundTurnsTheProfileOff() {
        XCTAssertEqual(KidsProfile.leaveCheck(isOn: true, stored: false, protectedData: true), .turnOff, "restored on, no passcode")
        XCTAssertEqual(KidsProfile.leaveCheck(isOn: true, stored: true, protectedData: true), .stayOn)
        XCTAssertEqual(KidsProfile.leaveCheck(isOn: true, stored: nil, protectedData: true), .askAgain,
                       "a read that failed (errSecInteractionNotAllowed) isn't \"no passcode\"")
        XCTAssertEqual(KidsProfile.leaveCheck(isOn: true, stored: false, protectedData: false), .askAgain, "before the first unlock")
        XCTAssertEqual(KidsProfile.leaveCheck(isOn: false, stored: false, protectedData: true), .stayOn)
        XCTAssertEqual(KidsProfile.leaveCheck(isOn: false, stored: nil, protectedData: false), .stayOn)
    }

    /// What passcodeStored counts on: "not found" is kept, a failure isn't,
    /// so a second ask reaches the read only after a failure.
    func testTheCacheKeepsNotFoundButNeverAFailure() {
        let cache = SecretCache()
        XCTAssertNil(cache.value(for: "missing") { .missing })
        var asked = false
        _ = cache.value(for: "missing") { asked = true; return .failed }
        XCTAssertFalse(asked, "not found is known")
        XCTAssertNil(cache.value(for: "locked") { .failed })
        _ = cache.value(for: "locked") { asked = true; return .failed }
        XCTAssertTrue(asked, "a failure is asked again")
    }

    func testThePasscodeIsFoundOrNot() {
        let saved = Keychain.get(KidsProfile.passcodeAccount)
        defer { Keychain.set(saved, for: KidsProfile.passcodeAccount) }
        Keychain.set(nil, for: KidsProfile.passcodeAccount)
        XCTAssertEqual(KidsProfile.passcodeStored, false)
        Keychain.set(KidsProfile.hashed("2580", salt: "00"), for: KidsProfile.passcodeAccount)
        XCTAssertEqual(KidsProfile.passcodeStored, true)
    }

    // MARK: A passcode pad still opening

    private final class GateBox { var gate: KidsGate? }

    private func nextTurn() async {
        let turn = expectation(description: "a turn of the main queue")
        DispatchQueue.main.async { turn.fulfill() }
        await fulfillment(of: [turn], timeout: 2)
    }

    func testAPadAskedForCountsBeforeItIsUp() async {
        let before = KidsGate.shown
        let box = GateBox()
        let binding = Binding<KidsGate?>(get: { box.gate }, set: { box.gate = $0 })
        KidsGate.open(binding, .unlock(reason: "test")) { _ in }
        XCTAssertEqual(KidsGate.shown, before + 1, "asked for, not up yet: Home closes it before Settings")
        await nextTurn()
        XCTAssertNotNil(box.gate)
        XCTAssertEqual(KidsGate.shown, before + 1, "set, its cover not up yet")
        KidsGate.close(binding)
        XCTAssertNil(box.gate)
        XCTAssertEqual(KidsGate.shown, before)
    }

    func testClosingAllStopsAPadStillOpening() async {
        let before = KidsGate.shown
        let box = GateBox()
        let binding = Binding<KidsGate?>(get: { box.gate }, set: { box.gate = $0 })
        KidsGate.open(binding, .unlock(reason: "test")) { _ in }
        XCTAssertEqual(KidsGate.shown, before + 1)
        KidsGate.closeAll()
        XCTAssertLessThanOrEqual(KidsGate.shown, before)
        await nextTurn()
        XCTAssertNil(box.gate, "closed before its turn: never set")
    }

    // MARK: The Airing widgets in the kids profile

    func testTheKidsProfileEmptiesTheAiringWidgets() {
        let now = Date(timeIntervalSince1970: 1_794_571_200)
        var s = TrackedShow(id: "tt1", name: "Grown-up show")
        s.next = AiringEpisode(season: 1, number: 2, airDate: now.addingTimeInterval(3600), day: nil)
        let grownUps = AiringSnapshotWriter.snapshot(AiringSnapshotWriter.shown([s], kids: false), now: now)
        XCTAssertEqual(grownUps.items.map(\.id), ["tt1"])
        let kids = AiringSnapshotWriter.snapshot(AiringSnapshotWriter.shown([s], kids: true), now: now)
        XCTAssertTrue(kids.items.isEmpty)
        XCTAssertEqual(kids.tracked, 0)
        XCTAssertEqual(kids.recent ?? [], [])
    }

    // MARK: News from Folio

    private func news(_ id: String) -> Announcements.Entry { Announcements.Entry(id: id, title: id) }
    private func update(_ v: String) -> Announcements.Entry { Announcements.Entry(id: "u\(v)", title: "\(v) is out", version: v) }

    func testANewerUpdateReplacesTheOneWaitingAndShowsFirst() {
        let a = news("a"), u5 = update("1.30.5"), u6 = update("1.30.6")
        let list = Announcements.queued([a, u5], adding: [u6], appVersion: "1.30.4")
        XCTAssertEqual(list.map(\.id), ["u1.30.6", "a"])
        XCTAssertEqual(Announcements.replaced([a, u5, u6], by: list), ["u1.30.5"], "marked seen: not picked again")
        XCTAssertEqual(Announcements.queued([u6, a], adding: [u5], appVersion: "1.30.4").map(\.id), ["u1.30.6", "a"], "an older one arriving later")
        XCTAssertEqual(Announcements.queued([a], adding: [u6], appVersion: "1.30.4").map(\.id), ["u1.30.6", "a"], "an update goes first")
        XCTAssertEqual(Announcements.queued([news("a")], adding: [news("b")], appVersion: "1.30.4").map(\.id), ["a", "b"], "news in turn, as before")
        XCTAssertTrue(Announcements.replaced([a], by: [a]).isEmpty)
        XCTAssertEqual(Announcements.queued([u5, u6], adding: [], appVersion: "1.30.5").map(\.id), ["u1.30.6"], "the installed one goes")
    }

    // MARK: Presets

    private func preset(_ settings: String) -> Data {
        Data(#"{"format": "folio-preset", "version": 1, "settings": \#(settings)}"#.utf8)
    }

    func testTheShaderListGoesWithTheShaders() throws {
        let known: [String: SettingsPreset.Kind] = ["subLangs": .string, SettingsKey.activeShaders: .strings]
        let p = try SettingsPreset.plan(preset(#"{"subLangs": "en", "activeShaders": ["FSR.glsl"]}"#), known: known, deleteWatchedNow: 0)
        XCTAssertEqual(p.activeShaders, ["FSR.glsl"])
        XCTAssertNil(p.settings[SettingsKey.activeShaders], "not applied with the settings")
        XCTAssertEqual(p.settings["subLangs"] as? String, "en")
    }

    func testValuesCompareAsUserDefaultsKeepsThem() {
        XCTAssertTrue(SettingsPreset.unchanged(NSNumber(value: true), true))
        XCTAssertTrue(SettingsPreset.unchanged(NSNumber(value: 3), 3))
        XCTAssertTrue(SettingsPreset.unchanged(NSNumber(value: 1.5), 1.5))
        XCTAssertTrue(SettingsPreset.unchanged("en" as NSString, "en"))
        XCTAssertTrue(SettingsPreset.unchanged(["a", "b"] as NSArray, ["a", "b"]))
        XCTAssertTrue(SettingsPreset.unchanged(Data([1, 2]) as NSData, Data([1, 2])))
        XCTAssertTrue(SettingsPreset.unchanged(["k": 1] as NSDictionary, ["k": 1] as [String: Any]))
        XCTAssertFalse(SettingsPreset.unchanged(NSNumber(value: 3), 4))
        XCTAssertFalse(SettingsPreset.unchanged("en" as NSString, "fr"))
        XCTAssertFalse(SettingsPreset.unchanged(["a"] as NSArray, ["a", "b"]))
        XCTAssertFalse(SettingsPreset.unchanged(nil, "en"), "not set at all")
    }

    func testAPresetWritesOnlyWhatChanges() {
        let d = UserDefaults.standard
        let key = "fixes1306.presetValue"
        let domain = Bundle.main.bundleIdentifier ?? ""
        let savedShaders = d.object(forKey: SettingsKey.activeShaders)
        defer {
            d.removeObject(forKey: key)
            if let savedShaders { d.set(savedShaders, forKey: SettingsKey.activeShaders) } else { d.removeObject(forKey: SettingsKey.activeShaders) }
        }
        d.register(defaults: [key: 5])
        d.removeObject(forKey: key)
        var p = SettingsPreset.Plan()
        p.settings = [key: 5]
        p.activeShaders = ["fixes1306.glsl"]
        var c = SettingsPreset.Plan.Choices()
        c.shaders = false
        let r = SettingsPreset.apply(p, c)
        XCTAssertEqual(r.applied, 1)
        XCTAssertNil(d.persistentDomain(forName: domain)?[key], "the default it already had: not written")
        XCTAssertNotEqual(d.stringArray(forKey: SettingsKey.activeShaders), ["fixes1306.glsl"], "shaders not ticked")
        p.settings = [key: 6]
        c.shaders = true
        _ = SettingsPreset.apply(p, c)
        XCTAssertEqual(d.persistentDomain(forName: domain)?[key] as? Int, 6)
        XCTAssertEqual(d.stringArray(forKey: SettingsKey.activeShaders), ["fixes1306.glsl"], "ticked")
    }
}
