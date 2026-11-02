import XCTest
@testable import Folio

/// Discover's For you row (1.20.3): seeds from the history, "More like this"
/// from IMDb's page data, the merge and ranking; and two IMDb fixes from the
/// same review: "/" in a search, a related title's facts on the main one.
final class ForYouTests: XCTestCase {
    // MARK: Fixtures

    private func meta(_ id: String, _ name: String, _ type: String = "movie", year: String? = nil, original: String? = nil) -> MetaItem {
        var m = MetaItem(id: id, type: type, name: name, poster: "https://p/\(id).jpg", description: nil, releaseInfo: year, imdbRating: nil, genres: nil)
        m.originalName = original
        return m
    }

    private func c(_ seed: String, _ m: MetaItem, votes: Int = 0) -> ForYou.Candidate {
        ForYou.Candidate(seed: seed, meta: m, votes: votes)
    }

    /// A title page as IMDb's own page data has it, cut down: the title
    /// (above the fold, and the main column with "More like this"), and a
    /// person's known-for list that is not a recommendation.
    private let page = """
    <html><head><script id="__NEXT_DATA__" type="application/json">
    {"props":{"pageProps":{
      "aboveTheFoldData":{"id":"tt0000001","titleText":{"text":"Main Title"},"originalTitleText":{"text":"Main Title"},
        "titleType":{"id":"tvSeries"},"genres":{"genres":[{"text":"Animation"},{"text":"Comedy"}]},
        "countriesOfOrigin":{"countries":[{"id":"US"}]}},
      "mainColumnData":{"id":"tt0000001",
        "moreLikeThisTitles":{"edges":[
          {"node":{"id":"tt1000001","titleText":{"text":"Like One"},"originalTitleText":{"text":"Rabo Wan"},"titleType":{"id":"tvSeries"},
            "primaryImage":{"url":"https://m.media-amazon.com/images/M/one._V1_.jpg"},"releaseYear":{"year":2011},
            "ratingsSummary":{"aggregateRating":8.1,"voteCount":120000},"titleGenres":{"genres":[{"genre":{"text":"Drama"}}]},
            "plot":{"plotText":{"plainText":"Not the main title's plot."}},"countriesOfOrigin":{"countries":[{"id":"JP"}]},
            "primaryVideos":{"edges":[{"node":{"thumbnail":{"url":"https://m.media-amazon.com/images/M/trailer._V1_.jpg"}}}]}}},
          {"node":{"id":"tt1000002","titleText":{"text":"Like Two"},"titleType":{"id":"movie"},"releaseYear":{"year":2019},
            "ratingsSummary":{"aggregateRating":7.0,"voteCount":5000},"currentRank":4}},
          {"node":{"id":"tt1000003","titleText":{"text":"An Episode"},"titleType":{"id":"tvEpisode"}}}
        ]},
        "knownFor":{"edges":[{"node":{"id":"tt2000001","titleText":{"text":"Someone's Other Work"},"titleType":{"id":"movie"}}}]}
      }
    }}}
    </script></head><body></body></html>
    """

    // MARK: More like this

    func testMoreLikeThisFromPageData() {
        // The title itself in its own list is left out too.
        let withItself = page.replacingOccurrences(of: "\"moreLikeThisTitles\":{\"edges\":[",
                                                   with: "\"moreLikeThisTitles\":{\"edges\":[{\"node\":{\"id\":\"tt0000001\",\"titleText\":{\"text\":\"Main Title\"}}},")
        XCTAssertNotEqual(withItself, page)
        let list = IMDbSource.moreLikeThis(page: withItself, id: "tt0000001", hint: "series")
        XCTAssertEqual(list.map(\.meta.id), ["tt1000001", "tt1000002"], "only the list's titles: not the title itself, an episode or a known-for")
        XCTAssertEqual(list.map(\.meta.type), ["series", "movie"])
        XCTAssertEqual(list.map(\.votes), [120000, 5000])
        let one = list[0].meta
        XCTAssertEqual(one.name, "Like One")
        XCTAssertEqual(one.originalName, "Rabo Wan")
        XCTAssertEqual(one.releaseInfo, "2011")
        XCTAssertEqual(one.imdbRating, "8.1")
        XCTAssertEqual(one.genres, ["Drama"])
        XCTAssertEqual(one.poster, "https://m.media-amazon.com/images/M/one._V1_QL80_UX240_.jpg")
        XCTAssertNil(list[1].meta.rank, "a chart position isn't shown on a recommendation")
    }

