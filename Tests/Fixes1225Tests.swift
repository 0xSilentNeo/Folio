import XCTest
@testable import Folio

/// 1.22.5: Home's search asks Plex and Jellyfin; a download in iOS's
/// background session stays there after a relaunch.
final class Fixes1225Tests: XCTestCase {
    func testASessionDownloadIsSavedAsOne() throws {
        let dest = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/Media/P/E1.mkv")
        var item = DownloadItem(url: URL(string: "https://dav.example.invalid/E1.mkv")!, fileName: "E1.mkv", package: "P", expected: 1, destination: dest)
        XCTAssertFalse(item.usesSession)
        item.inSession = true
        let back = try JSONDecoder().decode(DownloadItem.self, from: JSONEncoder().encode(item))
        XCTAssertTrue(back.usesSession, "after a relaunch it must finish in the session, not start again in Folio")
    }

    func testPlexSearchKeepsFilmsShowsAndEpisodes() throws {
        let json = """
        {"MediaContainer":{"Hub":[
          {"type":"movie","Metadata":[{"key":"/library/metadata/1","ratingKey":"1","type":"movie","title":"Dune","year":2021,"Media":[{"Part":[{"key":"/library/parts/1/file.mkv","file":"/m/Dune.mkv","size":1}]}]}]},
          {"type":"artist","Metadata":[{"key":"/library/metadata/2","ratingKey":"2","type":"artist","title":"Dune (band)"}]},
          {"type":"show","Metadata":[{"ratingKey":"3","type":"show","title":"Dune: Prophecy","key":"/library/metadata/3/children"}]},
          {"type":"episode","Metadata":[{"key":"/library/metadata/4","ratingKey":"4","type":"episode","title":"Pilot","grandparentTitle":"Dune: Prophecy","parentIndex":1,"index":1,"Media":[{"Part":[{"key":"/library/parts/4/file.mkv","file":"/s/E1.mkv","size":1}]}]}]}
        ]}}
        """
        let entries = try PlexAPI.decodeHubs(Data(json.utf8)).map(\.entry)
        XCTAssertEqual(entries.map(\.id), ["1", "3", "4"])
        XCTAssertEqual(entries.map(\.kind), [.movie, .series, .episode])
    }

    func testJellyfinSearchAddress() throws {
        let url = try XCTUnwrap(JellyfinAPI.searchURL(base: URL(string: "https://jf.example.invalid")!, userID: "u1", query: "dune part"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(url.path, "/Users/u1/Items")
        XCTAssertEqual(items.first { $0.name == "searchTerm" }?.value, "dune part")
        XCTAssertEqual(items.first { $0.name == "Recursive" }?.value, "true")
    }

    /// 1.28.11: one search for every tab; what it looks through ends with IMDb.
    @MainActor
    func testTheOneSearchLooksEverywhere() {
        let sources = LibrarySearchResults.sources().map(\.name)
        XCTAssertEqual(sources.first, "Library")
        XCTAssertEqual(sources.last, "Movies & Shows")
    }
}

/// The title page's loading lines (1.22.5).
final class LoadingQuipsTests: XCTestCase {
    func testEveryLineOnceARoundAndNoRepeatAcrossRounds() {
        let n = LoadingQuips.lines.count
        for _ in 0..<50 {
            let a = LoadingQuips.shuffled()
            XCTAssertEqual(Set(a).count, n)
            let b = LoadingQuips.shuffled(notFirst: a.last)
            XCTAssertNotEqual(b.first, a.last, "the same line twice in a row")
        }
        XCTAssertEqual(Set(LoadingQuips.lines).count, n, "a line is in the list twice")
    }
}
