import XCTest
@testable import GlassPlayer

/// Titles and episodes are saved to disk (IMDb cache, metadata cache) and read
/// back on later lookups: every field must survive that. A field missing from
/// the hand-written Codable is lost from the second lookup on (29 Oct: the
/// romaji under the title came back as the episode name).
final class MetaCodingTests: XCTestCase {
    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    func testTitleKeepsEveryField() throws {
        var m = MetaItem(id: "tt7263328", type: "series", name: "Classroom of the Elite", poster: "https://p", description: "d",
                         releaseInfo: "2017", imdbRating: "7.7", genres: ["Animation", "Anime"], rank: 3)
        m.posterShape = "poster"
        m.background = "https://b"
        m.logo = "https://l"
        m.runtime = "24m"
        var v = MetaVideo(id: "tt1:1:1", title: "What is evil?", season: 1, episode: 1)
        v.originalTitle = "Aku to wa nani ka"
        m.videos = [v]
        m.cast = ["Shoya Chiba"]
        m.originalName = "Yôkoso jitsuryoku shijô shugi no kyôshitsu e"
        m.director = ["Seiji Kishi"]
        m.contentRating = "TV-14"
        m.countries = ["JP"]
        m.credits = [CastMember(id: "nm1", name: "Shoya Chiba", character: "Kiyotaka", photo: "https://f")]
        m.wikipedia = "https://en.wikipedia.org/wiki/Classroom_of_the_Elite"
        let back = try roundTrip(m)
        XCTAssertEqual(back.originalName, m.originalName, "the original (romaji) title")
        XCTAssertEqual(back, m, "a field was lost on the way through the cache")
    }

    func testEpisodeKeepsEveryField() throws {
        var v = MetaVideo(id: "tt1:1:2", title: "It takes a great talent", season: 1, episode: 2)
        v.released = "2017-07-19"
        v.thumbnail = "https://t"
        v.overview = "o"
        v.rating = "7.5"
        v.imdbId = "tt7263400"
        v.originalTitle = "Nōaru taka wa tsume o kakusu"
        let back = try roundTrip(v)
        XCTAssertEqual(back.originalTitle, v.originalTitle, "the episode's original title")
        XCTAssertEqual(back, v, "a field was lost on the way through the cache")
    }
}
