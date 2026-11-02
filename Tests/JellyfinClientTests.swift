import XCTest
@testable import Folio

/// Jellyfin (1.20.3, 2 Nov): the sign-in header and request, the answers
/// read from inline fixtures (no server), the addresses, and that the token
/// travels in a header and is never saved. Not tested: a real server.
final class JellyfinClientTests: XCTestCase {
    private let base = URL(string: "http://192.168.1.20:8096")!
    private var server: MediaServer {
        var s = MediaServer(kind: .jellyfin, name: "Home", address: "192.168.1.20", username: "neo")
        s.id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        return s
    }

    func testAddressGetsSchemeAndPort() {
        XCTAssertEqual(MediaServer.baseURL("192.168.1.20", defaultPort: 8096)?.absoluteString, "http://192.168.1.20:8096")
        XCTAssertEqual(MediaServer.baseURL("https://jf.example.com/", defaultPort: 8096)?.absoluteString, "https://jf.example.com")
        XCTAssertEqual(MediaServer.baseURL("https://example.com/jellyfin/", defaultPort: 8096)?.absoluteString, "https://example.com/jellyfin")
        XCTAssertEqual(MediaServer.baseURL("http://nas:9000", defaultPort: 8096)?.absoluteString, "http://nas:9000")
        XCTAssertNil(MediaServer.baseURL("  ", defaultPort: 8096))
        XCTAssertNil(MediaServer.baseURL("ftp://nas", defaultPort: 8096))
        XCTAssertEqual(server.baseURL, base)
    }

