import XCTest
@testable import Folio

/// 1.22.6, from your 5 Nov screenshots: Dragon Ball tracked with Dragon Ball
/// Super: Beerus's times, Bleach and Thousand-Year Blood War tracked after
/// they ended, Tulsa King's newest episode without a date and the next one
/// "Airs tomorrow 11:00 pm" (TVmaze has no time for it).
@MainActor
final class Fixes1226Tests: XCTestCase {
    /// Thursday 5 November 2026, 3 PM in Melbourne (AEDT, UTC+11); Wednesday
    /// 4 November, 11 PM in New York.
    private let now = Date(timeIntervalSince1970: 1_793_851_200)
    private let us = Locale(identifier: "en_US")

    private func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    private func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{202F}", with: " ") }

    // MARK: AniList: another series isn't a sequel to follow

    /// AniList's search for "Dragon Ball" (5 Nov, trimmed): the 1986 series
    /// and Dragon Ball Z finished, Dragon Ball Super: Beerus airing.
    private let dragonBallSearch = Data("""
    {"data":{"Page":{"media":[
      {"id":223,"idMal":223,"title":{"romaji":"Dragon Ball","english":"Dragon Ball"},"status":"FINISHED","episodes":153,
       "relations":{"edges":[{"relationType":"SEQUEL","node":{"id":813,"type":"ANIME","status":"FINISHED","format":"TV"}}]}},
      {"id":206814,"idMal":null,"title":{"romaji":"Dragon Ball Super: Beerus","english":null},"status":"RELEASING","episodes":null,
       "nextAiringEpisode":{"airingAt":1794250560,"episode":5},"relations":{"edges":[]}},
      {"id":813,"idMal":813,"title":{"romaji":"Dragon Ball Z","english":"Dragon Ball Z"},"status":"FINISHED","episodes":291,
       "relations":{"edges":[{"relationType":"SEQUEL","node":{"id":225,"type":"ANIME","status":"FINISHED","format":"TV"}},
                             {"relationType":"SEQUEL","node":{"id":206814,"type":"ANIME","status":"RELEASING","format":"TV"}}]}}
    ]}}}
    """.utf8)

    func testAnEndedSeriesFindsItsOwnEntryNotTheAiringOne() throws {
        // A running series still finds what's on (1.21.0's rule).
        XCTAssertEqual(AiringParse.aniListSearch(dragonBallSearch, name: "Dragon Ball")?.anilist, 206814)
        // One that has ended: the entry with exactly its name.
        let f = try XCTUnwrap(AiringParse.aniListSearch(dragonBallSearch, name: "Dragon Ball", airingFirst: false))
        XCTAssertEqual(f.anilist, 223)
        XCTAssertEqual(f.status, .ended)
        XCTAssertEqual(f.lastAired?.number, 153)
    }

    /// Dragon Ball Super's sequels on AniList: a film. Dragon Ball Z's: GT
    /// and Beerus, both TV, the airing one picked.
    func testOnlyATVOrWebSequelIsFollowed() throws {
        let superData = Data("""
        {"data":{"Media":{"id":21175,"idMal":30694,"title":{"romaji":"Dragon Ball Super"},"status":"FINISHED","episodes":131,
         "relations":{"edges":[{"relationType":"SEQUEL","node":{"id":101302,"type":"ANIME","status":"FINISHED","format":"MOVIE"}}]}}}}
        """.utf8)
        let dbs = try XCTUnwrap(AiringParse.aniListMedia(superData))
        XCTAssertEqual(dbs.sequel, 101302)
        XCTAssertEqual(dbs.sequelFormat, "MOVIE")
        XCTAssertFalse(AiringService.followable(dbs.sequelFormat))

        let dbz = try XCTUnwrap(AiringParse.aniListSearch(dragonBallSearch, name: "Dragon Ball Z", airingFirst: false))
        XCTAssertEqual(dbz.anilist, 813)
        XCTAssertEqual(dbz.sequel, 206814)
        XCTAssertTrue(AiringService.followable(dbz.sequelFormat))
        XCTAssertTrue(AiringService.followable("ONA"))
        XCTAssertTrue(AiringService.followable(nil))      // an answer without formats (saved before 1.22.6)
        XCTAssertFalse(AiringService.followable("SPECIAL"))
    }

    // MARK: When a series has ended

    func testATitlePageKnowsTheSeriesEnded() {
        var m = MetaItem(id: "tt0434665", type: "series", name: "Bleach", poster: nil, description: nil, releaseInfo: "2006", imdbRating: nil, genres: ["Anime"])
        m.endYear = 2012
        XCTAssertEqual(TrackedShow(meta: m, imdbID: nil).seriesEnded, true)
        m.endYear = nil
        XCTAssertNil(TrackedShow(meta: m, imdbID: nil).seriesEnded)
    }

    func testTVmazeEndedIsTheSeriesButAniListFinishedIsASeason() throws {
        var s = TrackedShow(id: "tt14986406", name: "Bleach: Thousand-Year Blood War")
        s.apply(AiringFetch(source: .anilist, anilist: 185874, status: .ended), at: now)
        XCTAssertNil(s.seriesEnded)
        s.apply(AiringFetch(source: .tvmaze, tvmaze: 80375, status: .ended), at: now)
        XCTAssertEqual(s.seriesEnded, true)
    }

