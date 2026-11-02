import XCTest
@testable import Folio

/// MediaItem's hand-written encoder (1.20.3): it leaves a server item's login
/// out of history, and must still write every other field.
final class MediaItemCodingTests: XCTestCase {
    private func roundTrip(_ m: MediaItem) throws -> MediaItem {
        try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(m))
    }

    func testEveryFieldIsWritten() throws {
        var m = MediaItem(url: "https://dav.example.com/Show/E01.mkv", title: "Show", subtitle: "E01", source: .webdav(serverID: UUID()))
        m.artwork = "https://img.example.com/a.jpg"
        m.headers = ["Referer": "https://example.com"]
        m.subtitles = [ExternalSubtitle(url: "https://dav.example.com/Show/E01.en.srt", lang: "en", title: "English")]
        m.anime = AnimeHint(title: "Show", episode: 1)
        m.bookmark = Data([1, 2, 3])
        m.historyKey = "key"
        m.addonRef = "series|tt1|tt1:1:1"
        m.durationHint = 1420
        m.remote = ServerItemRef(kind: .jellyfin, serverID: UUID(), id: "abc", part: nil, parent: "season")
        let back = try roundTrip(m)
        XCTAssertEqual(back.url, m.url)
        XCTAssertEqual(back.title, m.title)
        XCTAssertEqual(back.subtitle, m.subtitle)
        XCTAssertEqual(back.artwork, m.artwork)
        XCTAssertEqual(back.headers, m.headers)
        XCTAssertEqual(back.subtitles, m.subtitles)
        XCTAssertEqual(back.source, m.source)
        XCTAssertEqual(back.anime, m.anime)
        XCTAssertEqual(back.bookmark, m.bookmark)
        XCTAssertEqual(back.historyKey, m.historyKey)
        XCTAssertEqual(back.addonRef, m.addonRef)
        XCTAssertEqual(back.durationHint, m.durationHint)
        XCTAssertEqual(back.remote, m.remote)
    }

    func testAServerItemsLoginIsLeftOut() throws {
        var m = MediaItem(url: "smb://me:secret@nas.local/Media/Film.mkv", title: "Film", source: .url)
        m.headers = ["X-Plex-Token": "tok", "X-Emby-Token": "tok2", "User-Agent": "Folio"]
        m.subtitles = [ExternalSubtitle(url: "smb://me:secret@nas.local/Media/Film.en.srt", lang: "en", title: nil)]
        m.remote = ServerItemRef(kind: .smb, serverID: UUID(), id: "/Media/Film.mkv", part: nil, parent: "/Media")
        let json = String(decoding: try JSONEncoder().encode(m), as: UTF8.self)
        XCTAssertFalse(json.contains("secret"), json)
        XCTAssertFalse(json.contains("tok"), json)
        let back = try roundTrip(m)
        XCTAssertEqual(back.headers, ["User-Agent": "Folio"])
        XCTAssertFalse(back.url.contains("secret"))
    }

    func testOtherItemsKeepTheirHeaders() throws {
        var m = MediaItem(url: "https://debrid.example.com/x.mkv", title: "X", source: .url)
        m.headers = ["Authorization": "Bearer addon"]
        XCTAssertEqual(try roundTrip(m).headers, m.headers)
    }
}
