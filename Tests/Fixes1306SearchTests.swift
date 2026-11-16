import XCTest
@testable import Folio

/// 1.30.6: the Search tab's fuller lists asked less (from 3 characters,
/// after a longer pause, once the suggestions have answered; empty answers
/// kept a few minutes), the last text's lists kept up, dimmed, until the new
/// ones answer, the pause counted as loading, the hints only when they're
/// true (answered, not offline; a count only when it's all of Search's).
@MainActor
final class Fixes1306SearchTests: XCTestCase {
    override func setUp() { DiscoverSearch.forgetEmptyAnswers() }
    override func tearDown() { DiscoverSearch.forgetEmptyAnswers() }

    private func meta(_ n: Int, series: Bool = false) -> MetaItem {
        MetaItem(id: "tt\(n)", type: series ? "series" : "movie", name: "Title \(n)", poster: nil, description: nil,
                 releaseInfo: "2024", imdbRating: nil, genres: nil)
    }

    // MARK: Asked less

    func testFullerListsWaitLongerAndForThreeCharacters() {
        XCTAssertEqual(DiscoverSearch.fullerMinLength, 3)
        XCTAssertEqual(DiscoverSearch.fullerPause, .milliseconds(900))
        XCTAssertGreaterThan(DiscoverSearch.fullerPause, DiscoverSearch.debounce, "the heavy pages wait longer than the suggestions")
        // The suggestions still start from 2.
        XCTAssertEqual(DiscoverSearch.minLength, 2)
    }

    func testTheTypingPauseIsLoadingFromThreeCharacters() {
        let s = DiscoverSearch()
        defer { s.reset() }
        s.textChanged("mo")
        s.loadBothKinds(for: "mo", wait: true)
        XCTAssertNil(s.fullerWaitingFor, "two characters asked the fuller lists")
        XCTAssertFalse(s.fullerBusy)
        s.textChanged("mon")
        s.loadBothKinds(for: "mon", wait: true)
        XCTAssertEqual(s.fullerWaitingFor, "mon")
        XCTAssertTrue(s.fullerBusy, "the pause isn't counted as loading")
        XCTAssertTrue(s.fullerLoading.isEmpty, "asked before the pause ended")
        // Typed on: nothing is waiting for the last text.
        s.textChanged("mo")
        XCTAssertNil(s.fullerWaitingFor)
        XCTAssertFalse(s.fullerBusy)
    }

    func testEmptyAnswersAreKeptAFewMinutes() {
        let t = Date()
        XCTAssertFalse(DiscoverSearch.knownEmpty("zqx", type: "movie", now: t))
        DiscoverSearch.noteEmpty("zqx", type: "movie", now: t)
        XCTAssertTrue(DiscoverSearch.knownEmpty("zqx", type: "movie", now: t.addingTimeInterval(60)))
        XCTAssertFalse(DiscoverSearch.knownEmpty("zqx", type: "series", now: t), "the other kind wasn't asked")
        XCTAssertFalse(DiscoverSearch.knownEmpty("zqxy", type: "movie", now: t), "another text")
        XCTAssertFalse(DiscoverSearch.knownEmpty("zqx", type: "movie", now: t.addingTimeInterval(DiscoverSearch.emptyKept + 1)), "kept for ever")
        XCTAssertEqual(DiscoverSearch.emptyKept, 300)
    }

    /// Both kinds known to be empty: answered at once, nothing waits or is asked.
    func testAKnownEmptyQueryAsksNothing() {
        DiscoverSearch.noteEmpty("zqx", type: "movie")
        DiscoverSearch.noteEmpty("zqx", type: "series")
        let s = DiscoverSearch()
        defer { s.reset() }
        s.textChanged("zqx")
        s.loadBothKinds(for: "zqx", wait: true)
        XCTAssertNil(s.fullerWaitingFor)
        XCTAssertTrue(s.fullerLoading.isEmpty)
        XCTAssertEqual(s.fuller["movie"]?.count, 0)
        XCTAssertEqual(s.fuller["series"]?.count, 0)
        XCTAssertTrue(s.fullerCounted(for: "zqx"), "both kinds are known")
    }

    /// One kind known to be empty: it's answered now, the other waits for the pause.
    func testOneKnownEmptyKindIsAnsweredTheOtherWaits() {
        DiscoverSearch.noteEmpty("zqx", type: "movie")
        let s = DiscoverSearch()
        defer { s.reset() }
        s.textChanged("zqx")
        s.loadBothKinds(for: "zqx", wait: true)
        XCTAssertEqual(s.fullerWaitingFor, "zqx")
        XCTAssertEqual(s.fuller["movie"]?.count, 0)
        XCTAssertNil(s.fuller["series"])
        XCTAssertFalse(s.fullerCounted(for: "zqx"), "the shows aren't known yet")
    }

    // MARK: The last text's lists kept, dimmed

