import XCTest
@testable import Folio

/// 1.30.4: the kids passcode's lockout messages, the profile left on with no
/// passcode (a restored backup), Settings' search finding only what its
/// pages show, what a server's file or entry plays with, a folder's titles
/// on their own, Home's grid row ids, and Airing now's season.
@MainActor
final class Fixes1304KidsTests: XCTestCase {
    // MARK: Lockout messages

    func testLastTryNoteNamesTheNextWait() {
        XCTAssertEqual(KidsProfile.lastTryNote(lockouts: 0), "Wrong passcode. One more try before a 30-second wait.")
        XCTAssertEqual(KidsProfile.lastTryNote(lockouts: 1), "Wrong passcode. One more try before a 1-minute wait.")
        XCTAssertEqual(KidsProfile.lastTryNote(lockouts: 2), "Wrong passcode. One more try before a 5-minute wait.")
        XCTAssertEqual(KidsProfile.lastTryNote(lockouts: 3), "Wrong passcode. One more try before a 15-minute wait.")
        XCTAssertEqual(KidsProfile.lastTryNote(lockouts: 4), "Wrong passcode. One more try before a 1-hour wait.")
        XCTAssertEqual(KidsProfile.lastTryNote(lockouts: 9), "Wrong passcode. One more try before a 1-hour wait.", "an hour is the longest")
    }

    func testCountdownInMinutesPastAMinute() {
        XCTAssertEqual(KidsProfile.waitNote(seconds: 30), "Too many tries. Try again in 30 s.")
        XCTAssertEqual(KidsProfile.waitNote(seconds: 60), "Too many tries. Try again in 60 s.")
        XCTAssertEqual(KidsProfile.waitNote(seconds: 61), "Too many tries. Try again in 2 min.")
        XCTAssertEqual(KidsProfile.waitNote(seconds: 299), "Too many tries. Try again in 5 min.")
        XCTAssertEqual(KidsProfile.waitNote(seconds: 3600), "Too many tries. Try again in 60 min.", "not 3600 s")
    }

    func testWaitLengths() {
        XCTAssertEqual(KidsProfile.waitLength(KidsProfile.lockout(after: 0)), "30-second")
        XCTAssertEqual(KidsProfile.waitLength(900), "15-minute")
        XCTAssertEqual(KidsProfile.waitLength(3600), "1-hour")
    }

    // MARK: On with no passcode

    func testOnWithoutPasscodeTurnsOffOnlyWhenTheKeychainCanTell() {
        XCTAssertTrue(KidsProfile.offWithoutPasscode(isOn: true, hasPasscode: false, keychainReadable: true), "restored on, no passcode: no way out")
        XCTAssertFalse(KidsProfile.offWithoutPasscode(isOn: true, hasPasscode: true, keychainReadable: true))
        XCTAssertFalse(KidsProfile.offWithoutPasscode(isOn: false, hasPasscode: false, keychainReadable: true))
        XCTAssertFalse(KidsProfile.offWithoutPasscode(isOn: true, hasPasscode: false, keychainReadable: false),
                       "before the first unlock the Keychain reads as empty: the profile stays on")
    }

    // MARK: Settings' search

    private func titles(_ q: String, _ showing: Set<SettingsIndex.Shown>) -> [String] {
        SettingsIndex.search(q, showing: showing).map(\.title)
    }

    func testFlipVideoOnlyWithOpenGL() {
        XCTAssertFalse(titles("flip", [.always]).contains("Flip Video"))
        XCTAssertTrue(titles("flip", [.always, .openGL]).contains("Flip Video"))
    }

    func testNativeMenuMorphOnlyOnIOS26() {
        XCTAssertFalse(titles("morph", [.always]).contains("Native Menu Morph"))
        XCTAssertTrue(titles("morph", [.always, .iOS26]).contains("Native Menu Morph"))
    }

    func testEverythingElseIsFoundEverywhere() {
        XCTAssertTrue(titles("renderer", [.always]).contains("Renderer"))
        for p in SettingsPage.allCases { XCTAssertTrue(titles(p.title, [.always]).contains(p.title), p.title) }
    }

    // MARK: What a server's file plays with

    private let base = URL(string: "https://dav.example.invalid/Show/")!
    private func dav(_ name: String) -> DAVItem {
        DAVItem(url: base.appendingPathComponent(name), name: name, isDirectory: false, size: 1, modified: nil, contentType: nil)
    }

    func testAFilmPlaysAlone() {
        let media = [dav("Dune (2021) 2160p.mkv"), dav("Arrival (2016) 1080p.mkv"), dav("Heat (1995).mkv")]
        XCTAssertEqual(DAVOrder.queue(for: media[1], in: media).map(\.name), ["Arrival (2016) 1080p.mkv"])
    }

