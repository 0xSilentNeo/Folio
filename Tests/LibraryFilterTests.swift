import XCTest
@testable import Folio

/// Home's library filters (1.22.0): watched state, genre and year, with
/// "Unknown" for titles Folio has no metadata for.
final class LibraryFilterTests: XCTestCase {
    private typealias Facts = LibraryFilter.Facts

    private let comedy2019 = Facts(watch: .unwatched, genres: ["Comedy", "Family"], year: "2019")
    private let dramaWatched = Facts(watch: .watched, genres: ["Drama"], year: "2017")
    private let halfway = Facts(watch: .inProgress, genres: ["Comedy"], year: "2019")
    private let bare = Facts(watch: .unwatched, genres: [], year: nil)

    func testWatchState() {
        XCTAssertEqual(LibraryFilter.watchState(watched: [false, false], resumable: [false, false]), .unwatched)
        XCTAssertEqual(LibraryFilter.watchState(watched: [true, true], resumable: [false, false]), .watched)
        XCTAssertEqual(LibraryFilter.watchState(watched: [true, false], resumable: [false, false]), .inProgress, "some episodes watched")
        XCTAssertEqual(LibraryFilter.watchState(watched: [false], resumable: [true]), .inProgress, "a film part-way")
        XCTAssertEqual(LibraryFilter.watchState(watched: [], resumable: []), .unwatched)
    }

    func testAllMatchesEverything() {
        let f = LibraryFilter()
        XCTAssertFalse(f.isActive)
        for x in [comedy2019, dramaWatched, halfway, bare] { XCTAssertTrue(f.matches(x)) }
    }

    func testWatchFilter() {
        XCTAssertTrue(LibraryFilter(watch: .unwatched).matches(comedy2019))
        XCTAssertFalse(LibraryFilter(watch: .unwatched).matches(halfway))
        XCTAssertTrue(LibraryFilter(watch: .inProgress).matches(halfway))
        XCTAssertTrue(LibraryFilter(watch: .watched).matches(dramaWatched))
        XCTAssertFalse(LibraryFilter(watch: .watched).matches(comedy2019))
    }

    func testGenreAndYear() {
        XCTAssertTrue(LibraryFilter(genre: "comedy").matches(comedy2019), "genres match whatever their case")
        XCTAssertFalse(LibraryFilter(genre: "Comedy").matches(dramaWatched))
        XCTAssertTrue(LibraryFilter(year: "2019").matches(halfway))
        XCTAssertFalse(LibraryFilter(year: "2019").matches(dramaWatched))
        XCTAssertTrue(LibraryFilter(watch: .unwatched, genre: "Comedy", year: "2019").matches(comedy2019))
        XCTAssertFalse(LibraryFilter(watch: .unwatched, genre: "Comedy", year: "2019").matches(halfway), "all three must hold")
    }

    func testUnknown() {
        XCTAssertTrue(LibraryFilter(genre: LibraryFilter.unknown).matches(bare))
        XCTAssertFalse(LibraryFilter(genre: LibraryFilter.unknown).matches(comedy2019))
        XCTAssertTrue(LibraryFilter(year: LibraryFilter.unknown).matches(bare))
        XCTAssertFalse(LibraryFilter(year: LibraryFilter.unknown).matches(dramaWatched))
    }

    func testFolderMatchesWhenAnyTitleDoes() {
        let f = LibraryFilter(genre: "Drama")
        XCTAssertTrue(f.matches(any: [comedy2019, dramaWatched]))
        XCTAssertFalse(f.matches(any: [comedy2019, bare]))
        XCTAssertFalse(f.matches(any: []))
    }

    func testMenus() {
        let all = [comedy2019, dramaWatched, halfway, bare]
        XCTAssertEqual(LibraryFilter.genres(in: all), ["Comedy", "Drama", "Family", LibraryFilter.unknown])
        XCTAssertEqual(LibraryFilter.years(in: all), ["2019", "2017", LibraryFilter.unknown])
        XCTAssertEqual(LibraryFilter.genres(in: [comedy2019]), ["Comedy", "Family"], "no Unknown when every title has genres")
    }

    func testYear() {
        XCTAssertEqual(LibraryFilter.year(meta: "2017–2023", fileName: nil), "2017")
        XCTAssertEqual(LibraryFilter.year(meta: nil, fileName: "Bright Movie 2024.mp4"), "2024", "the release name's year when the metadata has none")
        XCTAssertNil(LibraryFilter.year(meta: nil, fileName: "Home video.mp4"))
    }

    func testSavedValues() {
        let f = LibraryFilter(watch: "inProgress", genre: "", year: "2019")
        XCTAssertEqual(f, LibraryFilter(watch: .inProgress, genre: nil, year: "2019"))
        XCTAssertEqual(LibraryFilter(watch: "something newer", genre: "", year: "").watch, .all, "an unknown saved value is All")
        XCTAssertEqual(f.summary, "In Progress · 2019")
    }

    func testEmptyMessage() {
        XCTAssertEqual(LibraryFilter(watch: .unwatched, genre: "Comedy", year: "2019").emptyMessage(kidsHidden: 0), "No unwatched titles in Comedy from 2019.")
        XCTAssertEqual(LibraryFilter(genre: LibraryFilter.unknown).emptyMessage(kidsHidden: 2), "No titles without a genre. The kids profile hides 2 more.")
    }
}
