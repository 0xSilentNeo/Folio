import XCTest
@testable import Folio

/// Addon answers and saved lists (1.20.3): one entry this version can't read
/// used to drop the whole list.
final class LenientDecodingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testCatalogKeepsTheGoodItems() throws {
        let r = try decode(AddonAPI.CatalogResponse.self, #"{"metas":[{"id":"tt1","name":"One"},{"name":"no id"},{"id":"tt3","name":"Three"}]}"#)
        XCTAssertEqual(r.metas?.map(\.id), ["tt1", "tt3"])
    }

    func testEpisodesKeepTheGoodItems() throws {
        let r = try decode(AddonAPI.MetaResponse.self, #"{"meta":{"id":"tt1","type":"series","videos":[{"id":"a","season":1,"episode":1},{"season":1},{"id":"c","season":"1","episode":"3"}]}}"#)
        XCTAssertEqual(r.meta?.videos?.map(\.id), ["a", "c"])
        XCTAssertEqual(r.meta?.videos?.last?.episode, 3)
    }

    func testStreamsAndSubtitles() throws {
        let s = try decode(AddonAPI.StreamsResponse.self, #"{"streams":[{"url":"https://a/1.mkv","behaviorHints":{"notWebReady":"true","videoSize":"123"}},7,{"url":"https://a/2.mkv","subtitles":[{"url":"https://a/1.srt","id":5},{"lang":"en"}]}]}"#)
        XCTAssertEqual(s.streams?.count, 2)
        XCTAssertEqual(s.streams?.first?.behaviorHints?.notWebReady, true)
        XCTAssertEqual(s.streams?.first?.behaviorHints?.videoSize, 123)
        XCTAssertEqual(s.streams?.last?.subtitles?.map(\.id), ["5"])
        let subs = try decode(AddonAPI.SubtitlesResponse.self, #"{"subtitles":[{"id":1,"url":"https://a/1.srt","lang":"eng"},{"id":2}]}"#)
        XCTAssertEqual(subs.subtitles?.map(\.url), ["https://a/1.srt"])
    }

    func testABadExtraKeepsSearchAndGenres() throws {
        let m = try decode(AddonManifest.self, #"{"id":"x","name":"X","resources":["catalog"],"types":["movie"],"catalogs":[{"type":"movie","id":"top","extra":[{"name":"search","isRequired":"false"},{"options":["no name"]},{"name":"genre","options":["Action","Drama"]}]}]}"#)
        let cat = try XCTUnwrap(m.catalogs.first)
        XCTAssertTrue(cat.supportsSearch)
        XCTAssertEqual(cat.genreOptions, ["Action", "Drama"])
        XCTAssertTrue(cat.requiredExtras.isEmpty)
    }

    func testSavedDownloadsSkipWhatTheyCantRead() throws {
        let json = #"[{"url":"https://dav/a.mkv","fileName":"a.mkv","destination":"file:///tmp/a.mkv"},{"fileName":"no url"},{"url":"https://dav/b.mkv","fileName":"b.mkv","package":"P","expected":10,"state":"someNewState","destination":"file:///tmp/b.mkv"}]"#
        let items = try XCTUnwrap(JSONDecoder().decodeLossy(DownloadItem.self, from: Data(json.utf8)))
        XCTAssertEqual(items.map(\.fileName), ["a.mkv", "b.mkv"])
        XCTAssertEqual(items[0].package, "a.mkv")
        XCTAssertEqual(items[1].state, .paused)
    }

    func testHTMLControlCharacters() {
        XCTAssertEqual("O&#39;Hara".decodingHTMLEntities, "O'Hara")
        XCTAssertEqual("A&#0;B&#65533;C".decodingHTMLEntities, "ABC")
        XCTAssertEqual("Line&#10;two".decodingHTMLEntities, "Line two")
    }

    func testPrivateHostsGetNoIconLookup() {
        for h in ["nas.lan", "media.home.arpa", "192.168.1.20", "box.local", "nas", "pi.tail1234.ts.net", "fe80::1"] {
            XCTAssertTrue(BrandIcon.isPrivate(BrandIcon.domain(for: h)), h)
        }
        for h in ["dav.real-debrid.com", "webdav.torbox.app"] {
            XCTAssertFalse(BrandIcon.isPrivate(BrandIcon.domain(for: h)), h)
        }
    }
}