    func testNoListNoRecommendations() {
        let bare = "<script id=\"__NEXT_DATA__\" type=\"application/json\">{\"props\":{\"pageProps\":{\"aboveTheFoldData\":{\"id\":\"tt0000001\",\"titleText\":{\"text\":\"Main\"}}}}}</script>"
        XCTAssertTrue(IMDbSource.moreLikeThis(page: bare, id: "tt0000001", hint: "movie").isEmpty)
        XCTAssertTrue(IMDbSource.moreLikeThis(page: "<html>no data</html>", id: "tt0000001", hint: "movie").isEmpty)
    }

    /// Countries, plot, year and the trailer's picture come from the title
    /// itself, never from a "More like this" title: until 1.20.3 any object
    /// would do, so this American cartoon could take the related title's
    /// Japan (and so "Anime"), plot, year and trailer.
    func testDetailsFactsFromTheMainTitleOnly() throws {
        let m = try XCTUnwrap(IMDbSource.parseDetails(page: page, id: "tt0000001", hint: "series"))
        XCTAssertEqual(m.name, "Main Title")
        XCTAssertEqual(m.countries, ["US"])
        XCTAssertNil(m.description)
        XCTAssertNil(m.releaseInfo)
        XCTAssertNil(m.background)
        XCTAssertEqual(m.genres, ["Animation", "Comedy"], "not Anime: the title isn't from Japan")
    }

    /// The title's other object (the main column, with no title text of
    /// its own) is still the title's.
    func testDetailsStillReadTheTitlesOwnFacts() throws {
        let own = page.replacingOccurrences(of: "\"mainColumnData\":{\"id\":\"tt0000001\",",
                                            with: "\"mainColumnData\":{\"id\":\"tt0000001\",\"releaseYear\":{\"year\":2008},\"plot\":{\"plotText\":{\"plainText\":\"The main plot.\"}},"
                                                + "\"primaryVideos\":{\"edges\":[{\"node\":{\"thumbnail\":{\"url\":\"https://m.media-amazon.com/images/M/main._V1_.jpg\"}}}]},")
        XCTAssertNotEqual(own, page)
        let m = try XCTUnwrap(IMDbSource.parseDetails(page: own, id: "tt0000001", hint: "series"))
        XCTAssertEqual(m.releaseInfo, "2008")
        XCTAssertEqual(m.description, "The main plot.")
        XCTAssertEqual(m.background, "https://m.media-amazon.com/images/M/main._V1_QL80_UX1280_.jpg")
        XCTAssertEqual(m.countries, ["US"])
    }

    // MARK: Search with "/"

    func testSuggestionPathEscapesSlash() {
        XCTAssertEqual(IMDbSource.suggestionPath("fate/zero"), "fate%2Fzero")
        XCTAssertEqual(IMDbSource.suggestionPath("ac/dc"), "ac%2Fdc")
        XCTAssertEqual(IMDbSource.suggestionPath("the office"), "the_office")
        XCTAssertEqual(IMDbSource.suggestionPath("ocean's eleven"), "ocean's_eleven")
        XCTAssertEqual(IMDbSource.suggestionPath("what? #1 100%"), "what%3F_%231_100%25")
        XCTAssertEqual(IMDbSource.suggestionPath("amélie"), "am%C3%A9lie")
        let url = URL(string: "https://v3.sg.media-imdb.com/suggestion/x/\(IMDbSource.suggestionPath("fate/zero")!).json")
        XCTAssertEqual(url?.absoluteString, "https://v3.sg.media-imdb.com/suggestion/x/fate%2Fzero.json")
    }

    // MARK: Ranking

