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
