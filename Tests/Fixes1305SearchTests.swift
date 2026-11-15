import XCTest
@testable import Folio

/// 1.30.5: the search's two tabs (Library and Search, the user's design),
/// the Search tab's Shows and Movies pills, the tab kept across launches,
/// and the hint when the chosen tab found nothing but the other did.
@MainActor
final class Fixes1305SearchTests: XCTestCase {
    private func meta(_ n: Int, series: Bool = false) -> MetaItem {
        MetaItem(id: "tt\(n)", type: series ? "series" : "movie", name: "Title \(n)", poster: nil, description: nil,
                 releaseInfo: "2024", imdbRating: nil, genres: nil)
    }

    private func entry(_ n: Int) -> SearchItem {
        SearchItem(entry: CatalogEntry(id: "e\(n)", kind: .movie, name: "Film \(n)"), server: MediaServer(kind: .plex, name: "Plex"))
    }

    // MARK: The tabs

    func testTwoTabsNoAll() {
        XCTAssertEqual(SearchTab.allCases, [.library, .search])
        XCTAssertEqual(SearchTab.allCases.map(\.title), ["Library", "Search"])
        // The identifiers the UI tests find them by: searchTab:library, searchTab:search.
        XCTAssertEqual(SearchTab.allCases.map(\.rawValue), ["library", "search"])
    }

    /// Library: the top card and everything else that's yours; Search:
    /// IMDb's titles then the addons', each once, and nothing of yours.
    func testWhatEachTabHolds() {
        let owned = [entry(1), entry(2), entry(3)]
        let addon = AddonSearchView.SearchResult(id: "a", title: "Catalog", addon: nil, metas: [meta(2), meta(4, series: true)])
        let r = SearchResults(owned: owned, imdb: [meta(1), meta(2), meta(3, series: true)], addons: [addon])
        XCTAssertEqual(r.top?.id, owned[0].id)
        XCTAssertEqual(r.ownedRest.map(\.id), [owned[1].id, owned[2].id])
        XCTAssertEqual(r.count(.library), 3)
        XCTAssertEqual(r.filtered(nil).map(\.id), ["title|tt1", "title|tt2", "title|tt3", "title|tt4"])
        XCTAssertTrue(r.filtered(nil).allSatisfy(\.isTitle))
        XCTAssertEqual(r.count(.search), 4)
    }

    // MARK: Shows and Movies

    func testNoPillListsEveryTitleAndOnePillItsKind() {
        let r = SearchResults(imdb: [meta(1), meta(2, series: true), meta(3), meta(4, series: true)])
        XCTAssertEqual(r.filtered(nil).map(\.id), ["title|tt1", "title|tt2", "title|tt3", "title|tt4"])
        XCTAssertEqual(r.filtered(.shows).map(\.id), ["title|tt2", "title|tt4"])
        XCTAssertEqual(r.filtered(.movies).map(\.id), ["title|tt1", "title|tt3"])
        // The hint counts the tab, whatever pill is chosen.
        XCTAssertEqual(r.count(.search), 4)
    }

    func testAPillTappedAgainClearsIt() {
        XCTAssertEqual(SearchKindFilter.toggled(nil, by: .shows), .shows)
        XCTAssertNil(SearchKindFilter.toggled(.shows, by: .shows))
        // One at a time: the other pill takes over.
        XCTAssertEqual(SearchKindFilter.toggled(.shows, by: .movies), .movies)
        XCTAssertEqual(SearchKindFilter.allCases.map(\.title), ["Shows", "Movies"])
    }

    func testAPillAsksForItsKindsFullerList() {
        XCTAssertEqual(SearchKindFilter.shows.imdbType, "series")
        XCTAssertEqual(SearchKindFilter.movies.imdbType, "movie")
        // The Search tab's pause asks both kinds, each once a query.
        XCTAssertTrue(DiscoverSearch.shouldAskFuller(type: "movie", query: "dune", current: "dune", asked: ["series"]))
        XCTAssertFalse(DiscoverSearch.shouldAskFuller(type: "movie", query: "dune", current: "dune", asked: ["series", "movie"]))
    }

    /// The filter isn't kept: the same search typed on or back keeps it,
    /// another text starts on every title.
    func testANewQueryStartsOnEveryTitle() {
        XCTAssertTrue(SearchKindFilter.keeps(from: "mon", to: "mono"))
        XCTAssertTrue(SearchKindFilter.keeps(from: "mono", to: "mon"))
        XCTAssertTrue(SearchKindFilter.keeps(from: "Mon", to: " mon  "), "case and spaces aren't another query")
        XCTAssertFalse(SearchKindFilter.keeps(from: "mon", to: "dune"))
        XCTAssertFalse(SearchKindFilter.keeps(from: "", to: "mon"))
        XCTAssertFalse(SearchKindFilter.keeps(from: "mon", to: ""))
    }

    // MARK: The tab kept

    func testTheTabKeptDefaultsToLibrary() {
        XCTAssertEqual(SettingsKey.searchTabLast, "searchTabLast")
        SettingsKey.registerDefaults()
        let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        XCTAssertEqual(registered[SettingsKey.searchTabLast] as? String, "library")
        XCTAssertEqual(SearchTab.remembered(nil), .library)
        XCTAssertEqual(SearchTab.remembered("library"), .library)
        XCTAssertEqual(SearchTab.remembered("search"), .search)
        // Something this version doesn't know (an old chip's name): Library.
        XCTAssertEqual(SearchTab.remembered("yours"), .library)
    }

    func testTheTabIsReadBackFromItsKey() throws {
        let name = "Fixes1305SearchTests.tab"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        XCTAssertEqual(SearchTab.remembered(d.string(forKey: SettingsKey.searchTabLast)), .library)
        d.set(SearchTab.search.rawValue, forKey: SettingsKey.searchTabLast)
        XCTAssertEqual(SearchTab.remembered(d.string(forKey: SettingsKey.searchTabLast)), .search)
        d.set(SearchTab.library.rawValue, forKey: SettingsKey.searchTabLast)
        XCTAssertEqual(SearchTab.remembered(d.string(forKey: SettingsKey.searchTabLast)), .library)
    }

    // MARK: The hint

    func testTheHintPointsAtTheOtherTab() {
        let toSearch = SearchTab.hint(on: .library, owned: 0, titles: 12, settled: true)
        XCTAssertEqual(toSearch, SearchTab.Hint(text: "Nothing in your library — 12 results in Search", target: .search))
        let toLibrary = SearchTab.hint(on: .search, owned: 1, titles: 0, settled: true)
        XCTAssertEqual(toLibrary, SearchTab.Hint(text: "No movies or shows found — 1 result in Library", target: .library))
    }

    func testNoHintWhenItWouldntHelp() {
        // The tab found something.
        XCTAssertNil(SearchTab.hint(on: .library, owned: 2, titles: 12, settled: true))
        XCTAssertNil(SearchTab.hint(on: .search, owned: 3, titles: 5, settled: true))
        // Neither did.
        XCTAssertNil(SearchTab.hint(on: .library, owned: 0, titles: 0, settled: true))
        XCTAssertNil(SearchTab.hint(on: .search, owned: 0, titles: 0, settled: true))
        // Still looking: no hint yet.
        XCTAssertNil(SearchTab.hint(on: .library, owned: 0, titles: 12, settled: false))
        XCTAssertNil(SearchTab.hint(on: .search, owned: 3, titles: 0, settled: false))
    }

    func testResultCounts() {
        XCTAssertEqual(SearchTab.results(1), "1 result")
        XCTAssertEqual(SearchTab.results(12), "12 results")
    }
}