    func testAuthorizationHeader() {
        let h = JellyfinAPI.authorization(device: "iPhone", deviceID: "ABC-123", version: "1.20.3")
        XCTAssertEqual(h, #"MediaBrowser Client="Folio", Device="iPhone", DeviceId="ABC-123", Version="1.20.3""#)
        let signed = JellyfinAPI.authorization(device: "iPad \"Pro\", 13", deviceID: "ABC", version: "1", token: "tok")
        XCTAssertEqual(signed, #"MediaBrowser Client="Folio", Device="iPad Pro  13", DeviceId="ABC", Version="1", Token="tok""#)
    }

    func testSignInRequest() throws {
        let r = try XCTUnwrap(JellyfinAPI.signInRequest(base: base, username: "neo", password: "p@ss \"word\"", device: "iPhone",
                                                       deviceID: server.id.uuidString, version: "1.20.3"))
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.url?.absoluteString, "http://192.168.1.20:8096/Users/AuthenticateByName")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let auth = try XCTUnwrap(r.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(auth.hasPrefix(#"MediaBrowser Client="Folio""#), auth)
        XCTAssertTrue(auth.contains(#"DeviceId="11111111-2222-3333-4444-555555555555""#), "one stable device id per server")
        XCTAssertFalse(auth.contains("Token="))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(r.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["Username": "neo", "Pw": "p@ss \"word\""])
    }

    func testSignInAnswer() throws {
        let json = #"{"User":{"Name":"neo","Id":"f00dfeed","Policy":{"IsAdministrator":false}},"SessionInfo":{},"AccessToken":"0123456789abcdef","ServerId":"srv"}"#
        let s = try JellyfinAPI.decodeSignIn(Data(json.utf8))
        XCTAssertEqual(s.token, "0123456789abcdef")
        XCTAssertEqual(s.userID, "f00dfeed")
        XCTAssertEqual(s.userName, "neo")
        XCTAssertThrowsError(try JellyfinAPI.decodeSignIn(Data(#"{"User":{"Id":"x"}}"#.utf8)))
    }

    private let views = """
    {"Items":[
      {"Name":"Films","Id":"lib1","Type":"CollectionFolder","CollectionType":"movies","IsFolder":true,"ImageTags":{"Primary":"t1"}},
      {"Name":"Shows","Id":"lib2","Type":"CollectionFolder","CollectionType":"tvshows","IsFolder":true},
      {"Name":"Books","Id":"lib3","Type":"CollectionFolder","CollectionType":"books","IsFolder":true}
    ],"TotalRecordCount":3,"StartIndex":0}
    """

    func testLibraries() throws {
        let items = try JellyfinAPI.decodeItems(Data(views.utf8))
        XCTAssertEqual(items.map(\.id), ["lib1", "lib2", "lib3"])
        XCTAssertEqual(items.map(\.entry.kind), [.library, .library, .library])
        XCTAssertEqual(items[0].entry.children, "lib1")
        XCTAssertTrue(JellyfinAPI.skippedLibraries.contains(items[2].collectionType ?? ""))
        XCTAssertEqual(JellyfinAPI.viewsURL(base: base, userID: "f00dfeed")?.absoluteString, "http://192.168.1.20:8096/Users/f00dfeed/Views")
    }

    private let season = """
    {"Items":[
      {"Name":"The Journey's End","Id":"ep2","Type":"Episode","IsFolder":false,"MediaType":"Video","IndexNumber":2,"ParentIndexNumber":1,
       "SeriesName":"Frieren","SeriesId":"s1","SeasonId":"se1","RunTimeTicks":14400000000,"DateCreated":"2024-01-05T10:20:30.1234567Z",
       "Path":"/media/Frieren/Season 1/Frieren.S01E02.1080p.mkv","MediaSources":[{"Size":1500000000,"Container":"mkv"}],"ImageTags":{"Primary":"abc"}},
      {"Name":"Episode 1","Id":"ep1","Type":"Episode","IsFolder":false,"MediaType":"Video","IndexNumber":1,"ParentIndexNumber":1,"SeriesName":"Frieren",
       "DateCreated":"2024-01-04T09:00:00Z","UnknownField":{"x":[1,2]}},
      {"Name":"Odd","Id":"odd","Type":"Episode","IndexNumber":"three"},
      {"Name":"No id"}
    ]}
    """

    func testEpisodesReadAndSort() throws {
        let items = try JellyfinAPI.decodeItems(Data(season.utf8))
        XCTAssertEqual(items.map(\.id), ["ep2", "ep1", "odd"], "an item without an id is skipped, not the listing")
        let e = items[0].entry
        XCTAssertEqual(e.kind, .episode)
        XCTAssertEqual(e.season, 1)
        XCTAssertEqual(e.episode, 2)
        XCTAssertEqual(e.size, 1_500_000_000)
        XCTAssertEqual(e.duration, 1440)
        XCTAssertEqual(e.fileName, "Frieren.S01E02.1080p.mkv")
        XCTAssertEqual(e.image, "abc")
        XCTAssertEqual(e.added, ISO8601DateFormatter().date(from: "2024-01-05T10:20:30Z"), "seven digits of fractions")
        XCTAssertNil(items[2].index, "a number sent as text is dropped, not the item")
        let ordered = CatalogOrder.sorted(items.map(\.entry), by: .name, ascending: true)
        XCTAssertEqual(ordered.map(\.id).prefix(2), ["ep1", "ep2"], "episodes in episode order")
        XCTAssertEqual(CatalogTitles.tag(e), "S1 · E2")
        XCTAssertEqual(CatalogTitles.playerTitle(e), "Frieren · S01E02")
        XCTAssertEqual(CatalogTitles.playerSubtitle(e), "The Journey's End")
    }

    func testFilmTitles() throws {
        let json = """
        {"Items":[
          {"Name":"Dune: Part Two","Id":"m1","Type":"Movie","IsFolder":false,"MediaType":"Video","ProductionYear":2024},
          {"Name":"Dune.Part.Two.2024.2160p.WEB-DL.x265-GRP","Id":"m2","Type":"Movie","IsFolder":false,"MediaType":"Video"},
          {"Name":"Collection","Id":"b1","Type":"BoxSet","IsFolder":true,"ChildCount":4},
          {"Name":"Clip","Id":"v1","Type":"Video","IsFolder":false,"MediaType":"Video"}
        ]}
        """
        let e = try JellyfinAPI.decodeItems(Data(json.utf8)).map(\.entry)
        XCTAssertEqual(e.map(\.kind), [.movie, .movie, .folder, .video])
        XCTAssertEqual(CatalogTitles.playerTitle(e[0]), "Dune: Part Two (2024)")
        XCTAssertEqual(CatalogTitles.playerTitle(e[1]), TitleParser.clean("Dune.Part.Two.2024.2160p.WEB-DL.x265-GRP"))
        XCTAssertFalse(CatalogTitles.playerTitle(e[1]).contains("2160p"))
        XCTAssertEqual(e[2].children, "b1")
        let ordered = CatalogOrder.sorted(e, by: .name, ascending: true)
        XCTAssertEqual(ordered.first?.id, "b1", "what opens comes before what plays")
    }

    func testAddresses() {
        let items = JellyfinAPI.itemsURL(base: base, userID: "u1", parentID: "lib1", episodes: false)
        let q = URLComponents(url: items!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items?.path, "/Users/u1/Items")
        XCTAssertEqual(q.first { $0.name == "ParentId" }?.value, "lib1")
        XCTAssertEqual(q.first { $0.name == "SortBy" }?.value, "SortName")
        XCTAssertFalse(q.first { $0.name == "Fields" }?.value?.contains("MediaSources") ?? true)
        let eps = JellyfinAPI.itemsURL(base: base, userID: "u1", parentID: "se1", episodes: true)
        let eq = URLComponents(url: eps!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(eq.first { $0.name == "SortBy" }?.value, "ParentIndexNumber,IndexNumber,SortName")
        XCTAssertEqual(JellyfinAPI.streamURL(base: base, itemID: "ep2")?.absoluteString, "http://192.168.1.20:8096/Videos/ep2/stream?static=true")
        let proxied = URL(string: "https://example.com/jellyfin")!
        XCTAssertEqual(JellyfinAPI.streamURL(base: proxied, itemID: "a/b")?.absoluteString, "https://example.com/jellyfin/Videos/a%2Fb/stream?static=true")
    }

    func testPlaysWithTheTokenInAHeaderAndSavesNone() throws {
        let entry = try JellyfinAPI.decodeItems(Data(season.utf8))[0].entry
        let item = JellyfinClient.mediaItem(for: entry, parent: "se1", server: server, base: base)
        XCTAssertEqual(item.historyKey, "jellyfin:11111111-2222-3333-4444-555555555555:ep2")
        XCTAssertEqual(item.remote, ServerItemRef(kind: .jellyfin, serverID: server.id, id: "ep2", parent: "se1"))
        XCTAssertTrue(item.headers.isEmpty, "made without the login")
        XCTAssertEqual(item.anime?.title, "Frieren")
        XCTAssertEqual(item.anime?.episode, 2)

        let ready = ServerPlayback.prepared(item, item.remote!, server: server, token: "SECRET-TOKEN", password: nil)
        XCTAssertEqual(ready.headers["X-Emby-Token"], "SECRET-TOKEN")
        XCTAssertFalse(ready.url.contains("SECRET"), "never in the address")
        XCTAssertEqual(ready.url, "http://192.168.1.20:8096/Videos/ep2/stream?static=true")

        let saved = try JSONEncoder().encode(HistoryEntry(item: ready, position: 60, duration: 1440, updated: Date()))
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("SECRET"), "history keeps no token")
        let back = try JSONDecoder().decode(HistoryEntry.self, from: saved)
        XCTAssertEqual(back.id, item.historyKey)
        XCTAssertEqual(back.item.remote, item.remote)
    }

    func testServerThatMovedKeepsItsItems() {
        var moved = server
        moved.address = "https://jf.example.com"
        let item = JellyfinClient.mediaItem(for: CatalogEntry(id: "m1", kind: .movie, name: "Dune"), parent: nil, server: server, base: base)
        let ready = ServerPlayback.prepared(item, item.remote!, server: moved, token: "t", password: nil)
        XCTAssertEqual(ready.url, "https://jf.example.com/Videos/m1/stream?static=true")
        XCTAssertEqual(ready.id, item.id, "same history key")
    }
}
