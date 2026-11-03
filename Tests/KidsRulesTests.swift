import XCTest
@testable import Folio

/// The kids profile's rules (1.22.0): ratings from several systems on one
/// ladder, the genres when there's no rating, and unknown hidden.
final class KidsRulesTests: XCTestCase {
    private typealias L = KidsRules.Level
    private let pgShows = KidsRules.Limits(film: .pg, show: .tvPG)

    func testUSRatings() {
        XCTAssertEqual(KidsRules.level(ofRating: "G"), L.allAges)
        XCTAssertEqual(KidsRules.level(ofRating: "PG"), L.parentalGuidance)
        XCTAssertEqual(KidsRules.level(ofRating: "PG-13"), L.teens)
        XCTAssertEqual(KidsRules.level(ofRating: "R"), L.adults)
        XCTAssertEqual(KidsRules.level(ofRating: "TV-Y"), L.preschool)
        XCTAssertEqual(KidsRules.level(ofRating: "TV-Y7-FV"), L.youngKids)
        XCTAssertEqual(KidsRules.level(ofRating: "TV-G"), L.allAges)
        XCTAssertEqual(KidsRules.level(ofRating: "TV-14"), L.teens)
        XCTAssertEqual(KidsRules.level(ofRating: "TV-MA"), L.adults)
    }

    func testOtherSystems() {
        XCTAssertEqual(KidsRules.level(ofRating: "M"), L.teens, "Australia's M is about PG-13")
        XCTAssertEqual(KidsRules.level(ofRating: "MA15+"), L.adults)
        XCTAssertEqual(KidsRules.level(ofRating: "U"), L.allAges)
        XCTAssertEqual(KidsRules.level(ofRating: "12A"), L.teens)
        XCTAssertEqual(KidsRules.level(ofRating: "15"), L.adults)
        XCTAssertEqual(KidsRules.level(ofRating: "FSK 6"), L.parentalGuidance)
        XCTAssertEqual(KidsRules.level(ofRating: "FSK 0"), L.allAges)
        XCTAssertEqual(KidsRules.level(ofRating: "13+"), L.teens)
        XCTAssertEqual(KidsRules.level(ofRating: "+7"), L.parentalGuidance)
        XCTAssertEqual(KidsRules.level(ofRating: "Rated pg-13 "), L.teens, "spelling and spaces don't matter")
        XCTAssertEqual(KidsRules.level(ofRating: "US: TV-PG"), L.parentalGuidance, "a region in front")
    }

    func testRatingsThatSayNothing() {
        for r in ["Not Rated", "Unrated", "NR", "Approved", "", "Something new"] {
            XCTAssertNil(KidsRules.level(ofRating: r), r)
        }
    }

    func testFilmLimits() {
        func film(_ r: String, _ limit: KidsRules.FilmLimit) -> KidsRules.Verdict {
            KidsRules.verdict(rating: r, genres: nil, isSeries: false, limits: KidsRules.Limits(film: limit, show: .tvPG))
        }
        XCTAssertEqual(film("G", .g), .allowed)
        XCTAssertEqual(film("PG", .g), .above("PG"))
        XCTAssertEqual(film("PG", .pg), .allowed)
        XCTAssertEqual(film("PG-13", .pg), .above("PG-13"))
        XCTAssertEqual(film("PG-13", .pg13), .allowed)
        XCTAssertEqual(film("M", .pg13), .allowed)
        XCTAssertEqual(film("R", .pg13), .above("R"))
        XCTAssertEqual(film("TV-Y7", .g), .allowed, "a TV rating on a film goes on the same ladder")
    }

