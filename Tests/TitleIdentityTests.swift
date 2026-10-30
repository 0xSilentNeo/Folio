import XCTest
@testable import GlassPlayer

/// Title identities for the shared watch history (1.20.0: the read-only
/// linking check; nothing is migrated yet).
final class TitleIdentityTests: XCTestCase {
    func testAddonKeys() {
        XCTAssertEqual(TitleIdentity.fromAddonKey("addon:tt37532356:1:24"), "tt37532356:1:24")
        XCTAssertEqual(TitleIdentity.fromAddonKey("addon:tt0816692"), "tt0816692")
        XCTAssertNil(TitleIdentity.fromAddonKey("addon:kitsu:46474:5"))
        XCTAssertNil(TitleIdentity.fromAddonKey("addon:tt123:1"))
        XCTAssertNil(TitleIdentity.fromAddonKey("/var/mobile/Media/MobLand S01E01.mkv"))
    }

    private let gentlemen: (ReleaseName) async -> String? = { $0.title == "The Gentlemen" ? "tt13210838" : nil }

    /// A season pack on Real-Debrid: the folder's match, the file's S/E.
    func testWebDAVEpisodeInAReleaseFolder() async {
        let id = await TitleIdentity.forFile(name: "The.Gentlemen.S01E03.1080p.NF.WEB-DL.mkv",
                                             folder: "The.Gentlemen.S01.1080p.NF.WEB-DL.DDP5.1.H.264-FLUX", match: gentlemen)
        XCTAssertEqual(id, "tt13210838:1:3")
    }

    /// The same episode from a library file and from the addon: one identity.
    func testLibraryFileAndAddonMeet() async {
        let file = await TitleIdentity.forFile(name: "The Gentlemen S01E03.mkv", folder: nil, match: gentlemen)
        XCTAssertEqual(file, TitleIdentity.fromAddonKey("addon:tt13210838:1:3"))
    }

    /// No confident match: no identity, never a guess.
    func testUnmatchedHasNone() async {
        let id = await TitleIdentity.forFile(name: "Home Video 2019.mp4", folder: nil, match: gentlemen)
        XCTAssertNil(id)
    }

    /// An absolute episode number has no season: none.
    func testAbsoluteNumberHasNone() async {
        let id = await TitleIdentity.forFile(name: "[SubsPlease] The Gentlemen - 26 (1080p).mkv", folder: nil, match: gentlemen)
        XCTAssertNil(id)
    }

    func testFilm() async {
        let id = await TitleIdentity.forFile(name: "Dune.Part.Two.2024.2160p.UHD.BluRay.mkv", folder: nil) { $0.title == "Dune Part Two" ? "tt15239678" : nil }
        XCTAssertEqual(id, "tt15239678")
    }

    func testCheckCountsWithoutChangingAnything() async {
        func entry(_ url: String, _ source: MediaSource, key: String? = nil) -> HistoryEntry {
            var item = MediaItem(url: url, title: "x", source: source)
            item.historyKey = key
            return HistoryEntry(item: item, position: 100, duration: 1000, updated: Date())
        }
        let entries = [
            entry("https://dav.example.com/The.Gentlemen.S01.1080p.NF.WEB-DL-FLUX/The.Gentlemen.S01E03.1080p.NF.WEB-DL.mkv", .webdav(serverID: UUID())),
            entry("https://stream.example/abc", .addon(name: "A"), key: "addon:tt13210838:1:3"),
            entry("https://stream.example/def", .addon(name: "A"), key: "addon:kitsu:1:2"),
            entry("/Documents/Media/Home Video 2019.mp4", .local),
        ]
        let r = await HistoryLinkCheck.check(entries, match: gentlemen)
        XCTAssertEqual(r.entries, 4)
        XCTAssertEqual(r.addon, 2); XCTAssertEqual(r.addonLinked, 1)
        XCTAssertEqual(r.webdav, 1); XCTAssertEqual(r.webdavLinked, 1)
        XCTAssertEqual(r.library, 1); XCTAssertEqual(r.libraryLinked, 0)
        XCTAssertEqual(r.sharedAcrossSources, 1)
    }
}

final class SeasonEpisodeLabelTests: XCTestCase {
    func testLabels() {
        XCTAssertTrue(TitleIdentity.seasonEpisode("S01E03")! == (1, 3))
        XCTAssertNil(TitleIdentity.seasonEpisode("E05"))
        XCTAssertNil(TitleIdentity.seasonEpisode("S02"))
        XCTAssertNil(TitleIdentity.seasonEpisode("S01-S03"))
        XCTAssertNil(TitleIdentity.seasonEpisode("Complete"))
    }
}
