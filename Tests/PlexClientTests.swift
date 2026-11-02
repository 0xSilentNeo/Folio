import XCTest
@testable import Folio

/// Plex (1.20.3, 2 Nov): JSON answers read from inline fixtures (no
/// server), the addresses and headers, and that the X-Plex-Token travels
/// in a header and is never saved. Not tested: a real server.
final class PlexClientTests: XCTestCase {
    private let base = URL(string: "http://192.168.1.20:32400")!
    private var server: MediaServer {
        var s = MediaServer(kind: .plex, name: "Plex", address: "192.168.1.20")
        s.id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        return s
    }

    func testAddressGetsThePlexPort() {
        XCTAssertEqual(server.baseURL, base)
    }

    func testSections() throws {
        let json = """
        {"MediaContainer":{"size":3,"allowSync":false,"title1":"Plex Library","Directory":[
          {"allowSync":true,"art":"/:/resources/movie-fanart.jpg","key":"1","type":"movie","title":"Films","agent":"tv.plex.agents.movie","Location":[{"id":1,"path":"/data/films"}]},
          {"key":"2","type":"show","title":"Shows","thumb":"/:/resources/show.png"},
          {"key":3,"type":"photo","title":"Photos"}
        ]}}
        """
        let items = try PlexAPI.decode(Data(json.utf8))
        XCTAssertEqual(items.map(\.key), ["1", "2", "3"], "a key sent as a number still reads")
        let e = items[0].sectionEntry
        XCTAssertEqual(e.kind, .library)
        XCTAssertEqual(e.libraryType, "movie")
        XCTAssertEqual(e.children, "/library/sections/1/all")
        XCTAssertTrue(PlexAPI.skippedSections.contains(items[2].type ?? ""))
        XCTAssertEqual(PlexAPI.sectionsURL(base: base)?.absoluteString, "http://192.168.1.20:32400/library/sections")
    }

    private let films = """
    {"MediaContainer":{"size":3,"librarySectionID":1,"viewGroup":"movie","Metadata":[
      {"ratingKey":"101","key":"/library/metadata/101","type":"movie","title":"Dune","year":2021,"thumb":"/library/metadata/101/thumb/1700000000",
       "duration":9360000,"addedAt":1690000000,"viewOffset":120000,
       "Media":[{"id":201,"duration":9360000,"container":"mkv","videoResolution":"4k",
         "Part":[{"id":301,"key":"/library/parts/301/1690000000/file.mkv","duration":9360000,"file":"/data/films/Dune (2021)/Dune.2021.2160p.mkv","size":40000000000,"container":"mkv"}]},
         {"id":202,"Part":[{"id":302,"key":"/library/parts/302/1/file.mp4"}]}]},
      {"ratingKey":102,"key":"/library/metadata/102/children","type":"show","title":"Frieren","year":"2023","childCount":2,"leafCount":28},
      {"ratingKey":"103","key":"/library/collections/103/children","type":"collection","title":"Arrakis","childCount":2}
    ]}}
    """

    func testFilmsShowsAndCollections() throws {
        let e = try PlexAPI.decode(Data(films.utf8)).map(\.entry)
        XCTAssertEqual(e.map(\.kind), [.movie, .series, .folder])
        XCTAssertEqual(e[0].id, "101")
        XCTAssertEqual(e[0].part, "/library/parts/301/1690000000/file.mkv", "the first file of the first version")
        XCTAssertEqual(e[0].size, 40_000_000_000)
        XCTAssertEqual(e[0].duration, 9360)
        XCTAssertEqual(e[0].added, Date(timeIntervalSince1970: 1_690_000_000))
        XCTAssertEqual(e[0].fileName, "Dune.2021.2160p.mkv")
        XCTAssertEqual(CatalogTitles.playerTitle(e[0]), "Dune (2021)")
        XCTAssertEqual(e[1].id, "102", "a rating key sent as a number still reads")
        XCTAssertEqual(e[1].year, 2023, "a year sent as text still reads")
        XCTAssertEqual(e[1].children, "/library/metadata/102/children")
        XCTAssertEqual(e[1].childCount, 2, "a show counts its seasons")
        XCTAssertEqual(e[2].children, "/library/collections/103/children")
    }

