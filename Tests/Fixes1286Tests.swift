import XCTest
@testable import Folio

/// 1.28.6: the first fixes from the whole-app review.
@MainActor
final class Fixes1286Tests: XCTestCase {
    /// IMDb's popularity rank is kept with a cached search answer: 1.28.5
    /// fetched it but dropped it on the way to the cache, so the poster
    /// tie-break (Cowboy Bebop 1998 or 2021) only worked on a fresh answer.
    func testThePopularityRankSurvivesTheCache() throws {
        var m = MetaItem(id: "tt0213338", type: "series", name: "Cowboy Bebop", poster: nil, description: nil,
                         releaseInfo: "1998", imdbRating: nil, genres: nil)
        m.popularityRank = 1880
        let back = try JSONDecoder().decode([MetaItem].self, from: JSONEncoder().encode([m]))
        XCTAssertEqual(back.first?.popularityRank, 1880)
        // An answer kept before 1.28.6 has none, and still reads.
        let old = #"[{"id":"tt1","type":"movie","name":"A"}]"#
        XCTAssertNil(try JSONDecoder().decode([MetaItem].self, from: Data(old.utf8)).first?.popularityRank)
    }

    /// Notification Test is off unless it's turned on: it was the default,
    /// so no real notification was planned and new-episode alerts were held.
    func testNotificationTestIsOffByDefault() {
        SettingsKey.registerDefaults()
        let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        XCTAssertEqual(registered[SettingsKey.notifyTest] as? Bool, false)
    }

    /// A web page where a video was asked for is refused on the background
    /// path too (the same test the in-app engine uses).
    func testAWebPageIsNotAVideo() {
        XCTAssertTrue(ChunkPlan.isPage(contentType: "text/html; charset=utf-8", fileName: "Film.2024.1080p.mkv"))
        XCTAssertFalse(ChunkPlan.isPage(contentType: "video/x-matroska", fileName: "Film.2024.1080p.mkv"))
        XCTAssertFalse(ChunkPlan.isPage(contentType: nil, fileName: "Film.mkv"))
        XCTAssertFalse(ChunkPlan.isPage(contentType: "text/html", fileName: "page.html"), "a page that was asked for")
    }

    /// One entry this version can't read doesn't lose the rest of a saved list.
    func testASavedListReadsEntryByEntry() throws {
        let meta = MetaItem(id: "tt1", type: "movie", name: "A", poster: nil, description: nil, releaseInfo: nil, imdbRating: nil, genres: nil)
        let good = WatchlistItem(meta: meta, added: Date(timeIntervalSince1970: 1_800_000_000))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let one = try XCTUnwrap(String(data: enc.encode(good), encoding: .utf8))
        let mixed = Data("[\(one),{\"nonsense\":true},\(one)]".utf8)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        XCTAssertNil(try? dec.decode([WatchlistItem].self, from: mixed), "the whole list doesn't decode")
        XCTAssertEqual(dec.decodeLossy(WatchlistItem.self, from: mixed)?.count, 2)
    }
}
