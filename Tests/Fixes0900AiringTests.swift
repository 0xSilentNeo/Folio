import XCTest
@testable import Folio

/// 0.90.0: a title's page opened on an episode, from the Airing sheet
/// ("Open Title Page") and from a Continue Watching card ("Go to Show" /
/// "Go to Title"). Which episode a tracked show's page opens on, what an
/// addon item's ref says, which row matches, and which cards get the item.
@MainActor
final class Fixes0900AiringTests: XCTestCase {
    /// Tuesday 3 November 2026, 6 PM in New York, as in TrackingTests.
    private let now = Date(timeIntervalSince1970: 1_793_746_800)
    private let h: TimeInterval = 3600

    private func show(imdb: String? = "tt31510819", last: AiringEpisode?, next: AiringEpisode?) -> TrackedShow {
        var s = TrackedShow(id: imdb ?? "anilist:1", name: "MobLand")
        s.imdb = imdb
        s.poster = "https://example.com/p.jpg"
        s.lastAired = last
        s.next = next
        return s
    }

    private func episode(_ season: Int?, _ number: Int?, _ offset: TimeInterval) -> AiringEpisode {
        AiringEpisode(season: season, number: number, airDate: now.addingTimeInterval(offset))
    }

    // MARK: The Airing sheet's episode

    /// An episode out an hour ago is the sheet's "Out now": the page opens on it.
    func testAPageOpensOnTheEpisodeOutNow() throws {
        let s = show(last: episode(2, 6, -7 * 24 * h), next: episode(2, 7, -1 * h))
        XCTAssertEqual(s.headline(at: now)?.number, 7)
        XCTAssertEqual(TitlePageTarget.airedEpisode(of: s, now: now)?.number, 7)
        let t = try XCTUnwrap(TitlePageTarget(show: s, now: now))
        XCTAssertEqual(t.meta.id, "tt31510819")
        XCTAssertEqual(t.meta.type, "series")
        XCTAssertEqual(t.meta.name, "MobLand")
        XCTAssertEqual(t.meta.poster, "https://example.com/p.jpg")
        XCTAssertEqual(t.focus, EpisodeFocus(season: 2, episode: 7))
        XCTAssertTrue(t.isSeries)
    }

    /// The next one is still to come: the last aired, not the one that isn't out.
    func testAPageOpensOnTheLastAiredWhenTheNextIsToCome() throws {
        let s = show(last: episode(2, 7, -4 * 24 * h), next: episode(2, 8, 3 * 24 * h))
        XCTAssertEqual(s.headline(at: now)?.number, 8)
        let t = try XCTUnwrap(TitlePageTarget(show: s, now: now))
        XCTAssertEqual(t.focus, EpisodeFocus(season: 2, episode: 7))
    }

    /// Nothing aired yet: the page opens, on no episode.
    func testAShowWithNothingAiredOpensWithoutAFocus() throws {
        let s = show(last: nil, next: episode(1, 1, 3 * 24 * h))
        let t = try XCTUnwrap(TitlePageTarget(show: s, now: now))
        XCTAssertNil(t.focus)
        XCTAssertNil(TitlePageTarget.airedEpisode(of: s, now: now))
    }

    /// AniList numbers each season on its own: "E5" could be another
    /// season's fifth on IMDb, so no row is picked.
    func testAnEpisodeWithNoSeasonIsNotFocused() throws {
        let s = show(last: episode(nil, 5, -24 * h), next: nil)
        let t = try XCTUnwrap(TitlePageTarget(show: s, now: now))
        XCTAssertNil(t.focus)
    }

    /// No IMDb id (an anime tracked by its AniList id): no page, so no button.
    func testAShowWithoutAnIMDbIdHasNoPage() {
        XCTAssertNil(TitlePageTarget(show: show(imdb: nil, last: episode(1, 3, -24 * h), next: nil), now: now))
        XCTAssertNil(TitlePageTarget(show: show(imdb: "anilist:21", last: episode(1, 3, -24 * h), next: nil), now: now))
    }