    func testSeasonsAndEpisodes() throws {
        let seasons = """
        {"MediaContainer":{"size":2,"parentTitle":"Frieren","Metadata":[
          {"ratingKey":"201","key":"/library/metadata/201/children","parentRatingKey":"102","type":"season","title":"Season 2","index":2,"leafCount":10},
          {"ratingKey":"200","key":"/library/metadata/200/children","parentRatingKey":"102","type":"season","title":"Season 1","index":1,"leafCount":28}
        ]}}
        """
        let s = try PlexAPI.decode(Data(seasons.utf8)).map(\.entry)
        XCTAssertEqual(CatalogOrder.sorted(s, by: .name, ascending: true).map(\.id), ["200", "201"])
        XCTAssertEqual(s[1].season, 1)
        XCTAssertEqual(CatalogTitles.details(s[1]), ["28 episodes"])

        let episodes = """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"311","key":"/library/metadata/311","parentRatingKey":"200","type":"episode","title":"The Journey's End","grandparentTitle":"Frieren",
           "index":1,"parentIndex":1,"duration":1440000,"Media":[{"Part":[{"key":"/library/parts/411/1/file.mkv","size":1500000000}]}]},
          {"ratingKey":"312","key":"/library/metadata/312","type":"episode","title":"No file","index":2,"parentIndex":1}
        ]}}
        """
        let e = try PlexAPI.decode(Data(episodes.utf8)).map(\.entry)
        XCTAssertEqual(e[0].kind, .episode)
        XCTAssertEqual(CatalogTitles.tag(e[0]), "S1 · E1")
        XCTAssertEqual(CatalogTitles.playerTitle(e[0]), "Frieren · S01E01")
        XCTAssertEqual(e[1].kind, .folder, "nothing to play without a file")
    }

    func testHeadersAndAddresses() throws {
        let h = PlexAPI.headers(token: "TOK", clientID: server.id.uuidString)
        XCTAssertEqual(h["Accept"], "application/json")
        XCTAssertEqual(h["X-Plex-Token"], "TOK")
        XCTAssertEqual(h["X-Plex-Client-Identifier"], "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual(PlexAPI.childrenURL(base: base, path: "/library/metadata/102/children")?.absoluteString,
                       "http://192.168.1.20:32400/library/metadata/102/children")
        XCTAssertEqual(PlexAPI.partURL(base: base, part: "/library/parts/301/1690000000/file.mkv")?.absoluteString,
                       "http://192.168.1.20:32400/library/parts/301/1690000000/file.mkv")
        let img = try XCTUnwrap(PlexAPI.imageURL(base: base, thumb: "/library/metadata/101/thumb/1700000000", height: 120, poster: true))
        XCTAssertEqual(img.path, "/photo/:/transcode")
        let q = URLComponents(url: img, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(q.first { $0.name == "url" }?.value, "/library/metadata/101/thumb/1700000000")
        XCTAssertEqual(q.first { $0.name == "width" }?.value, "80")
        XCTAssertFalse(img.absoluteString.contains("Token"))
    }

    func testPlaysWithTheTokenInAHeaderAndSavesNone() throws {
        let entry = try PlexAPI.decode(Data(films.utf8))[0].entry
        let item = PlexClient.mediaItem(for: entry, parent: "/library/sections/1/all", server: server, base: base)
        XCTAssertEqual(item.historyKey, "plex:AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE:101", "keyed by rating key, not the file")
        XCTAssertEqual(item.remote?.part, "/library/parts/301/1690000000/file.mkv")
        XCTAssertNil(item.artwork, "Plex pictures need the token")
        XCTAssertTrue(item.headers.isEmpty)

        let ready = ServerPlayback.prepared(item, item.remote!, server: server, token: "PLEX-SECRET", password: nil)
        XCTAssertEqual(ready.headers["X-Plex-Token"], "PLEX-SECRET")
        XCTAssertEqual(ready.url, "http://192.168.1.20:32400/library/parts/301/1690000000/file.mkv")

        let saved = String(decoding: try JSONEncoder().encode(ready), as: UTF8.self)
        XCTAssertFalse(saved.contains("PLEX-SECRET"), saved)
        XCTAssertTrue(saved.contains("plex:AAAAAAAA"))
    }
}
