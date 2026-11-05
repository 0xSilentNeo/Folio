import XCTest
@testable import Folio

/// The airing tracker (1.21.0): TVmaze's and AniList's answers, which source
/// a show is asked from, the Tracking screen's groups, the notifications
/// planned, the saved list and the widget's snapshot.
@MainActor
final class TrackingTests: XCTestCase {
    /// Tuesday 3 November 2026, 6 PM in New York (EST, UTC−5).
    private let now = Date(timeIntervalSince1970: 1_793_746_800)
    private let h: TimeInterval = 3600

    private var newYork: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }
    private let us = Locale(identifier: "en_US")

    private func show(_ id: String, _ name: String, _ offsets: [TimeInterval], status: TrackedShow.Status = .airing) -> TrackedShow {
        var s = TrackedShow(id: id, name: name)
        s.status = status
        let eps = offsets.enumerated().map { i, o in AiringEpisode(season: 1, number: i + 1, airDate: now.addingTimeInterval(o)) }
        s.next = eps.first
        s.later = Array(eps.dropFirst())
        s.updated = now
        return s
    }

    /// iOS writes a narrow no-break space before AM/PM.
    private func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{202F}", with: " ") }

    // MARK: TVmaze

    private let tvmazeShow = Data("""
    {"id":75026,"url":"https://www.tvmaze.com/shows/75026/mobland","name":"MobLand","type":"Scripted","language":"English",
     "genres":["Drama","Crime"],"status":"Running","runtime":null,"averageRuntime":46,"premiered":"2025-03-30","ended":null,
     "schedule":{"time":"","days":["Sunday"]},"network":null,
     "webChannel":{"id":107,"name":"Paramount+","country":null,"officialSite":"https://www.paramountplus.com/"},
     "externals":{"tvrage":null,"thetvdb":441229,"imdb":"tt31510819"},
     "image":{"medium":"https://static.tvmaze.com/uploads/images/medium_portrait/556/1391393.jpg","original":"https://static.tvmaze.com/uploads/images/original_untouched/556/1391393.jpg"},
     "summary":"<p>A crime family…</p>","updated":1761900000,"_links":{"self":{"href":"https://api.tvmaze.com/shows/75026"}},
     "_embedded":{
       "nextepisode":{"id":3300001,"name":"We Don't Talk Anymore","season":2,"number":8,"type":"regular","airdate":"2026-11-06","airtime":"","airstamp":"2026-11-06T12:00:00+00:00","runtime":46,"image":null},
       "previousepisode":{"id":3300000,"name":"Ace of Spades","season":2,"number":7,"type":"regular","airdate":"2026-10-30","airtime":"","airstamp":"2026-10-30T12:00:00+00:00","runtime":46}
     }}
    """.utf8)

    func testTVmazeShowWithItsNextAndPreviousEpisodes() throws {
        let f = try XCTUnwrap(AiringParse.tvmazeShow(tvmazeShow))
        XCTAssertEqual(f.source, .tvmaze)
        XCTAssertEqual(f.tvmaze, 75026)
        XCTAssertEqual(f.imdb, "tt31510819")
        XCTAssertEqual(f.status, .airing)
        XCTAssertEqual(f.network, "Paramount+")           // a streaming show: its web channel
        XCTAssertEqual(f.page, "https://www.tvmaze.com/shows/75026/mobland")
        XCTAssertEqual(f.poster, "https://static.tvmaze.com/uploads/images/medium_portrait/556/1391393.jpg")
        XCTAssertEqual(f.next, AiringEpisode(season: 2, number: 8, title: "We Don't Talk Anymore", airDate: Date(timeIntervalSince1970: 1_793_966_400), day: "2026-11-06"))
        XCTAssertEqual(f.lastAired, AiringEpisode(season: 2, number: 7, title: "Ace of Spades", airDate: Date(timeIntervalSince1970: 1_793_361_600), day: "2026-10-30"))
        XCTAssertEqual(f.next?.label, "S2 · E8")
        // Paramount+ gives no hour ("airtime":""): the day alone (1.22.6).
    }

    func testAnEndedTVmazeShowHasNoNextEpisode() throws {
        let data = Data("""
        {"id":82,"name":"Game of Thrones","status":"Ended","network":{"id":8,"name":"HBO"},"webChannel":null,"image":null,
         "_embedded":{"previousepisode":{"name":"The Iron Throne","season":8,"number":6,"airstamp":"2019-05-20T01:00:00+00:00"}}}
        """.utf8)
        let f = try XCTUnwrap(AiringParse.tvmazeShow(data))
        XCTAssertEqual(f.status, .ended)
        XCTAssertNil(f.next)
        XCTAssertEqual(f.network, "HBO")
        XCTAssertEqual(f.lastAired?.number, 6)
        XCTAssertNil(f.poster)
    }

    /// An odd episode (a number as text) is left out, not the whole show.
    func testABadEmbeddedEpisodeDoesNotLoseTheShow() throws {
        let data = Data("""
        {"id":5,"name":"Odd","status":"Running","_embedded":{"nextepisode":{"season":"two","number":1},
         "previousepisode":{"season":1,"number":4,"airstamp":"2026-10-30T12:00:00+00:00"}}}
        """.utf8)
        let f = try XCTUnwrap(AiringParse.tvmazeShow(data))
        XCTAssertNil(f.next)
        XCTAssertEqual(f.lastAired?.number, 4)
        XCTAssertEqual(f.status, .airing)
    }

    func testTVmazeLookupAndSearch() {
        XCTAssertEqual(AiringParse.tvmazeID(tvmazeShow), 75026)
        let hits = Data("""
        [{"score":0.9,"show":{"id":1,"name":"Mob Land","premiered":"1999-01-01"}},
         {"score":0.8,"show":{"id":75026,"name":"MobLand","premiered":"2025-03-30"}},
         {"score":0.7,"show":"not a show"}]
        """.utf8)
        // Same name (spaces aside), premiere within a year of Folio's.
        XCTAssertEqual(AiringParse.tvmazeSearch(hits, name: "MobLand", year: 2025), 75026)
        // No year to go by: the first with the name.
        XCTAssertEqual(AiringParse.tvmazeSearch(hits, name: "MobLand", year: nil), 1)
        XCTAssertNil(AiringParse.tvmazeSearch(hits, name: "Something else", year: nil))
    }

    // MARK: AniList

    private let aniListMedia = Data("""
    {"data":{"Media":{"id":21,"idMal":21,"title":{"romaji":"ONE PIECE","english":"ONE PIECE"},"status":"RELEASING","episodes":null,
     "siteUrl":"https://anilist.co/anime/21","nextAiringEpisode":{"airingAt":1798985760,"episode":1181},
     "airingSchedule":{"nodes":[{"airingAt":1798985760,"episode":1181},{"airingAt":1799590560,"episode":1182},{"airingAt":1800195360,"episode":1183}]},
     "coverImage":{"large":"https://s4.anilist.co/file/anilistcdn/media/anime/cover/medium/bx21.jpg"},
     "externalLinks":[{"site":"Twitter","type":"SOCIAL"},{"site":"Crunchyroll","type":"STREAMING"},{"site":"Netflix","type":"STREAMING"}],
     "relations":{"edges":[{"relationType":"SIDE_STORY","node":{"id":466,"type":"ANIME","status":"FINISHED"}}]}}}}
    """.utf8)

    func testAniListMediaWithItsSchedule() throws {
        let f = try XCTUnwrap(AiringParse.aniListMedia(aniListMedia))
        XCTAssertEqual(f.source, .anilist)
        XCTAssertEqual(f.anilist, 21)
        XCTAssertEqual(f.mal, 21)
        XCTAssertEqual(f.status, .airing)
        XCTAssertEqual(f.network, "Crunchyroll")          // the first streaming link
        XCTAssertEqual(f.page, "https://myanimelist.net/anime/21")
        XCTAssertEqual(f.next, AiringEpisode(number: 1181, airDate: Date(timeIntervalSince1970: 1_798_985_760)))
        XCTAssertEqual(f.later.map(\.number), [1182, 1183])
        XCTAssertEqual(f.lastAired?.number, 1180)
        XCTAssertEqual(f.next?.label, "E1181")            // AniList numbers each season on its own
        XCTAssertNil(f.sequel)                            // a side story isn't the next season
    }

    func testAniListNotFound() {
        let data = Data(#"{"errors":[{"message":"Not Found.","status":404}],"data":{"Media":null}}"#.utf8)
        XCTAssertNil(AiringParse.aniListMedia(data))
    }

    /// Frieren on AniList: season 1 and 2 finished, season 3 announced. A
    /// search that matches the announced season picks it; one that only
    /// matches finished seasons takes the first, whose sequel is then followed.
    func testAniListSearchPrefersWhatIsOn() throws {
        let data = Data("""
        {"data":{"Page":{"media":[
          {"id":154587,"idMal":52991,"title":{"romaji":"Sousou no Frieren","english":"Frieren: Beyond Journey’s End"},"status":"FINISHED","episodes":28,
           "relations":{"edges":[{"relationType":"SEQUEL","node":{"id":182255,"type":"ANIME","status":"FINISHED"}},
                                 {"relationType":"ADAPTATION","node":{"id":118586,"type":"MANGA","status":"RELEASING"}}]}},
          {"id":209939,"idMal":null,"title":{"romaji":"Sousou no Frieren 3rd Season","english":null},"status":"NOT_YET_RELEASED","episodes":null,
           "nextAiringEpisode":null,"airingSchedule":{"nodes":[]},"relations":{"edges":[]}},
          {"id":182255,"idMal":59978,"title":{"romaji":"Sousou no Frieren 2nd Season","english":"Frieren: Beyond Journey’s End Season 2"},"status":"FINISHED",
           "relations":{"edges":[{"relationType":"SEQUEL","node":{"id":209939,"type":"ANIME","status":"NOT_YET_RELEASED"}}]}}
        ]}}}
        """.utf8)
        let romaji = try XCTUnwrap(AiringParse.aniListSearch(data, name: "Sousou no Frieren"))
        XCTAssertEqual(romaji.anilist, 209939)
        XCTAssertEqual(romaji.status, .upcoming)
        XCTAssertEqual(romaji.page, "https://anilist.co/anime/209939")   // not on MyAnimeList yet: AniList's page

        let english = try XCTUnwrap(AiringParse.aniListSearch(data, name: "Frieren"))
        XCTAssertEqual(english.anilist, 154587)
        XCTAssertEqual(english.status, .ended)
        XCTAssertEqual(english.lastAired?.number, 28)
        XCTAssertEqual(english.sequel, 182255)            // the manga adaptation isn't a sequel
        XCTAssertEqual(english.page, "https://myanimelist.net/anime/52991")
    }

    // MARK: Anime or series

    func testAnimeGoesToAniListFirst() {
        XCTAssertTrue(AiringRoute.isAnime(id: "kitsu:46474", genres: nil))
        XCTAssertTrue(AiringRoute.isAnime(id: "mal:52991", genres: nil))
        XCTAssertTrue(AiringRoute.isAnime(id: "anilist:154587", genres: nil))
        XCTAssertTrue(AiringRoute.isAnime(id: "tt22248376", genres: ["Animation", "Adventure", "Anime"]))   // IMDbSource's "Anime"
        XCTAssertTrue(AiringRoute.isAnime(id: "tt22248376", genres: ["Animation"], countries: ["JP"]))
        XCTAssertFalse(AiringRoute.isAnime(id: "tt0096697", genres: ["Animation", "Comedy"], countries: ["US"]))
        XCTAssertFalse(AiringRoute.isAnime(id: "tt31510819", genres: ["Drama", "Crime"]))
        // Library episodes get a hint from their file name; only one with an anime database's id counts.
        XCTAssertFalse(AiringRoute.isAnime(id: nil, genres: nil, hint: AnimeHint(title: "MobLand", episode: 3)))
        XCTAssertTrue(AiringRoute.isAnime(id: nil, genres: nil, hint: AnimeHint(title: "Frieren", episode: 3, malId: 52991)))

        var anime = TrackedShow(id: "kitsu:46474", name: "Frieren")
        anime.anime = true
        XCTAssertEqual(AiringService.sources(for: anime), [.anilist, .tvmaze])
        XCTAssertEqual(AiringService.sources(for: TrackedShow(id: "tt31510819", name: "MobLand")), [.tvmaze])
        // Once a source has the show, only that one is asked.
        anime.source = .tvmaze; anime.tvmaze = 64000
        XCTAssertEqual(AiringService.sources(for: anime), [.tvmaze])
        anime.source = .anilist; anime.anilist = 154587
        XCTAssertEqual(AiringService.sources(for: anime), [.anilist])
    }

    func testShowsMadeFromTitlePages() {
        let kitsu = TrackedShow(meta: MetaItem(id: "kitsu:46474", type: "series", name: "Frieren", poster: "https://p/f.jpg",
                                               description: nil, releaseInfo: "2023", imdbRating: nil, genres: ["Adventure"]), imdbID: nil)
        XCTAssertEqual(kitsu.id, "kitsu:46474")
        XCTAssertEqual(kitsu.kitsu, 46474)
        XCTAssertEqual(kitsu.anime, true)
        XCTAssertEqual(kitsu.year, 2023)

        var item = MetaItem(id: "tt31510819", type: "series", name: "MobLand", poster: nil, description: nil, releaseInfo: "2025–", imdbRating: "7.9", genres: ["Crime", "Drama"])
        item.countries = ["GB"]
        let imdb = TrackedShow(meta: item, imdbID: "tt31510819")
        XCTAssertEqual(imdb.id, "tt31510819")
        XCTAssertEqual(imdb.anime, false)
        XCTAssertEqual(imdb.year, 2025)

        let library = TrackedShow(libraryTitle: "Frieren", meta: MediaMeta(id: "tt22248376", type: "series", name: "Frieren: Beyond Journey's End",
                                                                           year: "2023", genres: ["Animation", "Anime"]),
                                  hint: AnimeHint(title: "Sousou no Frieren", episode: 3), season: 2)
        XCTAssertEqual(library.id, "tt22248376")
        XCTAssertEqual(library.name, "Frieren: Beyond Journey's End")
        XCTAssertEqual(library.anime, true)
        XCTAssertEqual(library.season, 2)

        let bare = TrackedShow(libraryTitle: "Some Show", meta: nil, hint: nil, season: 1)
        XCTAssertEqual(bare.id, "name:someshow")
        XCTAssertEqual(bare.anime, false)
    }

    func testTheSameShowFromAnotherPage() {
        var discover = TrackedShow(id: "tt31510819", name: "MobLand"); discover.imdb = "tt31510819"
        var library = TrackedShow(id: "tt31510819", name: "MobLand"); library.imdb = "tt31510819"
        XCTAssertTrue(discover.isSameShow(as: library))
        var byName = TrackedShow(id: "name:mobland", name: "Mob Land")
        XCTAssertTrue(discover.isSameShow(as: byName))
        byName.year = 1999; discover.year = 2025
        XCTAssertFalse(discover.isSameShow(as: byName))
        var other = TrackedShow(id: "tt0000001", name: "MobLand"); other.imdb = "tt0000001"
        XCTAssertFalse(discover.isSameShow(as: other))           // two IMDb ids: two shows
        var anime = TrackedShow(id: "kitsu:46474", name: "Frieren"); anime.mal = 52991
        var fromMAL = TrackedShow(id: "mal:52991", name: "Sousou no Frieren"); fromMAL.mal = 52991
        XCTAssertTrue(anime.isSameShow(as: fromMAL))
    }

    // MARK: Grouping and times

    func testGroupsByWhenTheNextEpisodeAirs() {
        let cal = newYork
        let tonight = show("a", "Tonight", [3 * h])                       // 9 PM
        let justOut = show("b", "Just out", [-2 * h])                     // 4 PM, "Out now"
        let late = show("c", "Late", [5.5 * h])                           // 11:30 PM
        let afterMidnight = show("d", "After midnight", [6.5 * h])        // 12:30 AM Wednesday
        let thursday = show("e", "Thursday", [56 * h])
        let inAWeek = show("f", "In a week", [7 * 24 * h - 6 * h])        // next Tuesday noon
        let later = show("g", "Later", [8 * 24 * h])
        let ended = show("h", "Ended", [], status: .ended)
        let stale = show("i", "Long out", [-10 * h])                      // out, but more than six hours ago
        let all = [later, ended, thursday, tonight, stale, afterMidnight, justOut, inAWeek, late]

        XCTAssertEqual(AiringGroup.of(tonight, now: now, calendar: cal), .today)
        XCTAssertEqual(AiringGroup.of(justOut, now: now, calendar: cal), .today)
        XCTAssertEqual(AiringGroup.of(afterMidnight, now: now, calendar: cal), .week)
        XCTAssertEqual(AiringGroup.of(stale, now: now, calendar: cal), .other)

        let groups = AiringGroup.grouped(all, now: now, calendar: cal)
        XCTAssertEqual(groups.map(\.group), [.today, .week, .later, .other])
        XCTAssertEqual(groups[0].shows.map(\.id), ["b", "a", "c"])       // soonest first, the one out now on top
        XCTAssertEqual(groups[1].shows.map(\.id), ["d", "e", "f"])
        XCTAssertEqual(groups[2].shows.map(\.id), ["g"])
        XCTAssertEqual(groups[3].shows.map(\.name), ["Ended", "Long out"])
    }

    func testTimesInYourTimeZone() {
        let cal = newYork
        XCTAssertEqual(plain(AiringFormat.when(now.addingTimeInterval(3 * h), now: now, calendar: cal, locale: us)), "Today 9:00 PM")
        XCTAssertEqual(plain(AiringFormat.when(now.addingTimeInterval(6.5 * h), now: now, calendar: cal, locale: us)), "Tomorrow 12:30 AM")
        XCTAssertEqual(plain(AiringFormat.when(now.addingTimeInterval(32.5 * h), now: now, calendar: cal, locale: us)), "Thu 2:30 AM")
        XCTAssertEqual(plain(AiringFormat.when(now.addingTimeInterval(-20 * h), now: now, calendar: cal, locale: us)), "Yesterday 10:00 PM")
        XCTAssertEqual(plain(AiringFormat.when(now.addingTimeInterval(17 * 24 * h), now: now, calendar: cal, locale: us)), "Nov 20, 6:00 PM")
        XCTAssertEqual(plain(AiringFormat.when(Date(timeIntervalSince1970: 1_558_314_000), now: now, calendar: cal, locale: us)), "May 19, 2019, 9:00 PM")
        // The same moment in Tokyo is Wednesday morning.
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(plain(AiringFormat.when(now.addingTimeInterval(3 * h), now: now, calendar: tokyo, locale: us)), "Today 11:00 AM")

        XCTAssertEqual(AiringFormat.countdown(to: now.addingTimeInterval(3 * h), now: now), "in 3 h")
        XCTAssertEqual(AiringFormat.countdown(to: now.addingTimeInterval(45 * 60), now: now), "in 45 min")
        XCTAssertEqual(AiringFormat.countdown(to: now.addingTimeInterval(50 * h), now: now), "in 2 days")
        XCTAssertEqual(AiringFormat.countdown(to: now.addingTimeInterval(-h), now: now), "Out now")
        XCTAssertEqual(AiringFormat.countdown(to: now.addingTimeInterval(-7 * h), now: now), "Aired")
    }

    func testWhatSiriSays() {
        var s = show("tt31510819", "MobLand", [3 * h])
        s.next?.season = 2; s.next?.number = 8; s.next?.title = "We Don't Talk Anymore"
        let said = plain(AiringFormat.spoken(s, now: now, calendar: newYork, locale: us))
        XCTAssertTrue(said.hasPrefix("MobLand season 2, episode 8, “We Don't Talk Anymore”, airs today at 9:00 PM, in 3 hours"), said)
        XCTAssertEqual(AiringFormat.spoken(show("x", "Gone", [], status: .ended), now: now, calendar: newYork, locale: us), "Gone has ended.")
        XCTAssertEqual(AiringFormat.spoken(show("y", "Waiting", []), now: now, calendar: newYork, locale: us),
                       "There's no date for the next episode of Waiting yet.")
    }

    // MARK: Notifications

    func testNotificationsForTheSoonestEpisodes() {
        var mobland = show("tt31510819", "MobLand", [2 * h])
        mobland.next = AiringEpisode(season: 2, number: 8, title: "We Don't Talk Anymore", airDate: now.addingTimeInterval(2 * h))
        mobland.network = "Paramount+"
        var anime = show("anilist:21", "One Piece", [0.5 * h, 24 * h, 8 * 24 * h])
        anime.next?.season = nil; anime.later = anime.later?.map { var e = $0; e.season = nil; return e }
        let past = show("p", "Already out", [-h])
        let thursday = show("t", "Thursday", [56 * h])
        let shows = [thursday, past, mobland, anime]

        let soonest = AiringNotifications.plan(shows, now: now, mode: .air, limit: 3)
        XCTAssertEqual(soonest.map(\.showID), ["anilist:21", "tt31510819", "anilist:21"])
        XCTAssertEqual(soonest.map(\.fire), [now.addingTimeInterval(0.5 * h), now.addingTimeInterval(2 * h), now.addingTimeInterval(24 * h)])
        XCTAssertEqual(soonest[1].title, "MobLand S2 · E8 is out")
        XCTAssertEqual(soonest[1].body, "We Don't Talk Anymore · On Paramount+")
        XCTAssertEqual(soonest[0].title, "One Piece E1 is out")
        XCTAssertEqual(Set(soonest.map(\.id)).count, 3)
        XCTAssertTrue(soonest.allSatisfy { $0.id.hasPrefix(AiringNotifications.prefix) })

        // An hour before: the episode 30 minutes away is too late for one.
        let early = AiringNotifications.plan(shows, now: now, mode: .hour)
        XCTAssertEqual(early.first?.showID, "tt31510819")
        XCTAssertEqual(early.first?.fire, now.addingTimeInterval(h))
        XCTAssertEqual(early.first?.title, "MobLand S2 · E8 is out in an hour")
        XCTAssertEqual(early.count, 4)                    // MobLand's, One Piece's next two, Thursday's
        XCTAssertFalse(early.contains { $0.fire <= now })

        XCTAssertTrue(AiringNotifications.plan(shows, now: now, mode: .off).isEmpty)
    }

    func testAtMostFortyPendingAcrossAllShows() {
        let many = (0..<60).map { i in show("s\(i)", "Show \(i)", [TimeInterval(60 - i) * h]) }
        let planned = AiringNotifications.plan(many, now: now, mode: .air)
        XCTAssertEqual(planned.count, 40)
        XCTAssertEqual(planned.first?.showID, "s59")
        XCTAssertEqual(planned.map(\.fire), planned.map(\.fire).sorted())
        XCTAssertFalse(planned.contains { $0.showID == "s0" })           // the furthest off wait their turn
    }

    func testBackgroundRefreshComesAfterTheNextAirTime() {
        let soon = show("a", "A", [2 * h])
        XCTAssertEqual(AiringBackground.earliest([soon], now: now), now.addingTimeInterval(2 * h + 15 * 60))
        XCTAssertEqual(AiringBackground.earliest([soon, show("b", "B", [60])], now: now), now.addingTimeInterval(60 + 15 * 60))
        XCTAssertEqual(AiringBackground.earliest([show("c", "C", [30 * h])], now: now), now.addingTimeInterval(6 * h))
        XCTAssertEqual(AiringBackground.earliest([show("d", "D", [], status: .ended)], now: now), now.addingTimeInterval(6 * h))
    }

    // MARK: Saved list

    func testTheSavedListReadsEntriesItDoesNotFullyKnow() throws {
        let saved = Data("""
        [{"id":"tt31510819","name":"MobLand","status":"airing","source":"tvmaze","tvmaze":75026,"futureField":{"x":1},
          "next":{"season":2,"number":8,"airDate":815000000,"newThing":true}},
         {"id":"mal:52991","name":"Frieren","status":"on-a-break","source":"some-new-source"},
         {"id":"no-name"},
         {"id":"name:minimal","name":"Minimal"},
         {"id":123,"name":"A number for an id"}]
        """.utf8)
        let shows = try XCTUnwrap(TrackingStore.decode(saved))
        XCTAssertEqual(shows.map(\.id), ["tt31510819", "mal:52991", "name:minimal"])
        XCTAssertEqual(shows[0].status, .airing)
        XCTAssertEqual(shows[0].tvmaze, 75026)
        XCTAssertEqual(shows[0].next?.number, 8)
        XCTAssertEqual(shows[0].next?.airDate, Date(timeIntervalSinceReferenceDate: 815_000_000))
        XCTAssertEqual(shows[1].status, .unknown)         // a status a later version added
        XCTAssertEqual(shows[1].source, .unknown)
        XCTAssertNil(shows[2].status)
        XCTAssertNil(shows[2].updated)
        XCTAssertNil(TrackingStore.decode(Data("{}".utf8)))   // not a list: nothing (the file is kept aside)
    }

    func testTheSavedListRoundTrips() throws {
        var s = show("tt31510819", "MobLand", [2 * h, 9 * 24 * h])
        s.imdb = "tt31510819"; s.network = "Paramount+"; s.source = .tvmaze; s.page = "https://www.tvmaze.com/shows/75026/mobland"
        s.lastAired = AiringEpisode(season: 2, number: 7, title: "Ace of Spades", airDate: now.addingTimeInterval(-7 * 24 * h))
        let data = try JSONEncoder().encode([s, TrackedShow(id: "name:x", name: "X")])
        XCTAssertEqual(TrackingStore.decode(data), [s, TrackedShow(id: "name:x", name: "X")])
    }

    /// A fetch puts in the schedule and keeps what you tracked it with.
    func testAFetchKeepsTheNameAndPoster() throws {
        var s = TrackedShow(id: "tt31510819", name: "MobLand")
        s.imdb = "tt31510819"; s.poster = "https://imdb/poster.jpg"
        s.apply(try XCTUnwrap(AiringParse.tvmazeShow(tvmazeShow)), at: now)
        XCTAssertEqual(s.name, "MobLand")
        XCTAssertEqual(s.poster, "https://imdb/poster.jpg")
        XCTAssertEqual(s.tvmaze, 75026)
        XCTAssertEqual(s.next?.number, 8)
        XCTAssertEqual(s.updated, now)
        XCTAssertEqual(s.pageLink?.title, "TVmaze")
    }

    // MARK: Widget and Home

    func testTheWidgetSnapshotAndItsTimeline() {
        let out = show("a", "Just out", [-h])
        let soon = show("b", "Soon", [2 * h, 26 * h])
        let ended = show("c", "Ended", [], status: .ended)
        let snap = AiringSnapshotWriter.snapshot([soon, ended, out], now: now)
        XCTAssertEqual(snap.items.map(\.id), ["a", "b"])            // nothing to show for an ended one
        XCTAssertEqual(snap.items[1].episodes.count, 2)

        let rows = snap.rows(at: now)
        XCTAssertEqual(rows.map(\.id), ["a", "b"])
        XCTAssertTrue(rows[0].isOut)
        XCTAssertFalse(rows[1].isOut)
        // Two hours on, without the app: both are out, the newest first.
        let later = snap.rows(at: now.addingTimeInterval(2 * h))
        XCTAssertEqual(later.map(\.id), ["b", "a"])
        XCTAssertTrue(later.allSatisfy(\.isOut))
        // Six hours after it aired, "Just out" is gone; "Soon" moves to its next.
        let evening = snap.rows(at: now.addingTimeInterval(9 * h))
        XCTAssertEqual(evening.map(\.id), ["b"])
        XCTAssertEqual(evening.first?.episode.airDate, now.addingTimeInterval(26 * h))

        XCTAssertEqual(snap.timelineDates(from: now), [now, now.addingTimeInterval(2 * h), now.addingTimeInterval(5 * h),
                                                         now.addingTimeInterval(8 * h), now.addingTimeInterval(26 * h), now.addingTimeInterval(32 * h)])
    }

    func testTheTrackLink() {
        for id in ["tt31510819", "mal:52991", "name:mob land & co?"] {
            let url = TrackLink.url(id: id)
            XCTAssertEqual(url.scheme, "folio")
            XCTAssertEqual(url.host, "track")
            XCTAssertEqual(TrackLink.id(from: url), id)
        }
        XCTAssertNil(TrackLink.id(from: URL(string: "folio://continue?id=tt1")!))
        XCTAssertNil(TrackLink.id(from: URL(string: "folio://track?id=")!))
    }

    func testHomeRowShowsTheNextSevenDays() {
        let shows = [show("a", "A", [3 * h, 3 * 24 * h, 9 * 24 * h]), show("b", "B", [-h]), show("c", "C", [8 * 24 * h]), show("d", "D", [-10 * h])]
        let slots = AiringRow.slots(shows, now: now)
        XCTAssertEqual(slots.map(\.show.id), ["b", "a", "a"])
        XCTAssertEqual(slots.map { $0.episode.airDate }, [now.addingTimeInterval(-h), now.addingTimeInterval(3 * h), now.addingTimeInterval(3 * 24 * h)])
        XCTAssertTrue(AiringRow.slots([show("e", "E", [], status: .ended)], now: now).isEmpty)
    }
}
