import XCTest
@testable import Folio

/// Discover's For you row in the kids profile (1.22.1): only titles whose
/// own rating is known and within the limits. 1.22.0 went by the tile,
/// which has no rating (IMDb's "More like this" and TMDB's recommendations
/// give none), so KidsRules' genre guess decided, and an animated show
/// rated 13+ counted as G.
final class KidsForYouTests: XCTestCase {
    private let pg = KidsRules.Limits(film: .pg, show: .tvPG)

    private func tile(_ id: String, _ type: String = "series", genres: [String]? = nil, rating: String? = nil) -> MetaItem {
        var m = MetaItem(id: id, type: type, name: id, poster: nil, description: nil, releaseInfo: "2024", imdbRating: "8.0", genres: genres)
        m.contentRating = rating
        return m
    }

    /// The reported case: an animated show above the limit, in the row.
    func testAnAnimatedTeenShowIsHidden() {
        let show = tile("tt0000013", genres: ["Animation", "Action", "Adventure"])
        XCTAssertTrue(KidsRules.allows(show, limits: pg), "the cause: with no rating, the genres alone count it as G")
        XCTAssertEqual(ForYou.kidsRow([show], ratings: ["tt0000013": "13+"], limits: pg), [], "its title page says 13+")
        XCTAssertEqual(ForYou.kidsRow([show], ratings: ["tt0000013": "TV-14"], limits: pg), [])
        XCTAssertEqual(ForYou.kidsRow([show], ratings: ["tt0000013": "M"], limits: pg), [], "Australia's M is about PG-13")
    }

    func testUnknownAndUnratedTitlesAreHidden() {
        let family = tile("tt0000001", "movie", genres: ["Family", "Animation"])
        XCTAssertEqual(ForYou.kidsRow([family], ratings: [:], limits: pg), [], "not looked up yet, or the page couldn't be loaded")
        XCTAssertEqual(ForYou.kidsRow([family], ratings: ["tt0000001": ""], limits: pg), [], "the title page has no rating")
        for unrated in ["Not Rated", "Unrated", "NR", "Approved", "something new"] {
            XCTAssertEqual(ForYou.kidsRow([family], ratings: ["tt0000001": unrated], limits: pg), [], unrated)
        }
        XCTAssertEqual(ForYou.kidsRow([tile("tmdb:series:100", genres: ["Family"])], ratings: [:], limits: pg), [],
                       "a TMDB title with no IMDb page to read a rating from")
    }

    func testTitlesRatedWithinTheLimitsAreShown() {
        let a = tile("tt0000002", genres: ["Animation"])
        let b = tile("tt0000003", "movie", genres: ["Comedy"])
        let c = tile("tt0000004", "movie")
        let d = tile("tt0000005", rating: "TV-G")             // a tile that does carry a rating
        let row = ForYou.kidsRow([a, b, c, d], ratings: ["tt0000002": "TV-Y7", "tt0000003": "PG", "tt0000004": "PG-13"], limits: pg)
        XCTAssertEqual(row.map(\.id), ["tt0000002", "tt0000003", "tt0000005"], "in the row's order")
        // A higher film limit lets the PG-13 film in.
        let teens = KidsRules.Limits(film: .pg13, show: .tvPG)
        XCTAssertEqual(ForYou.kidsRow([c], ratings: ["tt0000004": "PG-13"], limits: teens).map(\.id), ["tt0000004"])
        // The tile's own rating wins over a looked-up one.
        XCTAssertEqual(ForYou.kidsRow([tile("tt0000006", rating: "TV-MA")], ratings: ["tt0000006": "TV-Y"], limits: pg), [])
    }

    func testTheRatingAloneDecides() {
        XCTAssertEqual(KidsRules.ratedVerdict(rating: nil, isSeries: true, limits: pg), .unknown)
        XCTAssertEqual(KidsRules.ratedVerdict(rating: "TV-PG", isSeries: true, limits: pg), .allowed)
        XCTAssertEqual(KidsRules.ratedVerdict(rating: "13+", isSeries: true, limits: pg), .above("13+"))
        XCTAssertEqual(KidsRules.ratedVerdict(rating: "PG", isSeries: false, limits: KidsRules.Limits(film: .g, show: .tvPG)), .above("PG"))
    }
}