    // MARK: An addon item's ref

    func testAnEpisodesRef() throws {
        let t = try XCTUnwrap(TitlePageTarget(addonRef: "series|tt0944947|tt0944947:1:3", name: "Game of Thrones", poster: "p"))
        XCTAssertEqual(t.meta.id, "tt0944947")
        XCTAssertEqual(t.meta.type, "series")
        XCTAssertEqual(t.meta.name, "Game of Thrones")
        XCTAssertEqual(t.meta.poster, "p")
        XCTAssertEqual(t.focus, EpisodeFocus(season: 1, episode: 3, videoID: "tt0944947:1:3"))
        XCTAssertTrue(t.isSeries)
    }

    func testAFilmsRefHasNoEpisode() throws {
        let t = try XCTUnwrap(TitlePageTarget(addonRef: "movie|tt0111161|tt0111161", name: "The Shawshank Redemption", poster: nil))
        XCTAssertEqual(t.meta.type, "movie")
        XCTAssertNil(t.focus)
        XCTAssertFalse(t.isSeries)
        // No kind written: a film, as Handoff reads it.
        XCTAssertEqual(TitlePageTarget(addonRef: "|tt0111161|tt0111161", name: "", poster: nil)?.meta.type, "movie")
    }

    /// An anime addon's id has no season in it: the row is found by the id alone.
    func testAnAddonsOwnVideoId() throws {
        let t = try XCTUnwrap(TitlePageTarget(addonRef: "series|kitsu:7442|kitsu:7442:12", name: "Attack on Titan", poster: nil))
        XCTAssertEqual(t.meta.id, "kitsu:7442")
        XCTAssertEqual(t.focus, EpisodeFocus(season: nil, episode: nil, videoID: "kitsu:7442:12"))
    }

    func testARefWithNoTitle() {
        XCTAssertNil(TitlePageTarget(addonRef: "", name: "x", poster: nil))
        XCTAssertNil(TitlePageTarget(addonRef: "series", name: "x", poster: nil))
        XCTAssertNil(TitlePageTarget(addonRef: "series||tt1:1:1", name: "x", poster: nil))
        // A series with no video id: its page, on no episode.
        XCTAssertNil(TitlePageTarget(addonRef: "series|tt1", name: "x", poster: nil)?.focus)
    }

    // MARK: The row that's highlighted

    func testWhichRowMatches() {
        let s1e3 = MetaVideo(id: "tt1:1:3", title: nil, season: 1, episode: 3)
        let s2e3 = MetaVideo(id: "tt1:2:3", title: nil, season: 2, episode: 3)
        let anime = MetaVideo(id: "kitsu:7442:12", title: nil, season: 1, episode: 12)
        let byNumber = EpisodeFocus(season: 2, episode: 3)
        XCTAssertFalse(byNumber.matches(s1e3))
        XCTAssertTrue(byNumber.matches(s2e3))
        // By id whatever the page's numbers are; never by a number alone.
        let byID = EpisodeFocus(season: nil, episode: nil, videoID: "kitsu:7442:12")
        XCTAssertTrue(byID.matches(anime))
        XCTAssertFalse(byID.matches(s1e3))
        XCTAssertFalse(EpisodeFocus(season: nil, episode: 3).matches(s1e3))
        // IMDb's page gives its rows other ids than the addon that played it: the numbers still find it.
        var other = s1e3
        other.id = "imdb-episode-3"
        XCTAssertTrue(EpisodeFocus(season: 1, episode: 3, videoID: "tt1:1:3").matches(other))
    }

    // MARK: Continue Watching's menu item

    private func entry(_ item: MediaItem, follows: String? = nil) -> HistoryEntry {
        HistoryEntry(item: item, position: 60, duration: 1200, updated: now, follows: follows)
    }

    private func libraryItem(_ name: String) -> MediaItem {
        let path = "/var/mobile/Containers/Data/Application/AAAA/Documents/Media/" + name
        var m = MediaItem(url: path, title: TitleParser.clean(name), source: .local)
        m.historyKey = path
        return m
    }