    /// More seeds first, then more ratings, then as the lists had them.
    func testRanksBySeedsThenPopularity() {
        let x = meta("tt0000010", "X"), y = meta("tt0000011", "Y"), z = meta("tt0000012", "Z"), w = meta("tt0000013", "W")
        let picks = ForYou.rank([c("tt1", x, votes: 100), c("tt1", y, votes: 5000), c("tt1", z, votes: 10), c("tt1", w, votes: 10),
                                 c("tt2", z, votes: 10), c("tt2", x, votes: 100)], watched: [])
        XCTAssertEqual(picks.map(\.meta.id), ["tt0000010", "tt0000012", "tt0000011", "tt0000013"])
        XCTAssertEqual(picks.map(\.seeds), [2, 2, 1, 1])
    }

    /// A seed recommending the same title twice (IMDb and TMDB) counts once.
    func testOneSeedCountsOnce() {
        let x = meta("tt0000010", "X", year: "2010"), y = meta("tt0000011", "Y", year: "2012")
        let picks = ForYou.rank([c("tt1", x, votes: 10), c("tt1", meta("tmdb:55", "X", year: "2010"), votes: 900),
                                 c("tt1", y, votes: 20), c("tt2", y, votes: 20)], watched: [])
        XCTAssertEqual(picks.map(\.meta.id), ["tt0000011", "tt0000010"])
        XCTAssertEqual(picks.map(\.seeds), [2, 1])
    }

    func testLeavesOutTheHistory() {
        let picks = ForYou.rank([c("tt1", meta("tt2", "The other seed")), c("tt1", meta("tt0000020", "Watched")),
                                 c("tt1", meta("tt0000021", "New"))], watched: ["tt1", "tt2", "tt0000020"])
        XCTAssertEqual(picks.map(\.meta.id), ["tt0000021"])
    }

    /// TMDB's title is IMDb's with the same name, kind and year (or a year
    /// apart): one tile, IMDb's, recommended by both seeds.
    func testTMDBTitleMeetsIMDbsByName() {
        let imdb = meta("tt0386676", "The Office", "series", year: "2005")
        let tmdb = meta("tmdb:2316", "The Office", "series", year: "2005")
        let film = meta("tmdb:9999", "The Office", "movie", year: "2005")
        let picks = ForYou.rank([c("tt1", imdb, votes: 700000), c("tt2", tmdb, votes: 4000), c("tt2", film, votes: 3)], watched: [])
        XCTAssertEqual(picks.map(\.meta.id), ["tt0386676", "tmdb:movie:9999"], "a film of the same name is another title")
        XCTAssertEqual(picks.first?.seeds, 2)
        XCTAssertEqual(picks.first?.meta.name, "The Office")

        let apart = ForYou.rank([c("tt2", meta("tmdb:1", "Amélie", year: "2002")), c("tt1", meta("tt0211915", "Amelie", year: "2001"))], watched: [])
        XCTAssertEqual(apart.map(\.meta.id), ["tt0211915"])
        XCTAssertEqual(apart.first?.seeds, 2)
        XCTAssertEqual(apart.first?.meta.name, "Amelie", "IMDb's tile, though TMDB's came first")

        let original = ForYou.rank([c("tt1", meta("tt0000030", "Spirited Away", year: "2001", original: "Sen to Chihiro no kamikakushi")),
                                    c("tt2", meta("tmdb:129", "Le Voyage de Chihiro", year: "2001", original: "Sen to Chihiro no kamikakushi"))], watched: [])
        XCTAssertEqual(original.map(\.meta.id), ["tt0000030"], "matched by the original title when the names are in other languages")
    }

    /// A TMDB title whose IMDb id is known is left out when you've watched
    /// it; so is a seed's own TMDB entry. Films and series with the same
    /// TMDB number stay two titles.
    func testTMDBTitlesAgainstTheHistory() {
        let got = meta("tmdb:1399", "Game of Thrones", "series", year: "2011")
        let seedItself = meta("tmdb:1396", "Breaking Bad", "series", year: "2008")
        let film = meta("tmdb:100", "Lock, Stock and Two Smoking Barrels", "movie", year: "1998")
        let show = meta("tmdb:100", "I Am Not an Animal", "series", year: "2004")
        let picks = ForYou.rank([c("tt0903747", got), c("tt0903747", seedItself), c("tt0903747", film), c("tt0903747", show)],
                                watched: ["tt0903747", "tt0944947", "tmdb:series:1396"],
                                imdbIDs: ["tmdb:series:1399": "tt0944947", "tmdb:movie:100": "tt0120735"])
        XCTAssertEqual(picks.map(\.meta.id), ["tt0120735", "tmdb:series:100"])
    }