    func testEpisodesPlayInEpisodeOrderWhateverTheSort() {
        // As Z to A shows them, with a film and another show among them.
        let media = [dav("Show S01E03.mkv"), dav("Other S01E01.mkv"), dav("Show S01E02.mkv"), dav("Film (2020).mkv"), dav("Show S01E01.mkv")]
        XCTAssertEqual(DAVOrder.queue(for: media[2], in: media).map(\.name), ["Show S01E01.mkv", "Show S01E02.mkv", "Show S01E03.mkv"])
    }

    func testCatalogFilmAloneAndSeasonInOrder() {
        let film = CatalogEntry(id: "m1", kind: .movie, name: "Dune")
        let eps = [3, 1, 2].map { (n: Int) in CatalogEntry(id: "e\(n)", kind: .episode, name: "E\(n)", season: 1, episode: n, seriesName: "Show") }
        let list = [film] + eps
        XCTAssertEqual(CatalogBrowserView.queue(for: film, in: list).map(\.id), ["m1"])
        XCTAssertEqual(CatalogBrowserView.queue(for: eps[0], in: list).map(\.id), ["e1", "e2", "e3"])
    }

    // MARK: A folder's titles

    private func folderGroup() -> LibraryGroup {
        let dir = URL(fileURLWithPath: "/lab/Media/Mixed", isDirectory: true)
        let files = ["Dune (2021).mkv", "Lab Show S01E02.mkv", "Heat (1995).mkv", "Lab Show S01E01.mkv"].map { dir.appendingPathComponent($0) }
        return LibraryGroup(id: "d|" + dir.path, title: "Mixed", files: files, isSeries: false, date: .distantPast, size: 0, folder: dir)
    }

    func testAFilmInAFolderIsItsOwnTitle() {
        let g = folderGroup()
        let dune = g.files[0]
        let t = LibraryGroup.ownTitle(of: dune, in: g)
        XCTAssertEqual(t.files, [dune], "the folder's other films aren't its episodes")
        XCTAssertFalse(t.isSeries)
        XCTAssertNil(t.folder)
    }

    func testAnEpisodeInAFolderIsItsShow() {
        let g = folderGroup()
        let t = LibraryGroup.ownTitle(of: g.files[1], in: g)
        XCTAssertEqual(t.files.map(\.lastPathComponent), ["Lab Show S01E01.mkv", "Lab Show S01E02.mkv"])
        XCTAssertTrue(t.isSeries)
        XCTAssertEqual(t.title, "Lab Show")
    }

    func testAFilmInAFolderIsFoundByName() {
        let found = LibrarySearchResults.libraryMatches(["heat"], in: [folderGroup()], limits: nil)
        XCTAssertEqual(found.map { $0.files.map(\.lastPathComponent) }, [["Heat (1995).mkv"]])
        XCTAssertEqual(LibrarySearchResults.libraryMatches(["mixed"], in: [folderGroup()], limits: nil).first?.folder?.lastPathComponent, "Mixed",
                       "the folder itself, by its own name")
    }

    // MARK: Home's grid rows

    func testRowIDsStayWhenATitleIsAdded() {
        func groups(_ t: [String]) -> [LibraryGroup] {
            t.map { LibraryGroup(id: "g|" + $0, title: $0, files: [URL(fileURLWithPath: "/lab/\($0).mkv")], isSeries: false, date: .distantPast, size: 0) }
        }
        let before = TileRow.rows(groups(["B", "C", "D", "E"]), columns: 3)
        let after = TileRow.rows(groups(["A", "B", "C", "D", "E"]), columns: 3)
        XCTAssertEqual(before.map(\.id), after.map(\.id), "a new first title doesn't rename the rows after it")
        XCTAssertNotEqual(TileRow.rows(groups(["A"]), columns: 3).map(\.id), TileRow.rows(groups(["A"]), columns: 6).map(\.id))
    }

    // MARK: Airing now

    func testAiringSeasonFromTheNote() {
        XCTAssertEqual(AiringNowRow.season(fromNote: "S3 · E5 today"), 3)
        XCTAssertEqual(AiringNowRow.season(fromNote: "S12 · E1 Tue"), 12)
        XCTAssertNil(AiringNowRow.season(fromNote: "E5 in 2 days"))
        XCTAssertNil(AiringNowRow.season(fromNote: nil))
        XCTAssertNil(AiringNowRow.season(fromNote: "Soon"))
    }
}