    func testShowLimitsInTheirOrder() {
        func show(_ r: String, _ limit: KidsRules.ShowLimit) -> Bool {
            KidsRules.verdict(rating: r, genres: nil, isSeries: true, limits: KidsRules.Limits(film: .pg13, show: limit)) == .allowed
        }
        // TV-Y < TV-Y7 < TV-G < TV-PG, as Settings lists them.
        XCTAssertTrue(show("TV-Y", .tvY))
        XCTAssertFalse(show("TV-Y7", .tvY))
        XCTAssertTrue(show("TV-Y7", .tvY7))
        XCTAssertFalse(show("TV-G", .tvY7))
        XCTAssertTrue(show("TV-G", .tvG))
        XCTAssertFalse(show("TV-PG", .tvG))
        XCTAssertTrue(show("TV-PG", .tvPG))
        XCTAssertFalse(show("TV-14", .tvPG))
        XCTAssertFalse(show("PG-13", .tvPG), "a show limit is used for a show whatever its rating's system")
    }

    func testGenresWhenThereIsNoRating() {
        XCTAssertEqual(KidsRules.verdict(rating: nil, genres: ["Animation", "Comedy"], isSeries: false, limits: pgShows), .allowed)
        XCTAssertEqual(KidsRules.verdict(rating: "Not Rated", genres: ["Family"], isSeries: false, limits: pgShows), .allowed)
        XCTAssertEqual(KidsRules.verdict(rating: nil, genres: ["Animation", "Horror"], isSeries: false, limits: pgShows), .unknown)
        XCTAssertEqual(KidsRules.verdict(rating: nil, genres: ["Animation", "Anime", "Action"], isSeries: true, limits: pgShows), .unknown, "anime goes by its rating")
        XCTAssertEqual(KidsRules.verdict(rating: nil, genres: ["Drama"], isSeries: false, limits: pgShows), .unknown)
        XCTAssertEqual(KidsRules.verdict(rating: nil, genres: ["Family"], isSeries: true, limits: KidsRules.Limits(film: .pg, show: .tvY)), .unknown,
                       "genres count as G: not enough for a TV-Y limit")
    }

    func testRatingWinsOverGenres() {
        XCTAssertEqual(KidsRules.verdict(rating: "PG-13", genres: ["Family", "Animation"], isSeries: false, limits: pgShows), .above("PG-13"))
    }

    func testUnknownIsHidden() {
        XCTAssertEqual(KidsRules.verdict(rating: nil, genres: nil, isSeries: false, limits: pgShows), .unknown)
        XCTAssertFalse(KidsRules.allows(nil as MediaMeta?, limits: pgShows), "a library file Folio found nothing for")
    }

    func testMetaItemsAndLibraryMetadata() {
        var film = MetaItem(id: "tt1", type: "movie", name: "A", poster: nil, description: nil, releaseInfo: nil, imdbRating: nil, genres: ["Family"])
        XCTAssertTrue(KidsRules.allows(film, limits: pgShows))
        film.contentRating = "R"
        XCTAssertFalse(KidsRules.allows(film, limits: pgShows))
        var show = MediaMeta(id: "tt2", type: "series", name: "B", genres: ["Animation"])
        show.contentRating = "TV-Y7"
        XCTAssertTrue(KidsRules.allows(show, limits: pgShows))
        XCTAssertFalse(KidsRules.allows(show, limits: KidsRules.Limits(film: .pg13, show: .tvY)))
    }

    func testPasscodeIsKeptHashed() {
        let stored = KidsProfile.hashed("1234", salt: "abc")
        XCTAssertFalse(stored.contains("1234"))
        XCTAssertTrue(KidsProfile.matches("1234", stored: stored))
        XCTAssertFalse(KidsProfile.matches("4321", stored: stored))
        XCTAssertNotEqual(KidsProfile.hashed("1234", salt: KidsProfile.newSalt()), KidsProfile.hashed("1234", salt: KidsProfile.newSalt()))
        XCTAssertTrue(KidsProfile.isValid("0042"))
        XCTAssertFalse(KidsProfile.isValid("123"))
        XCTAssertFalse(KidsProfile.isValid("12a4"))
    }
}

private extension MediaMeta {
    init(id: String, type: String, name: String, genres: [String]) {
        self.init(id: id, type: type, name: name, poster: nil, background: nil, logo: nil, description: nil, year: nil, rating: nil, genres: genres)
    }
}