    func testTheLastTextsFullerListsAreStaleUntilReplaced() {
        let suggestions = [meta(1), meta(2, series: true)]
        let fuller = ["movie": [meta(1), meta(3), meta(4)], "series": [meta(5, series: true)]]
        // Both kinds answer "mon"; the field now says "mons".
        let stale = DiscoverSearch.staleIDs(suggestions: suggestions, fuller: fuller, fullerFor: ["movie": "mon", "series": "mon"], query: "mons")
        XCTAssertEqual(stale, ["tt3", "tt4", "tt5"], "a title the new suggestions have isn't stale")
        // The movies have answered "mons": only the shows are the last text's.
        let half = DiscoverSearch.staleIDs(suggestions: suggestions, fuller: fuller, fullerFor: ["movie": "mons", "series": "mon"], query: "mons")
        XCTAssertEqual(half, ["tt5"])
        XCTAssertTrue(DiscoverSearch.staleIDs(suggestions: suggestions, fuller: fuller, fullerFor: ["movie": "mons", "series": "mons"], query: "mons").isEmpty)
    }

    func testStaleRowsAreListedButNotCounted() {
        let suggestions = [meta(1), meta(2, series: true)]
        let fuller = ["movie": [meta(3), meta(4)], "series": [meta(5, series: true)]]
        let imdb = DiscoverSearch.merged(suggestions, fuller: fuller)
        let r = SearchResults(imdb: imdb, stale: ["tt3", "tt5"])
        // Listed, in their places: nothing jumps.
        XCTAssertEqual(r.filtered(nil).map(\.id), ["title|tt1", "title|tt2", "title|tt3", "title|tt4", "title|tt5"])
        XCTAssertEqual(r.stale, ["title|tt3", "title|tt5"])
        // Counted for the hint: only this text's.
        XCTAssertEqual(r.count(.search), 3)
        XCTAssertEqual(SearchResults(imdb: imdb).count(.search), 5)
        // An id not on the list isn't counted against it.
        XCTAssertEqual(SearchResults(imdb: suggestions, stale: ["tt9"]).count(.search), 2)
    }

    /// Too short for the fuller lists: the suggestions are all the Search tab lists, so they can be counted.
    func testShortTextIsCountedLongerWaitsForTheFullerLists() {
        let s = DiscoverSearch()
        XCTAssertTrue(s.fullerCounted(for: "mo"))
        XCTAssertFalse(s.fullerCounted(for: "mon"))
    }

    // MARK: The hints

    func testTheLibraryHintCountsOnlyWhatsAllKnown() {
        XCTAssertEqual(SearchTab.hint(on: .library, owned: 0, titles: 8, settled: true, counted: false),
                       SearchTab.Hint(text: "Nothing in your library — results in Search", target: .search))
        XCTAssertEqual(SearchTab.hint(on: .library, owned: 0, titles: 57, settled: true, counted: true),
                       SearchTab.Hint(text: "Nothing in your library — 57 results in Search", target: .search))
        // The same rules as before otherwise.
        XCTAssertNil(SearchTab.hint(on: .library, owned: 0, titles: 0, settled: true, counted: false))
        XCTAssertNil(SearchTab.hint(on: .library, owned: 1, titles: 8, settled: true, counted: false))
        XCTAssertNil(SearchTab.hint(on: .library, owned: 0, titles: 8, settled: false, counted: false))
    }

    /// Offline isn't "nothing found": the Search tab's hint needs IMDb's answer.
    func testTheSearchHintNeedsAnAnswerNotAFailure() {
        let offline = DiscoverSearch.Phase.failed(offline: true)
        XCTAssertFalse(AddonSearchView.titlesSettled(offline, fullerBusy: false, addonsSearching: false, answeredOnly: true))
        XCTAssertTrue(AddonSearchView.titlesSettled(offline, fullerBusy: false, addonsSearching: false, answeredOnly: false),
                      "the Library tab stops waiting for a failure")
        XCTAssertTrue(AddonSearchView.titlesSettled(.done, fullerBusy: false, addonsSearching: false, answeredOnly: true))
        // Still on the way: the pause or the fuller lists, the addons, IMDb.
        XCTAssertFalse(AddonSearchView.titlesSettled(.done, fullerBusy: true, addonsSearching: false, answeredOnly: true))
        XCTAssertFalse(AddonSearchView.titlesSettled(.done, fullerBusy: false, addonsSearching: true, answeredOnly: false))
        XCTAssertFalse(AddonSearchView.titlesSettled(.loading, fullerBusy: false, addonsSearching: false, answeredOnly: false))
        XCTAssertFalse(AddonSearchView.titlesSettled(.idle, fullerBusy: false, addonsSearching: false, answeredOnly: false))
    }

    /// The Library tab's empty state waits for Search at most this long.
    func testTheLibraryTabWaitsForSearchAMoment() {
        XCTAssertEqual(AddonSearchView.searchWait, .milliseconds(1500))
    }
}
