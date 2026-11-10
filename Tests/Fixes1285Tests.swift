import XCTest
@testable import Folio

/// 1.28.5: the Cowboy Bebop poster, notifications that stay while Folio is
/// open, the master switch, settings pages that show a change at once, and
/// the kids passcode's Lock Screen keys.
@MainActor
final class Fixes1285Tests: XCTestCase {
    private func release(_ folder: String) throws -> ReleaseName { try XCTUnwrap(ReleaseName.folder(folder)) }

    /// IMDb's popularity rank, as the suggestions give it (10 Nov).
    private func imdb(_ id: String, _ name: String, _ year: Int, rank: Int) -> ReleaseMatch.Candidate {
        ReleaseMatch.Candidate(id: id, name: name, originalName: nil, year: year, kind: .series,
                               popularity: 100_000 / Double(rank), poster: "https://img.invalid/\(id).jpg", animation: false, japanese: false)
    }

    // MARK: The Cowboy Bebop poster

    /// Two series called Cowboy Bebop and no year in the folder's name: the
    /// 1998 one is far more popular on IMDb, so it's the match (it was a
    /// placeholder: IMDb's candidates had no popularity).
    func testFarMorePopularOnIMDbDecides() throws {
        let r = ReleaseMatch.pick(try release("Cowboy.Bebop.S01.1080i.BluRay.REMUX.AVC.FLAC.2.0-GRP"),
                                  [imdb("tt0213338", "Cowboy Bebop", 1998, rank: 1880), imdb("tt1267295", "Cowboy Bebop", 2021, rank: 10491)],
                                  source: "IMDb")
        XCTAssertTrue(r.confident, r.why)
        XCTAssertEqual(r.imdbID, "tt0213338")
    }

    /// Close in popularity: still a placeholder rather than a guess.
    func testCloseInPopularityStaysAPlaceholder() throws {
        let r = ReleaseMatch.pick(try release("Dark.S01.1080p.WEB-DL-GRP"),
                                  [imdb("tt6", "Dark", 2017, rank: 1000), imdb("tt7", "Dark", 2009, rank: 2000)], source: "IMDb")
        XCTAssertFalse(r.confident, r.why)
    }

    /// An unsure match from the rules before 1.28.5 is asked again at once.
    func testAnUnsureMatchFromOlderRulesIsTriedAgain() {
        let now = Date()
        var old = ReleaseMatch.Result(imdbID: nil, name: nil, year: nil, poster: nil, score: 0, source: "IMDb", confident: false,
                                      why: "2 titles", date: now)
        XCTAssertTrue(old.wantsRetry(preferred: "IMDb", now: now))
        old.rules = 2
        XCTAssertFalse(old.wantsRetry(preferred: "IMDb", now: now))
        XCTAssertTrue(old.wantsRetry(preferred: "IMDb", now: now.addingTimeInterval(4 * 86400)))
        old.confident = true
        old.rules = nil
        XCTAssertFalse(old.wantsRetry(preferred: "IMDb", now: now), "a confident match stays")
    }

    // MARK: Notifications

    /// Coming back to Folio takes back only what hangs on what you do in it.
    func testOnlyWatchingDependentNotificationsAreTakenBack() {
        for k in NotifyKind.allCases where k.group == .watching {
            XCTAssertFalse(k.keptWhileOpen, "\(k) hangs on what you watch")
        }
        for k in NotifyKind.allCases where k.group == .trending {
            XCTAssertTrue(k.keptWhileOpen, "\(k) is IMDb's charts")
        }
        XCTAssertTrue(NotifyKind.weeklyBriefing.keptWhileOpen)
        XCTAssertTrue(NotifyKind.freshTitles.keptWhileOpen)
        for k: NotifyKind in [.rainy, .cold, .hot, .holiday, .weekendForecast, .movieNight] {
            XCTAssertTrue(k.keptWhileOpen, "\(k) is the weather or the calendar")
        }
        for k: NotifyKind in [.openedNoWatch, .longChoosing, .streak, .unfinishedPile, .monthlyRecap, .forgotten, .forYouPick] {
            XCTAssertFalse(k.keptWhileOpen, "\(k) can be made wrong by watching")
        }
    }

    /// Off as a whole: no kind is switched on, whatever its own switch.
    func testTheMasterSwitchTurnsEveryKindOff() {
        let d = UserDefaults.standard
        let before = d.object(forKey: SettingsKey.notifyAllOff)
        defer { d.set(before, forKey: SettingsKey.notifyAllOff) }
        NotifyPrefs.allOn = true
        let on = NotifyKind.allCases.filter(NotifyPrefs.switchedOn)
        NotifyPrefs.allOn = false
        XCTAssertFalse(NotifyPrefs.allOn)
        XCTAssertTrue(NotifyKind.allCases.filter(NotifyPrefs.switchedOn).isEmpty)
        NotifyPrefs.allOn = true
        XCTAssertEqual(NotifyKind.allCases.filter(NotifyPrefs.switchedOn), on, "each kind's own switch is kept")
    }

    /// A sound or city picked on the page above shows on the page under it:
    /// both are read through the model the pages observe.
    func testSoundAndCityChangesReachThePagesUnderThem() {
        let d = UserDefaults.standard
        let sounds = d.object(forKey: SettingsKey.notifySounds), place = d.object(forKey: SettingsKey.notifyPlace)
        defer {
            d.set(sounds, forKey: SettingsKey.notifySounds)
            d.set(place, forKey: SettingsKey.notifyPlace)
        }
        let model = NotifyPrefsModel.shared
        let start = model.revision
        model.setSound(.none, for: .trending)
        XCTAssertEqual(model.sound(for: .trending), NotifySound.none)
        XCTAssertGreaterThan(model.revision, start)
        let r = model.revision
        model.place = nil
        XCTAssertNil(model.place)
        XCTAssertGreaterThan(model.revision, r)
    }

    // MARK: The kids passcode

    /// The Lock Screen's keys: 75 pt on a 375 pt phone, 88 on a Pro Max,
    /// never past 90; smaller when the screen is short.
    func testThePasscodeKeysAreTheLockScreensSize() {
        XCTAssertEqual(PasscodeScreen.keySize(CGSize(width: 375, height: 812), landscape: false), 75)
        XCTAssertEqual(PasscodeScreen.keySize(CGSize(width: 440, height: 956), landscape: false), 88)
        XCTAssertEqual(PasscodeScreen.keySize(CGSize(width: 600, height: 1000), landscape: false), 90)
        XCTAssertLessThan(PasscodeScreen.keySize(CGSize(width: 375, height: 600), landscape: false), 75)
    }

    func testTheBiometrySymbolMatchesTheDevice() {
        XCTAssertEqual(KidsProfile.biometrySymbol("Face ID"), "faceid")
        XCTAssertEqual(KidsProfile.biometrySymbol("Touch ID"), "touchid")
        XCTAssertEqual(KidsProfile.biometrySymbol("Optic ID"), "opticid")
    }
}
