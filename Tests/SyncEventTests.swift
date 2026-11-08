import XCTest
@testable import Folio

/// 1.26.0: what the sync services are sent, and the Airing now row's dates.
final class SyncEventTests: XCTestCase {
    func testLabelsAndKeys() {
        let ep = SyncEvent(title: "The Gentlemen", imdb: "tt13210838", season: 2, episode: 1, isMovie: false,
                           anime: nil, looksLikeAnime: false, watchedAt: Date())
        XCTAssertEqual(ep.label, "The Gentlemen S2E1")
        XCTAssertEqual(ep.key, "tt13210838|2|1")

        var hint = AnimeHint()
        hint.title = "Frieren"
        hint.episode = 5
        let anime = SyncEvent(title: "Frieren", imdb: nil, season: nil, episode: nil, isMovie: false,
                              anime: hint, looksLikeAnime: true, watchedAt: Date())
        XCTAssertEqual(anime.label, "Frieren E5")
        XCTAssertEqual(anime.key, "Frieren|0|5")

        let film = SyncEvent(title: "Dune", imdb: "tt1160419", season: nil, episode: nil, isMovie: true,
                             anime: nil, looksLikeAnime: false, watchedAt: Date())
        XCTAssertEqual(film.label, "Dune")
    }

    func testEventsSurviveTheQueueOnDisk() throws {
        let e = SyncEvent(title: "Show", imdb: "tt1", season: 1, episode: 3, isMovie: false, anime: nil, looksLikeAnime: false,
                          watchedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try dec.decode(SyncEvent.self, from: enc.encode(e)), e)
    }

    func testRelativeDays() {
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12))!
        XCTAssertEqual(AiringCatalog.relative(now, now: now), "today")
        XCTAssertEqual(AiringCatalog.relative(now.addingTimeInterval(86_400), now: now), "tomorrow")
        XCTAssertEqual(AiringCatalog.relative(now.addingTimeInterval(-86_400), now: now), "yesterday")
        XCTAssertEqual(AiringCatalog.relative(now.addingTimeInterval(6 * 86_400), now: now), "in 6 days")
    }

    func testFormBodyEncodesReservedCharacters() {
        XCTAssertEqual(SyncHTTP.formBody(["b": "a b&c", "a": "x=y"]), "a=x%3Dy&b=a%20b%26c")
    }
}