    func testAnEndedShowIsOverOnceItsLastEpisodesWeekIsOver() {
        var s = TrackedShow(id: "tt0434665", name: "Bleach")
        s.status = .ended
        s.lastAired = AiringEpisode(number: 366)                      // no date (AniList)
        XCTAssertFalse(s.isOver(at: now))                             // not known to have ended
        s.seriesEnded = true
        XCTAssertTrue(s.isOver(at: now))

        // A finale three days ago keeps its week as "New".
        s.lastAired = AiringEpisode(number: 10, airDate: now.addingTimeInterval(-3 * 86400))
        XCTAssertFalse(s.isOver(at: now))
        XCTAssertTrue(s.isOver(at: now.addingTimeInterval(5 * 86400)))

        // Something still to come: not over, whatever IMDb says.
        s.next = AiringEpisode(number: 11, airDate: now.addingTimeInterval(86400))
        XCTAssertFalse(s.isOver(at: now))
    }

    // MARK: TVmaze without a time

    func testAnEpisodeWithoutATimeKeepsItsDay() throws {
        let data = Data("""
        [{"id":1,"name":"Cease & Desist","season":4,"number":3,"airdate":"2026-10-30","airtime":"","airstamp":"2026-10-30T12:00:00+00:00"},
         {"id":2,"name":"Square One","season":4,"number":4,"airdate":"2026-11-06","airtime":"","airstamp":"2026-11-06T12:00:00+00:00"},
         {"id":3,"name":"Pilot","season":1,"number":1,"airdate":"2026-11-08","airtime":"21:00","airstamp":"2026-11-09T02:00:00+00:00"}]
        """.utf8)
        let list = AiringParse.tvmazeEpisodes(data)
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list[1].episode.day, "2026-11-06")
        XCTAssertEqual(list[1].airdate, "2026-11-06")
        XCTAssertNil(list[2].episode.day)                             // a real time
        XCTAssertEqual(list[2].episode.airDate, Date(timeIntervalSince1970: 1_794_189_600))
    }

    /// Tulsa King S4E4: Friday 6 November on Paramount+, no hour. The same
    /// day in Melbourne and New York, no "11:00 pm".
    func testADayWithoutAnHour() {
        let stamp = Date(timeIntervalSince1970: 1_793_966_400)       // TVmaze's 12:00 UTC
        let melbourne = calendar("Australia/Melbourne"), newYork = calendar("America/New_York")
        XCTAssertEqual(AiringFormat.airs(stamp, day: "2026-11-06", now: now, calendar: melbourne, locale: us), "Airs tomorrow")
        XCTAssertEqual(AiringFormat.countdownTitle(to: stamp, day: "2026-11-06", now: now, calendar: melbourne), "In 1 day")
        XCTAssertEqual(AiringFormat.airs(stamp, day: "2026-11-06", now: now, calendar: newYork, locale: us), "Airs Fri")
        XCTAssertEqual(AiringFormat.countdownTitle(to: stamp, day: "2026-11-06", now: now, calendar: newYork), "In 2 days")
        XCTAssertEqual(AiringFormat.when(stamp, day: "2026-11-27", now: now, calendar: melbourne, locale: us), "Nov 27")
        XCTAssertEqual(AiringFormat.countdown(to: stamp, day: "2026-11-05", now: now, calendar: melbourne), "today")
        XCTAssertEqual(AiringFormat.countdown(to: stamp, day: "2026-11-01", now: now, calendar: melbourne), "Aired")
        // Without a day, the hour as before.
        XCTAssertEqual(plain(AiringFormat.airs(stamp, now: now, calendar: melbourne, locale: us)), "Airs tomorrow 11:00 PM")
    }

    func testATileMarkCarriesTheDay() {
        var s = TrackedShow(id: "tt16358384", name: "Tulsa King")
        s.next = AiringEpisode(season: 4, number: 4, airDate: Date(timeIntervalSince1970: 1_793_966_400), day: "2026-11-06")
        let a = EpisodeAiring(show: s, now: now, newestSeason: 4)
        XCTAssertEqual(a.mark(season: 4, episode: 4), .airs(Date(timeIntervalSince1970: 1_793_966_400), day: "2026-11-06"))
    }

    // MARK: Episode dates checked against TVmaze

    func testTVmazesDateForEpisodesOutLatelyOrToCome() {
        // Tulsa King S4E5: IMDb Nov 14, TVmaze Nov 13 (weekly, Fridays).
        XCTAssertEqual(EpisodeDateCheck.pick(imdb: "2026-11-14", tvmaze: "2026-11-13", now: now), "2026-11-13")
        // IMDb has none.
        XCTAssertEqual(EpisodeDateCheck.pick(imdb: nil, tvmaze: "2026-10-30", now: now), "2026-10-30")
        // Out last week, moved by TVmaze.
        XCTAssertEqual(EpisodeDateCheck.pick(imdb: "2026-10-29", tvmaze: "2026-10-30", now: now), "2026-10-30")
        // The same date: IMDb's text stays.
        XCTAssertEqual(EpisodeDateCheck.pick(imdb: "2026-10-23", tvmaze: "2026-10-23", now: now), "2026-10-23")
        // Years ago: history, IMDb's stays.
        XCTAssertEqual(EpisodeDateCheck.pick(imdb: "2019-04-14", tvmaze: "2019-04-15", now: now), "2019-04-14")
        // TVmaze has nothing usable.
        XCTAssertEqual(EpisodeDateCheck.pick(imdb: "2026-11-14", tvmaze: nil, now: now), "2026-11-14")
        XCTAssertEqual(EpisodeDateCheck.pick(imdb: "2026-11-14", tvmaze: "TBA", now: now), "2026-11-14")
        XCTAssertNil(EpisodeDateCheck.pick(imdb: nil, tvmaze: nil, now: now))
    }
}
