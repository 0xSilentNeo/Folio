import XCTest
@testable import Folio

/// 1.30.2: the review's fixes that are plain logic.
final class Fixes1302LogicTests: XCTestCase {
    private func series(_ id: String, _ name: String, _ year: String?, type: String = "series") -> MetaItem {
        MetaItem(id: id, type: type, name: name, poster: nil, description: nil, releaseInfo: year, imdbRating: nil, genres: nil)
    }

    /// An anime's IMDb title is the one of its name that began in the
    /// season's year or the closest before it, not the first of that name.
    func testAnimeLinkPrefersTheYearAtOrBeforeTheSeason() {
        let wanted: Set<String> = [AnimeLink.normalized("Cowboy Bebop")]
        let live = series("tt1267295", "Cowboy Bebop", "2021–2021"), anime = series("tt0213338", "Cowboy Bebop", "1998–1999")
        XCTAssertEqual(AnimeLink.choose([live, anime], wanted: wanted, seasonYear: 1998)?.id, "tt0213338")
        // A later season of the same show: still the one that began before it.
        XCTAssertEqual(AnimeLink.choose([live, anime], wanted: wanted, seasonYear: 2001)?.id, "tt0213338")
        // The closest before, of two.
        XCTAssertEqual(AnimeLink.choose([anime, live], wanted: wanted, seasonYear: 2024)?.id, "tt1267295")
        // Years not known: the first, as before.
        XCTAssertEqual(AnimeLink.choose([live, anime], wanted: wanted, seasonYear: nil)?.id, "tt1267295")
        XCTAssertEqual(AnimeLink.choose([series("tt1", "Cowboy Bebop", nil), series("tt2", "Cowboy Bebop", nil)], wanted: wanted, seasonYear: 1998)?.id, "tt1")
        // None began by then: the first of the name.
        XCTAssertEqual(AnimeLink.choose([live, series("tt3", "Cowboy Bebop", "2030")], wanted: wanted, seasonYear: 1998)?.id, "tt1267295")
        // Another name, or a film, is never taken.
        XCTAssertNil(AnimeLink.choose([series("tt4", "Blues of War", "1998")], wanted: wanted, seasonYear: 1998))
        XCTAssertNil(AnimeLink.choose([series("tt5", "Cowboy Bebop", "1998", type: "movie")], wanted: wanted, seasonYear: 1998))
    }

    /// What was sent in the last 12 hours isn't sent again; older is forgotten.
    func testSentRecently() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let e = SyncEvent(title: "Show", imdb: "tt1", season: 2, episode: 1, isMovie: false, anime: nil, looksLikeAnime: false, watchedAt: now)
        let key = SyncCenter.sentKey(.trakt, e)
        XCTAssertEqual(key, "trakt|tt1|2|1")
        XCTAssertNotEqual(key, SyncCenter.sentKey(.anilist, e), "each service on its own")
        XCTAssertFalse(SyncCenter.sentRecently([:], key: key, now: now))
        XCTAssertTrue(SyncCenter.sentRecently([key: now.addingTimeInterval(-3600)], key: key, now: now))
        XCTAssertFalse(SyncCenter.sentRecently([key: now.addingTimeInterval(-13 * 3600)], key: key, now: now))
        XCTAssertFalse(SyncCenter.sentRecently([key: now.addingTimeInterval(-3600)], key: "trakt|tt1|2|2", now: now))
    }

    func testSentMapIsPruned() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var sent: [String: Date] = ["old": now.addingTimeInterval(-13 * 3600), "fresh": now.addingTimeInterval(-60)]
        XCTAssertEqual(Set(SyncCenter.prunedSent(sent, now: now).keys), ["fresh"])
        // The newest 200 of more.
        sent = [:]
        for i in 0..<250 { sent["k\(i)"] = now.addingTimeInterval(-Double(i) * 10) }
        let kept = SyncCenter.prunedSent(sent, now: now)
        XCTAssertEqual(kept.count, SyncCenter.sentLimit)
        XCTAssertNotNil(kept["k0"])
        XCTAssertNotNil(kept["k199"])
        XCTAssertNil(kept["k200"])
    }

    /// Presets leave the test switches out and carry the appearance and the
    /// notifications' groups, kinds and sounds.
    @MainActor
    func testPresetKeys() {
        let known = SettingsPreset.known
        XCTAssertNil(known[SettingsKey.notifyTest])
        XCTAssertNil(known[SettingsKey.engageQuick])
        XCTAssertEqual(known[SettingsKey.appearance], .string)
        XCTAssertEqual(known[SettingsKey.notifyGroupsOff], .strings)
        XCTAssertEqual(known[SettingsKey.notifyKindsOff], .strings)
        XCTAssertEqual(known[SettingsKey.notifySounds], .dictionary)
    }

    func testOptionFileNames() {
        XCTAssertEqual(ScriptOptsView.optionFileName("stats"), "stats.conf")
        XCTAssertEqual(ScriptOptsView.optionFileName("  stats.conf "), "stats.conf")
        XCTAssertNil(ScriptOptsView.optionFileName(""))
        XCTAssertNil(ScriptOptsView.optionFileName("   "))
        XCTAssertNil(ScriptOptsView.optionFileName(".conf"))
        XCTAssertNil(ScriptOptsView.optionFileName("/"))
        XCTAssertEqual(ScriptOptsView.optionFileName("../a/b"), "ab.conf")
        XCTAssertEqual(ScriptOptsView.optionFileName("osc"), "osc.conf")
    }

    func testRegionAsTyped() {
        XCTAssertEqual(PlatformCatalogs.cleanRegion("au "), "AU")
        XCTAssertEqual(PlatformCatalogs.cleanRegion("GB"), "GB")
        XCTAssertNil(PlatformCatalogs.cleanRegion(""))
        XCTAssertNil(PlatformCatalogs.cleanRegion("A"))
        XCTAssertNil(PlatformCatalogs.cleanRegion("AUS"))
        XCTAssertNil(PlatformCatalogs.cleanRegion("A1"))
    }

    /// The passcode's lockout goes by the clock and by the time since the
    /// device started; after a restart, by the clock alone.
    func testLockoutSurvivesTheClockSetForward() {
        // Locked at 1000 s (500 s since boot) for 60 s.
        XCTAssertEqual(KidsProfile.lockLeft(until: 1060, now: 1010, bootAtLock: 500, bootUntil: 560, bootNow: 510), 50)
        // The clock set an hour forward, ten seconds later: still 50 s.
        XCTAssertEqual(KidsProfile.lockLeft(until: 1060, now: 4610, bootAtLock: 500, bootUntil: 560, bootNow: 510), 50)
        // Both over.
        XCTAssertNil(KidsProfile.lockLeft(until: 1060, now: 1061, bootAtLock: 500, bootUntil: 560, bootNow: 561))
        // Restarted (less time since boot than at the lockout): the clock alone.
        XCTAssertNil(KidsProfile.lockLeft(until: 1060, now: 1100, bootAtLock: 500, bootUntil: 560, bootNow: 20))
        XCTAssertEqual(KidsProfile.lockLeft(until: 1060, now: 1040, bootAtLock: 500, bootUntil: 560, bootNow: 20), 20)
        // A lockout saved before 1.30.2 (nothing since boot): the clock alone.
        XCTAssertNil(KidsProfile.lockLeft(until: 1060, now: 1100, bootAtLock: 0, bootUntil: 0, bootNow: 9000))
        // Never locked.
        XCTAssertNil(KidsProfile.lockLeft(until: 0, now: 1000, bootAtLock: 0, bootUntil: 0, bootNow: 9000))
    }
}
