import XCTest
@testable import GlassPlayer

/// Poster matching for release folders: the WebDAV browser script's scoring
/// (PS.pick) plus a minimum confidence — a weak match gets the placeholder,
/// never a wrong poster.
final class ReleaseMatchTests: XCTestCase {
    func c(_ id: String, _ name: String, _ year: Int?, _ kind: ReleaseMatch.Kind, pop: Double = 0, original: String? = nil) -> ReleaseMatch.Candidate {
        ReleaseMatch.Candidate(id: id, name: name, originalName: original, year: year, kind: kind, popularity: pop,
                               poster: "https://img.invalid/\(id).jpg", animation: false, japanese: false)
    }
    func release(_ folder: String) throws -> ReleaseName { try XCTUnwrap(ReleaseName.folder(folder)) }

    func testExactNameAndYear() throws {
        let r = ReleaseMatch.pick(try release("Obsession.2025.2160p.UHD.BluRay.REMUX-GRP"),
                                  [c("tt1", "Obsession", 1976, .movie), c("tt2", "Obsession", 2025, .movie)], source: "IMDb")
        XCTAssertTrue(r.confident, r.why)
        XCTAssertEqual(r.imdbID, "tt2", "the year picks the right one")
    }

    func testYearTooFarIsNoMatch() throws {
        let r = ReleaseMatch.pick(try release("Obsession.2025.1080p.WEB-DL-GRP"), [c("tt1", "Obsession", 1976, .movie)], source: "IMDb")
        XCTAssertFalse(r.confident, "a 1976 film for a 2025 release is a wrong poster")
    }

    func testSeasonPackPrefersTheSeries() throws {
        let r = ReleaseMatch.pick(try release("Dark.S01.1080p.NF.WEB-DL-GRP"),
                                  [c("tt5", "Dark", 2005, .movie), c("tt6", "Dark", 2017, .series)], source: "IMDb")
        XCTAssertTrue(r.confident, r.why)
        XCTAssertEqual(r.imdbID, "tt6")
    }

    func testSameNameNoYearIsAPlaceholder() throws {
        let r = ReleaseMatch.pick(try release("Dark.S01.1080p.WEB-DL-GRP"),
                                  [c("tt6", "Dark", 2017, .series), c("tt7", "Dark", 2009, .series)], source: "IMDb")
        XCTAssertFalse(r.confident, "two series called Dark and no year to choose")
        XCTAssertTrue(r.why.contains("2 titles"), r.why)
    }

    func testFarMorePopularOnTMDBDecides() throws {
        let r = ReleaseMatch.pick(try release("Dark.S01.1080p.WEB-DL-GRP"),
                                  [c("tmdb:tv:1", "Dark", 2017, .series, pop: 90), c("tmdb:tv:2", "Dark", 2009, .series, pop: 4)], source: "TMDB")
        XCTAssertTrue(r.confident, r.why)
        XCTAssertEqual(r.year, 2017)
    }

    func testOriginalNameCounts() throws {
        let r = ReleaseMatch.pick(try release("[SubsPlease] Sousou no Frieren S01 (1080p)"),
                                  [c("tt9", "Frieren: Beyond Journey's End", 2023, .series, original: "Sousou no Frieren")], source: "IMDb")
        XCTAssertTrue(r.confident, r.why)
    }

    func testOnlyRelatedNameIsAPlaceholder() throws {
        let r = ReleaseMatch.pick(try release("The.Office.S01.1080p.WEB-DL-GRP"),
                                  [c("tt3", "The Office Christmas Party", 2016, .movie)], source: "IMDb")
        XCTAssertFalse(r.confident, r.why)
    }

    func testNothingFound() throws {
        XCTAssertFalse(ReleaseMatch.pick(try release("Show.S01.1080p.WEB-DL-GRP"), [], source: "IMDb").confident)
    }
}
