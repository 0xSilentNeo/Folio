import XCTest
@testable import Folio

/// Air times in the user's own time zone (1.22.1): a Japanese anime from
/// AniList and a US show from TVmaze, read from their answers and shown
/// with the device in Melbourne and in New York. TVmaze's airstamp is the
/// moment; its airdate and airtime (the network's own zone) are never read.
/// Also the title pages' episode marks ("New", "Airs Tue 9:00 PM").
@MainActor
final class AiringTimeZoneTests: XCTestCase {
    /// Tuesday 3 November 2026, 23:00 UTC: 6 PM Tuesday in New York (EST,
    /// UTC−5), 10 AM Wednesday in Melbourne (AEDT, UTC+11).
    private let now = Date(timeIntervalSince1970: 1_793_746_800)
    private let h: TimeInterval = 3600
    private let us = Locale(identifier: "en_US")

    private func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }
    private var melbourne: Calendar { calendar("Australia/Melbourne") }
    private var newYork: Calendar { calendar("America/New_York") }

    /// iOS writes a narrow no-break space before AM/PM.
    private func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{202F}", with: " ") }

    private var savedZone: TimeZone!
    override func setUp() { savedZone = NSTimeZone.default }
    override func tearDown() { NSTimeZone.default = savedZone }

    // MARK: Fixtures

    /// An anime that airs in Japan on Saturdays at 23:30 JST (14:30 UTC):
    /// AniList's airingAt is seconds since 1970, a moment.
    private let aniList = Data("""
    {"data":{"Media":{"id":170000,"idMal":59000,"title":{"romaji":"Rabo no Anime","english":"Lab Anime"},"status":"RELEASING","episodes":12,
     "siteUrl":"https://anilist.co/anime/170000","nextAiringEpisode":{"airingAt":1794061800,"episode":6},
     "airingSchedule":{"nodes":[{"airingAt":1794061800,"episode":6},{"airingAt":1794666600,"episode":7}]},
     "coverImage":{"large":null},"externalLinks":[{"site":"Crunchyroll","type":"STREAMING"}],"relations":{"edges":[]}}}}
    """.utf8)

    /// A US network show on Sundays at 9 PM Eastern. TVmaze's airdate and
    /// airtime are in the network's zone ("2026-11-08", "21:00"); its
    /// airstamp is the moment (02:00 UTC on Monday).
    private let tvmaze = Data("""
    {"id":90000,"url":"https://www.tvmaze.com/shows/90000/lab-show","name":"Lab Show","status":"Running","premiered":"2025-09-21",
     "network":{"id":1,"name":"NBC","country":{"name":"United States","code":"US","timezone":"America/New_York"}},"webChannel":null,
     "externals":{"imdb":"tt9000090"},"image":null,
     "_embedded":{
       "nextepisode":{"name":"The Next One","season":2,"number":7,"airdate":"2026-11-08","airtime":"21:00","airstamp":"2026-11-09T02:00:00+00:00"},
       "previousepisode":{"name":"The Last One","season":2,"number":6,"airdate":"2026-11-01","airtime":"21:00","airstamp":"2026-11-02T02:00:00+00:00"}
     }}
    """.utf8)

    // MARK: AniList: a Japanese anime

    func testAnAnimeFromJapanInMelbourneAndNewYork() throws {
        let f = try XCTUnwrap(AiringParse.aniListMedia(aniList))
        let next = try XCTUnwrap(f.next?.airDate)
        XCTAssertEqual(next, Date(timeIntervalSince1970: 1_794_061_800))
        // Saturday 23:30 in Tokyo…
        XCTAssertEqual(plain(AiringFormat.when(next, now: now, calendar: calendar("Asia/Tokyo"), locale: us)), "Sat 11:30 PM")
        // …is Sunday 1:30 AM in Melbourne and Saturday 9:30 AM in New York.
        XCTAssertEqual(plain(AiringFormat.when(next, now: now, calendar: melbourne, locale: us)), "Sun 1:30 AM")
        XCTAssertEqual(plain(AiringFormat.when(next, now: now, calendar: newYork, locale: us)), "Sat 9:30 AM")
        XCTAssertEqual(plain(AiringFormat.airs(next, now: now, calendar: melbourne, locale: us)), "Airs Sun 1:30 AM")
        XCTAssertEqual(plain(AiringFormat.airs(next, now: now, calendar: newYork, locale: us)), "Airs Sat 9:30 AM")
        // Four days away in both: Wednesday to Sunday, Tuesday to Saturday.
        XCTAssertEqual(AiringFormat.countdownTitle(to: next, now: now, calendar: melbourne), "In 4 days")
        XCTAssertEqual(AiringFormat.countdownTitle(to: next, now: now, calendar: newYork), "In 4 days")
        // The one after: a week later, the same local times.
        XCTAssertEqual(f.later.first.flatMap { $0.airDate }.map { plain(AiringFormat.when($0, now: now, calendar: melbourne, locale: us)) }, "Nov 15, 1:30 AM")
    }

    // MARK: TVmaze: a US show

    func testAUSShowInMelbourneAndNewYork() throws {
        let f = try XCTUnwrap(AiringParse.tvmazeShow(tvmaze))
        let next = try XCTUnwrap(f.next?.airDate)
        // The airstamp's moment, not the airdate and airtime read in any zone.
        XCTAssertEqual(next, Date(timeIntervalSince1970: 1_794_189_600))
        XCTAssertEqual(plain(AiringFormat.when(next, now: now, calendar: newYork, locale: us)), "Sun 9:00 PM")
        XCTAssertEqual(plain(AiringFormat.when(next, now: now, calendar: melbourne, locale: us)), "Mon 1:00 PM",
                       "in Melbourne it's Monday afternoon, not the network's Sunday 9 PM")
        XCTAssertEqual(plain(AiringFormat.airs(next, now: now, calendar: melbourne, locale: us)), "Airs Mon 1:00 PM")
        XCTAssertEqual(AiringFormat.countdownTitle(to: next, now: now, calendar: newYork), "In 5 days")
        // 38 hours before: Saturday 7 AM in New York, so "tomorrow" and one day;
        // Saturday 11 PM in Melbourne, where it's Monday: two days.
        let saturday = Date(timeIntervalSince1970: 1_794_189_600 - 38 * 3600)
        XCTAssertEqual(plain(AiringFormat.airs(next, now: saturday, calendar: newYork, locale: us)), "Airs tomorrow 9:00 PM")
        XCTAssertEqual(AiringFormat.countdownTitle(to: next, now: saturday, calendar: newYork), "In 1 day")
        XCTAssertEqual(plain(AiringFormat.airs(next, now: saturday, calendar: melbourne, locale: us)), "Airs Mon 1:00 PM")
        XCTAssertEqual(AiringFormat.countdownTitle(to: next, now: saturday, calendar: melbourne), "In 2 days")
        let last = try XCTUnwrap(f.lastAired?.airDate)
        XCTAssertEqual(plain(AiringFormat.when(last, now: now, calendar: newYork, locale: us)), "Nov 1, 9:00 PM")
        XCTAssertEqual(plain(AiringFormat.when(last, now: now, calendar: melbourne, locale: us)), "Nov 2, 1:00 PM")
    }

    /// airdate and airtime are never read: an answer whose airdate and
    /// airtime say something else still gives the airstamp's moment, and
    /// one with no airstamp gives no time at all rather than a guess.
    func testOnlyTheAirstampCounts() throws {
        let odd = Data("""
        {"id":1,"name":"Odd","status":"Running","_embedded":{
          "nextepisode":{"season":1,"number":2,"airdate":"2026-11-10","airtime":"08:00","airstamp":"2026-11-09T02:00:00+00:00"},
          "previousepisode":{"season":1,"number":1,"airdate":"2026-11-01","airtime":"21:00"}}}
        """.utf8)
        let f = try XCTUnwrap(AiringParse.tvmazeShow(odd))
        XCTAssertEqual(f.next?.airDate, Date(timeIntervalSince1970: 1_794_189_600))
        XCTAssertEqual(f.lastAired?.number, 1)
        XCTAssertNil(f.lastAired?.airDate)
    }

    /// The device's own zone, as the screens ask for it (no calendar passed):
    /// the same moment reads as Melbourne's time, then New York's.
    func testTheDevicesZoneIsUsed() throws {
        let next = try XCTUnwrap(AiringParse.tvmazeShow(tvmaze)?.next?.airDate)
        NSTimeZone.default = TimeZone(identifier: "Australia/Melbourne")!
        XCTAssertEqual(plain(AiringFormat.when(next, now: now, locale: us)), "Mon 1:00 PM")
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(plain(AiringFormat.when(next, now: now, locale: us)), "Sun 9:00 PM")
    }

    /// Siri and the Tracking screen's groups in both zones.
    func testSiriAndTheGroupsInBothZones() throws {
        var s = TrackedShow(id: "tt9000090", name: "Lab Show")
        s.apply(try XCTUnwrap(AiringParse.tvmazeShow(tvmaze)), at: now)
        XCTAssertTrue(plain(AiringFormat.spoken(s, now: now, calendar: melbourne, locale: us)).contains("airs on Monday at 1:00 PM"))
        XCTAssertTrue(plain(AiringFormat.spoken(s, now: now, calendar: newYork, locale: us)).contains("airs on Sunday at 9:00 PM"))
        XCTAssertEqual(AiringGroup.of(s, now: now, calendar: melbourne), .week)
        // Six hours before it airs: Monday 7 AM in Melbourne, so "today" there,
        // while New York is still on Sunday afternoon — also "today" there.
        let before = Date(timeIntervalSince1970: 1_794_189_600 - 6 * 3600)
        XCTAssertEqual(AiringGroup.of(s, now: before, calendar: melbourne), .today)
        XCTAssertEqual(AiringGroup.of(s, now: before, calendar: newYork), .today)
        // Twenty hours before, the two zones disagree about "today".
        let earlier = Date(timeIntervalSince1970: 1_794_189_600 - 20 * 3600)
        XCTAssertEqual(AiringGroup.of(s, now: earlier, calendar: newYork), .today)        // Sunday 1 AM, airs Sunday 9 PM
        XCTAssertEqual(AiringGroup.of(s, now: earlier, calendar: melbourne), .week)       // Sunday 5 PM, airs Monday
    }

    // MARK: Title pages' episode marks

    private func tracked() throws -> TrackedShow {
        var s = TrackedShow(id: "tt9000090", name: "Lab Show")
        s.apply(try XCTUnwrap(AiringParse.tvmazeShow(tvmaze)), at: now)
        return s
    }

    func testEpisodeMarks() throws {
        let a = EpisodeAiring(show: try tracked(), now: now, newestSeason: 2)
        let next = Date(timeIntervalSince1970: 1_794_189_600)
        XCTAssertEqual(a.mark(season: 2, episode: 7), .airs(next))
        XCTAssertEqual(a.mark(season: 2, episode: 6), .new, "out on Sunday, two days ago")
        XCTAssertNil(a.mark(season: 1, episode: 6), "another season's episode 6")
        XCTAssertNil(a.mark(season: 2, episode: 5))
        XCTAssertNil(a.mark(season: 2, episode: nil))
        // A week on, episode 6 isn't new any more (and 7 is, once it's out).
        let weekOn = EpisodeAiring(show: try tracked(), now: now.addingTimeInterval(6 * 24 * h), newestSeason: 2)
        XCTAssertEqual(weekOn.mark(season: 2, episode: 7), .new)
        XCTAssertNil(weekOn.mark(season: 2, episode: 6))
        // Episodes with no tile on the page: the one not out yet.
        XCTAssertEqual(a.untiled(shown: 2, seasons: [1, 2], episodes: [1, 2, 3, 4, 5, 6]).map(\.number), [7])
        XCTAssertTrue(a.untiled(shown: 2, seasons: [1, 2], episodes: [6, 7]).isEmpty, "it has a tile")
        XCTAssertTrue(a.untiled(shown: 1, seasons: [1, 2], episodes: [1, 2]).isEmpty, "another season is shown")
        XCTAssertEqual(a.untiled(shown: 1, seasons: [1], episodes: [1, 2]).map(\.label), ["S2 · E7"],
                       "a season the page doesn't have yet goes under its newest")
    }

    /// AniList numbers each season on its own: its episodes match the
    /// tracked (or the page's newest) season. "New" needs the time the
    /// episode aired: kept from when Folio saw it coming.
    func testAnimeMarksAndTheEpisodeJustOut() throws {
        var s = TrackedShow(id: "anilist:170000", name: "Lab Anime")
        s.season = 2
        s.apply(try XCTUnwrap(AiringParse.aniListMedia(aniList)), at: now)
        let a = EpisodeAiring(show: s, now: now, newestSeason: 2)
        XCTAssertEqual(a.mark(season: 2, episode: 6), .airs(Date(timeIntervalSince1970: 1_794_061_800)))
        XCTAssertEqual(a.mark(season: nil, episode: 7), .airs(Date(timeIntervalSince1970: 1_794_666_600)))
        XCTAssertNil(a.mark(season: 1, episode: 6))
        XCTAssertNil(a.mark(season: 2, episode: 5), "AniList gave no time for episode 5: not marked New on a guess")

        // A week on, AniList's next is 7 and its last is 6, with no time: the
        // time Folio saw for 6 stays, so 6 shows New.
        let later = Data(String(decoding: aniList, as: UTF8.self)
            .replacingOccurrences(of: "\"nextAiringEpisode\":{\"airingAt\":1794061800,\"episode\":6}", with: "\"nextAiringEpisode\":{\"airingAt\":1794666600,\"episode\":7}")
            .replacingOccurrences(of: "{\"airingAt\":1794061800,\"episode\":6},", with: "").utf8)
        let weekOn = Date(timeIntervalSince1970: 1_794_061_800 + 2 * 3600)
        s.apply(try XCTUnwrap(AiringParse.aniListMedia(later)), at: weekOn)
        XCTAssertEqual(s.lastAired?.number, 6)
        XCTAssertEqual(s.lastAired?.airDate, Date(timeIntervalSince1970: 1_794_061_800))
        XCTAssertEqual(EpisodeAiring(show: s, now: weekOn, newestSeason: 2).mark(season: 2, episode: 6), .new)
    }

    func testTheTrackedLineUnderTheButton() throws {
        let s = try tracked()
        XCTAssertEqual(plain(TrackStatusLine.text(s, now: now, calendar: melbourne, locale: us)), "Tracking · next S2 · E7 airs Mon 1:00 PM, in 5 days")
        XCTAssertEqual(plain(TrackStatusLine.text(s, now: now, calendar: newYork, locale: us)), "Tracking · next S2 · E7 airs Sun 9:00 PM, in 5 days")
        let tonight = Date(timeIntervalSince1970: 1_794_189_600 - 3 * 3600)      // Sunday 6 PM in New York
        XCTAssertEqual(plain(AiringFormat.airs(Date(timeIntervalSince1970: 1_794_189_600), now: tonight, calendar: newYork, locale: us)), "Airs today 9:00 PM")
    }

    /// The library's page and Discover's find the same tracked show by any
    /// of its names, so both show Tracking.
    func testTheLibraryAndDiscoverAgree() {
        var discover = TrackedShow(meta: MetaItem(id: "kitsu:46474", type: "series", name: "Frieren: Beyond Journey's End", poster: nil,
                                                  description: nil, releaseInfo: "2023", imdbRating: nil, genres: ["Anime"]), imdbID: nil)
        discover.otherNames = ["Sousou no Frieren"]
        // The library's files are named in romaji, and Folio found no metadata for them.
        let library = TrackedShow(libraryTitle: "Sousou no Frieren", meta: nil, hint: nil, season: 1)
        XCTAssertTrue(library.isSameShow(as: discover))
        XCTAssertTrue(discover.isSameShow(as: library))
        XCTAssertFalse(TrackedShow(libraryTitle: "Another Show", meta: nil, hint: nil, season: 1).isSameShow(as: discover))
    }
}
