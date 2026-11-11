import XCTest
@testable import Folio

/// One watched state for the library's and Discover's title pages (1.30.0,
/// WatchedState). UX audit: a show watched from your own files looked
/// unwatched in Discover, so Continue Season started at E1.
final class WatchedState1300Tests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ key: String, position: Double, duration: Double = 3000, watched: Bool? = nil, age: TimeInterval = 0) -> HistoryEntry {
        var item = MediaItem(url: key, title: "T", source: .local)
        item.historyKey = key
        return HistoryEntry(item: item, position: position, duration: duration, updated: t0.addingTimeInterval(-age), watched: watched)
    }

    // MARK: Identity

    func testAFilesIdentityIsTheAddonEntrys() {
        let p = TitleParser.Parsed(title: "MobLand", season: 1, episode: 5)
        let id = WatchedState.identity(imdb: "tt31510819", type: "series", parsed: p, metaSeason: nil, metaEpisode: nil)
        XCTAssertEqual(id, "tt31510819:1:5")
        XCTAssertEqual(id.map(WatchedState.addonKey), "addon:tt31510819:1:5", "the key Discover's page reads")
        XCTAssertEqual(WatchedState.identity(videoID: "tt31510819:1:5"), id, "the addon video's identity is the same")
    }

    func testAnAbsoluteNumberTakesIMDbsSeasonAndEpisode() {
        let p = TitleParser.Parsed(title: "Attack on Titan", season: nil, episode: 26)
        XCTAssertEqual(WatchedState.identity(imdb: "tt2560140", type: "series", parsed: p, metaSeason: 2, metaEpisode: 1), "tt2560140:2:1")
        XCTAssertNil(WatchedState.identity(imdb: "tt2560140", type: "series", parsed: p, metaSeason: nil, metaEpisode: nil),
                     "no season known: not linked, rather than guessed")
    }

    func testAFilmAndWhatHasNoIdentity() {
        let film = TitleParser.Parsed(title: "Interstellar", year: 2014)
        XCTAssertEqual(WatchedState.identity(imdb: "tt0816692", type: "movie", parsed: film, metaSeason: nil, metaEpisode: nil), "tt0816692")
        XCTAssertNil(WatchedState.identity(imdb: "tt0816692", type: "series", parsed: film, metaSeason: nil, metaEpisode: nil), "a series' file with no episode")
        XCTAssertNil(WatchedState.identity(imdb: nil, type: "movie", parsed: film, metaSeason: nil, metaEpisode: nil), "no match")
        XCTAssertNil(WatchedState.identity(imdb: "kitsu:1", type: "movie", parsed: film, metaSeason: nil, metaEpisode: nil), "not an IMDb id")
        var oad = TitleParser.Parsed(title: "Show", season: 1, episode: 2)
        oad.extra = "OAD"
        XCTAssertNil(WatchedState.identity(imdb: "tt1", type: "series", parsed: oad, metaSeason: nil, metaEpisode: nil), "an OAD's numbers are its own")
        XCTAssertNil(WatchedState.identity(videoID: "kitsu:123:4"), "an addon id that isn't IMDb's stays on its own")
        XCTAssertEqual(WatchedState.identity(videoID: "tt0816692"), "tt0816692")
    }

    // MARK: Combining

    func testWatchedOnEitherSideIsWatched() {
        let file = entry("/x/Documents/Media/Show S01E01.mkv", position: 0, duration: 0, watched: true, age: 500)
        let addon = entry("addon:tt1:1:1", position: 600, age: 10)        // half watched from a stream, more recently
        XCTAssertEqual(WatchedState.combined([addon, file])?.isFinished, true)
        XCTAssertEqual(WatchedState.combined([nil, file])?.isFinished, true, "only the file has an entry")
        XCTAssertEqual(WatchedState.combined([addon, nil])?.isFinished, false)
        XCTAssertNil(WatchedState.combined([nil, nil]))
        XCTAssertNil(WatchedState.combined([]))
    }

    func testInProgressIsTheMostRecentPlace() {
        let file = entry("/x/Documents/Media/Show S01E02.mkv", position: 900, age: 10)
        let addon = entry("addon:tt1:1:2", position: 300, age: 500)
        let c = WatchedState.combined([addon, file])
        XCTAssertEqual(c?.canResume, true)
        XCTAssertEqual(c?.position, 900)
        // A few seconds played on one side don't hide the other's place.
        let barely = entry("addon:tt1:1:2", position: 5, age: 1)
        XCTAssertEqual(WatchedState.combined([barely, file])?.position, 900)
    }

    func testThePlaceIsCarriedOnlyWhenItsNotTheItemsOwn() {
        let file = entry("/x/Documents/Media/Show S01E02.mkv", position: 900)
        let addon = entry("addon:tt1:1:2", position: 300)
        XCTAssertEqual(WatchedState.carriedPosition(own: nil, others: [file]), 900, "a stream starts where the file stopped")
        XCTAssertNil(WatchedState.carriedPosition(own: addon, others: [file]), "its own place: the player resumes from that")
        XCTAssertNil(WatchedState.carriedPosition(own: nil, others: [nil]))
        let done = entry("/x/Documents/Media/Show S01E02.mkv", position: 3000)
        XCTAssertNil(WatchedState.carriedPosition(own: nil, others: [done]), "watched: from the start")
        let ownDone = entry("addon:tt1:1:2", position: 3000)
        XCTAssertNil(WatchedState.carriedPosition(own: ownDone, others: [file]), "watched on its own side: from the start")
    }

    // MARK: Where Continue starts

    func testContinueStartsAtTheFirstUnwatched() {
        XCTAssertEqual(WatchedState.firstUnwatched([true, true, false, false]), 2, "E1 and E2 watched from files: Continue Season from E3")
        XCTAssertEqual(WatchedState.firstUnwatched([false, false]), 0)
        XCTAssertEqual(WatchedState.firstUnwatched([true, true]), 0, "all watched: from the first again")
        XCTAssertEqual(WatchedState.firstUnwatched([true, false, true]), 1)
        XCTAssertEqual(WatchedState.firstUnwatched([]), 0)
    }

    func testTheSeasonsCombinedStateGivesTheStart() {
        // E1 from a stream, E2 from a file, E3 untouched.
        let addon: [String: HistoryEntry] = ["tt1:1:1": entry("addon:tt1:1:1", position: 3000)]
        let files: [String: HistoryEntry] = ["tt1:1:2": entry("/x/Documents/Media/Show S01E02.mkv", position: 0, duration: 0, watched: true)]
        let ids = ["tt1:1:1", "tt1:1:2", "tt1:1:3"]
        let watched = ids.map { WatchedState.combined([addon[$0], files[$0]])?.isFinished == true }
        XCTAssertEqual(watched, [true, true, false])
        XCTAssertEqual(WatchedState.firstUnwatched(watched), 2)
        XCTAssertEqual(WatchedState.firstUnwatched(ids.map { addon[$0]?.isFinished == true }), 1, "what Discover did until 1.30.0: streams only")
    }

    func testNextUpFollowsTheLibrarysRule() {
        let items = ["e1", "e2", "e3", "e4"]
        XCTAssertEqual(WatchedState.nextUp(items) { _ in nil }, "e1", "nothing watched: the first")
        XCTAssertNil(WatchedState.nextUp([String]()) { _ in nil })
        let e1 = entry("e1", position: 3000, age: 300), e2 = entry("e2", position: 3000, age: 200)
        XCTAssertEqual(WatchedState.nextUp(items) { ["e1": e1, "e2": e2][$0] }, "e3", "the one after the episode finished last")
        let half = entry("e2", position: 700, age: 100)
        XCTAssertEqual(WatchedState.nextUp(items) { ["e1": e1, "e2": half][$0] }, "e2", "the one watched last, when it isn't finished")
        let e3 = entry("e3", position: 3000, age: 400), e4 = entry("e4", position: 3000, age: 50)
        XCTAssertEqual(WatchedState.nextUp(items) { ["e3": e3, "e4": e4][$0] }, "e4", "nothing after the last: it stays")
        XCTAssertEqual(WatchedState.nextUp(items) { ["e1": e1, "e2": e2, "e3": e3][$0] }, "e4", "watched ones after it are skipped")
    }

    // MARK: Marking

    func testMarkingReachesTheOtherSideOnlyWhereItHasAnEntry() {
        let file = "/x/Documents/Media/Show S01E01.mkv", addon = "addon:tt1:1:1"
        XCTAssertEqual(WatchedState.markKeys(own: [file], others: [addon]) { _ in true }, [file, addon])
        XCTAssertEqual(WatchedState.markKeys(own: [file], others: [addon]) { _ in false }, [file], "no entry made for a stream never played")
        XCTAssertEqual(WatchedState.markKeys(own: [file], others: []) { _ in true }, [file])
        XCTAssertEqual(WatchedState.markKeys(own: [file], others: [file]) { _ in true }, [file], "not twice")
    }

    func testAnAddonItemThatWasNeverPlayed() {
        let item = WatchedState.addonItem(key: "addon:tt1:1:3", name: "Show", poster: "p", type: "series", metaID: "tt1", label: "S1 · E3 — Three")
        XCTAssertEqual(item.id, "addon:tt1:1:3", "found again by the key Discover's page reads")
        XCTAssertEqual(item.addonRef, "series|tt1|tt1:1:3")
        XCTAssertEqual(item.title, "Show")
        XCTAssertEqual(TitleIdentity.fromAddonKey(item.id), "tt1:1:3")
    }

    @MainActor
    func testMarkingAnEpisodeMarksBothSidesAndUnmarkingClearsBoth() {
        let h = HistoryStore.shared
        let file = "/unit-test/Documents/Media/Linked 1300 S01E01.mp4", addon = "addon:tt99913000:1:1"
        func item(_ key: String) -> MediaItem {
            key.hasPrefix("addon:") ? WatchedState.addonItem(key: key, name: "Linked 1300", poster: nil, type: "series", metaID: "tt99913000", label: nil)
                                    : HistoryStore.libraryItem(key)
        }
        defer { h.setWatched([file, addon], false, item: item) }
        h.setWatched([file, addon], false, item: item)

        // From the library's page: the file only (the stream was never played).
        var keys = WatchedState.markKeys(own: [file], others: [addon]) { h.entry(for: $0) != nil }
        h.setWatched(keys, true, item: item)
        XCTAssertTrue(h.isWatched(key: file))
        XCTAssertNil(h.entry(for: addon), "no entry made for the other side")
        XCTAssertEqual(WatchedState.combined([h.entry(for: addon), h.entry(forURL: file)])?.isFinished, true, "Discover's page sees it watched")

        // From Discover's page: the addon entry and the file.
        h.setWatched([addon, file], true, item: item)
        XCTAssertTrue(h.isWatched(key: addon))

        // Unwatched from the library's page: both go, or it would still read as watched.
        keys = WatchedState.markKeys(own: [file], others: [addon]) { h.entry(for: $0) != nil }
        XCTAssertEqual(keys, [file, addon])
        h.setWatched(keys, false, item: item)
        XCTAssertNil(WatchedState.combined([h.entry(for: addon), h.entry(forURL: file)]))
    }

    // MARK: Accessibility

    func testWhatARowSays() {
        XCTAssertEqual(WatchedState.spoken(nil), "")
        XCTAssertEqual(WatchedState.spoken(entry("a", position: 3000)), "Watched")
        XCTAssertEqual(WatchedState.spoken(entry("a", position: 0, duration: 0, watched: true)), "Watched")
        XCTAssertEqual(WatchedState.spoken(entry("a", position: 600)), "In progress")
        XCTAssertEqual(WatchedState.spoken(entry("a", position: 0)), "")
    }
}
