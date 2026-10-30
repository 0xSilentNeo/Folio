import XCTest
@testable import GlassPlayer

/// The watched actions a menu offers (WatchedMenuItems), and that they follow
/// the history straight after a change. 30 Oct screenshot: "Mark all as
/// watched" on a title whose episodes were all watched.
@MainActor
final class WatchedMenuTests: XCTestCase {
    func testOffersFollowTheCount() {
        XCTAssertTrue(WatchedMenuItems.offers(watched: 0, total: 10) == (true, false), "none watched: only Mark as watched")
        XCTAssertTrue(WatchedMenuItems.offers(watched: 4, total: 10) == (true, true), "some watched: both")
        XCTAssertTrue(WatchedMenuItems.offers(watched: 10, total: 10) == (false, true), "all watched: only Mark as unwatched")
        XCTAssertTrue(WatchedMenuItems.offers(watched: 1, total: 1) == (false, true), "one file, watched")
    }

    func testHistoryChangesShowAtOnce() {
        let h = HistoryStore.shared
        let keys = (1...3).map { "/unit-test/Documents/Media/Watched Test S01E0\($0).mp4" }
        defer { h.setWatched(keys, false, item: HistoryStore.libraryItem) }
        func count() -> Int { keys.filter { h.isWatched(key: $0) }.count }

        h.setWatched(keys, false, item: HistoryStore.libraryItem)
        XCTAssertEqual(count(), 0)
        h.setWatched(Array(keys.prefix(2)), true, item: HistoryStore.libraryItem)
        XCTAssertEqual(count(), 2, "never-played files marked watched")
        XCTAssertTrue(WatchedMenuItems.offers(watched: count(), total: keys.count) == (true, true))
        h.setWatched(keys, true, item: HistoryStore.libraryItem)
        XCTAssertTrue(WatchedMenuItems.offers(watched: count(), total: keys.count) == (false, true), "all watched right after the change")
        h.setWatched(keys, false, item: HistoryStore.libraryItem)
        XCTAssertTrue(WatchedMenuItems.offers(watched: count(), total: keys.count) == (true, false), "all unwatched right after the change")
    }
}

/// Continue Watching's line under the title: one format for every source,
/// never a raw release name (30 Oct screenshots: "[AnoZu]…",
/// "S1 · E24 — …", "Hell is other people.").
@MainActor
final class ContinueLineTests: XCTestCase {
    func testAddonEpisode() {
        var m = MediaItem(url: "", title: "Daemons of the Shadow Realm", subtitle: "S1 · E24 — Higashi Village and Nishino Village", source: .url)
        m.addonRef = "series|tt37532356|tt37532356:1:24"
        XCTAssertEqual(HeroCard.line(m, meta: nil), "S1 · E24 · Higashi Village and Nishino Village")
    }

    func testWebDAVFileNeverShowsTheFolderName() {
        let m = MediaItem(url: "https://dav.example.invalid/torrents/x/Daemons.of.the.Shadow.Realm.2026.S01E24.1080p.CR.WEB.DL.DUAL.DDP2.0.H.264-AnoZu.mkv",
                          title: "Daemons of the Shadow Realm · S01E24", subtitle: "[AnoZu] Daemons of the Shadow Realm S01 1080p CR WEB.DL", source: .url)
        XCTAssertEqual(HeroCard.line(m, meta: nil), "S1 · E24")
    }

    func testLibraryFileGetsItsNumbers() {
        let m = MediaItem(url: "/x/Documents/Media/Classroom.of.the.Elite.S01E05.Hell.is.other.people.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR.mkv",
                          title: "Classroom of the Elite", source: .local)
        XCTAssertEqual(HeroCard.line(m, meta: nil), "S1 · E5 · Hell is other people")
    }
}