    func testAnAddonEpisodeGoesToItsShow() throws {
        var m = MediaItem(url: "https://example.com/stream.mkv", title: "Tulsa King", subtitle: "S3 · E2", source: .addon(name: "Lab"))
        m.addonRef = "series|tt16358384|tt16358384:3:2"
        m.artwork = "poster"
        let page = try XCTUnwrap(HomeView.goToPage(entry(m)))
        XCTAssertEqual(page.menuTitle, "Go to Show")
        guard case .title(let t) = page else { return XCTFail("not a title page") }
        XCTAssertEqual(t.meta.id, "tt16358384")
        XCTAssertEqual(t.meta.name, "Tulsa King")
        XCTAssertEqual(t.meta.poster, "poster")
        XCTAssertEqual(t.focus, EpisodeFocus(season: 3, episode: 2, videoID: "tt16358384:3:2"))
    }

    /// A next-episode card is the next episode's own item: the page opens on that one.
    func testANextEpisodeCardGoesToTheNextEpisode() throws {
        var m = MediaItem(url: "", title: "Tulsa King", subtitle: "S3 · E3", source: .addon(name: "Lab"))
        m.addonRef = "series|tt16358384|tt16358384:3:3"
        guard case .title(let t)? = HomeView.goToPage(entry(m, follows: "addon:tt16358384:3:2")) else { return XCTFail("no page") }
        XCTAssertEqual(t.focus?.episode, 3)
    }

    func testAnAddonFilmGoesToItsTitle() throws {
        var m = MediaItem(url: "https://example.com/film.mkv", title: "Heat", source: .addon(name: "Lab"))
        m.addonRef = "movie|tt0113277|tt0113277"
        let page = try XCTUnwrap(HomeView.goToPage(entry(m)))
        XCTAssertEqual(page.menuTitle, "Go to Title")
        guard case .title(let t) = page else { return XCTFail("not a title page") }
        XCTAssertNil(t.focus)
    }

    /// A library file by its place inside Media: the same after the app's container moved.
    func testLibraryFiles() {
        XCTAssertEqual(HomeView.goToPage(entry(libraryItem("Lab Show S01E02.mp4"))), .library(relative: "Lab Show S01E02.mp4", episode: true))
        XCTAssertEqual(HomeView.goToPage(entry(libraryItem("Lab Show S01E02.mp4")))?.menuTitle, "Go to Show")
        XCTAssertEqual(HomeView.goToPage(entry(libraryItem("Films/Heat (1995).mkv"))), .library(relative: "Films/Heat (1995).mkv", episode: false))
        XCTAssertEqual(HomeView.goToPage(entry(libraryItem("Films/Heat (1995).mkv")))?.menuTitle, "Go to Title")
        // The next file's card, the same way.
        XCTAssertEqual(HomeView.goToPage(entry(libraryItem("Lab Show S01E03.mp4"), follows: "x")), .library(relative: "Lab Show S01E03.mp4", episode: true))
    }

    /// A pasted link, a server's file and a file opened from outside the library have no page.
    func testEntriesWithNoPageGetNoItem() {
        XCTAssertNil(HomeView.goToPage(entry(MediaItem(url: "https://example.com/a.mkv", title: "a", source: .url))))
        XCTAssertNil(HomeView.goToPage(entry(MediaItem(url: "https://dav.example.com/Show.S01E01.mkv", title: "Show", source: .webdav(serverID: UUID())))))
        XCTAssertNil(HomeView.goToPage(entry(MediaItem(url: "/private/var/mobile/Library/Mobile Documents/Show.S01E01.mkv", title: "Show", source: .local))))
        var bad = MediaItem(url: "https://example.com/a.mkv", title: "a", source: .addon(name: "Lab"))
        bad.addonRef = "series"
        XCTAssertNil(HomeView.goToPage(entry(bad)))
    }
}