    func testRowSize() {
        let many = (0..<40).map { c("tt1", meta(String(format: "tt%07d", 100 + $0), "T\($0)")) }
        XCTAssertEqual(ForYou.rank(many, watched: []).count, ForYou.rowSize)
    }

    // MARK: Seeds

    private func entry(_ key: String, ref: String? = nil, source: MediaSource = .addon(name: "Lab")) -> HistoryEntry {
        var item = MediaItem(url: "https://stream.example/\(key)", title: "x", source: source)
        item.historyKey = key
        item.addonRef = ref
        return HistoryEntry(item: item, position: 300, duration: 1000, updated: Date())
    }

    func testAddonTitles() {
        XCTAssertEqual(ForYou.addonTitle(entry("addon:tt0944947:1:3", ref: "series|tt0944947|tt0944947:1:3")), ForYou.Seed(id: "tt0944947", type: "series"))
        XCTAssertEqual(ForYou.addonTitle(entry("addon:tt0816692")), ForYou.Seed(id: "tt0816692", type: "movie"))
        XCTAssertEqual(ForYou.addonTitle(entry("addon:tt0944947:2:1", ref: "anime|kitsu:1|tt0944947:2:1")), ForYou.Seed(id: "tt0944947", type: "series"))
        XCTAssertNil(ForYou.addonTitle(entry("addon:kitsu:46474:5", ref: "anime|kitsu:46474|kitsu:46474:5")))
    }

    /// Up to five seeds, in the order given (Continue Watching first); a
    /// file with no IMDb id is skipped; every addon title is "watched".
    func testSeedsFromTheHistory() async {
        let shows = [entry("addon:tt0000101:1:1", ref: "series|tt0000101|tt0000101:1:1"),
                     entry("/Documents/Media/Home Video.mp4", source: .local),
                     entry("/Documents/Media/Known Film 2010.mkv", source: .local),
                     entry("addon:tt0000101:1:2", ref: "series|tt0000101|tt0000101:1:2"),
                     entry("addon:tt0000103"), entry("addon:tt0000104"), entry("addon:tt0000105"), entry("addon:tt0000106")]
        let all = shows + [entry("addon:tt0000900")]
        let h = await ForYou.history(shows, all: all) { e in
            e.item.url.contains("Known Film") ? ForYou.Seed(id: "tt0000102", type: "movie") : nil
        }
        XCTAssertEqual(h.seeds.map(\.id), ["tt0000101", "tt0000102", "tt0000103", "tt0000104", "tt0000105"])
        XCTAssertTrue(h.watched.isSuperset(of: ["tt0000101", "tt0000102", "tt0000106", "tt0000900"]))
    }

    func testNoSeedsWithoutIMDbIDs() async {
        let h = await ForYou.history([entry("/Documents/Media/Home Video.mp4", source: .local)], all: []) { _ in nil }
        XCTAssertTrue(h.seeds.isEmpty)
    }

    // MARK: Saved row

    func testSavedRowFreshness() {
        let now = Date()
        let saved = ForYou.Saved(date: now.addingTimeInterval(-3600), seeds: ["tt1", "tt2"], tmdb: false, metas: [], imdbIDs: [:])
        let seeds = [ForYou.Seed(id: "tt2"), ForYou.Seed(id: "tt1")]
        XCTAssertTrue(saved.isFresh(for: seeds, tmdb: false, now: now), "the same seeds in another order")
        XCTAssertFalse(saved.isFresh(for: seeds, tmdb: false, now: now.addingTimeInterval(12 * 3600)), "older than 12 hours")
        XCTAssertFalse(saved.isFresh(for: seeds + [ForYou.Seed(id: "tt3")], tmdb: false, now: now), "a new seed")
        XCTAssertFalse(saved.isFresh(for: seeds, tmdb: true, now: now), "a TMDB key added")
    }
}
