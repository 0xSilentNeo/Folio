import XCTest
@testable import Folio

/// SMB (1.20.3, 2 Nov): smb:// addresses for libsmbclient and mpv, what a
/// host field may hold, the password kept out of saved items, and that
/// history saved before server items still reads. Not tested: a real share
/// (the only libsmbclient call here starts a context and connects nowhere).
final class SMBURLTests: XCTestCase {
    private var server: MediaServer {
        var s = MediaServer(kind: .smb, name: "NAS", address: "nas.local", share: "Media", username: "neo")
        s.id = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        return s
    }

    func testAddresses() {
        XCTAssertEqual(SMBURL.address(host: "nas.local", path: "/"), "smb://nas.local/")
        XCTAssertEqual(SMBURL.address(host: "nas.local", path: "/Media/Films/Dune (2021).mkv"),
                       "smb://nas.local/Media/Films/Dune%20%282021%29.mkv")
        XCTAssertEqual(SMBURL.address(host: "nas", path: "/M/a#b?c@d%e+f.mkv"), "smb://nas/M/a%23b%3Fc%40d%25e%2Bf.mkv")
        XCTAssertEqual(SMBURL.address(host: "nas", path: "/Média/日本.mkv"), "smb://nas/M%C3%A9dia/%E6%97%A5%E6%9C%AC.mkv")
        XCTAssertEqual(SMBURL.address(host: "10.0.0.2:4450", path: "/Media"), "smb://10.0.0.2:4450/Media")
        XCTAssertEqual(SMBURL.address(host: "fe80::1", path: "/Media"), "smb://[fe80::1]/Media")
    }

    func testLoginInTheAddress() {
        XCTAssertEqual(SMBURL.address(host: "nas", path: "/Media/a.mkv", user: "neo", password: "p@ss:w/rd#1"),
                       "smb://neo:p%40ss%3Aw%2Frd%231@nas/Media/a.mkv")
        XCTAssertEqual(SMBURL.address(host: "nas", path: "/Media", user: "WORK\\neo", password: "pw"), "smb://WORK;neo:pw@nas/Media")
        XCTAssertEqual(SMBURL.address(host: "nas", path: "/Media", user: "neo", password: ""), "smb://neo@nas/Media")
        XCTAssertEqual(SMBURL.address(host: "nas", path: "/Media", user: "", password: "x"), "smb://nas/Media", "guest: no login")
        XCTAssertEqual(SMBURL.splitDomain("WORK;neo").domain, "WORK")
        XCTAssertNil(SMBURL.splitDomain("neo").domain)
    }

    func testHostField() {
        XCTAssertEqual(SMBURL.parseHost("nas.local").host, "nas.local")
        XCTAssertNil(SMBURL.parseHost("nas.local").share)
        let unc = SMBURL.parseHost("\\\\NAS\\Media\\Films")
        XCTAssertEqual(unc.host, "NAS")
        XCTAssertEqual(unc.share, "Media")
        let url = SMBURL.parseHost(" smb://neo@nas.local/Media/ ")
        XCTAssertEqual(url.host, "nas.local")
        XCTAssertEqual(url.share, "Media")
        XCTAssertEqual(SMBURL.port("10.0.0.2:4450"), 4450)
        XCTAssertNil(SMBURL.port("nas"))
        XCTAssertNil(SMBURL.port("fe80::1"))

        var s = MediaServer(kind: .smb, address: "\\\\NAS\\Media")
        XCTAssertEqual(s.smbShare, "Media", "a share typed with the host")
        XCTAssertEqual(s.smbStartPath, "/Media")
        s.share = "/Films/"
        XCTAssertEqual(s.smbStartPath, "/Films", "the share field wins")
        s = MediaServer(kind: .smb, address: "nas")
        XCTAssertEqual(s.smbStartPath, "/", "no share: the host's shares")
        XCTAssertNil(MediaServer(kind: .smb, address: "  ").smbHost)
    }

    func testPaths() {
        XCTAssertEqual(SMBURL.parent("/Media/Films"), "/Media")
        XCTAssertEqual(SMBURL.parent("/Media"), "/")
        XCTAssertEqual(SMBPath.join("/", "Media"), "/Media")
        XCTAssertEqual(SMBPath.join("/Media", "a.mkv"), "/Media/a.mkv")
        XCTAssertEqual(ServerPlayback.matchingSubtitles(for: "Film.mkv", in: ["Film.en.srt", "film.srt", "Other.srt", "Film.nfo"]),
                       ["Film.en.srt", "film.srt"])
    }

    func testErrors() {
        XCTAssertEqual(SMBError(errno: EACCES), .wrongLogin)
        XCTAssertEqual(SMBError(errno: ENOENT), .notFound)
        XCTAssertEqual(SMBError(errno: ETIMEDOUT), .timedOut)
        XCTAssertEqual(SMBError(errno: ECONNREFUSED), .unreachable)
        XCTAssertTrue(SMBError.unreachable.isOffline)
    }

    func testPlaysWithThePasswordAndSavesNone() throws {
        let item = ServerPlayback.smbItem(server: server, path: "/Media/Show/Show.S01E02.1080p.mkv", name: "Show.S01E02.1080p.mkv",
                                          cleanTitles: true, subtitles: [(path: "/Media/Show/Show.S01E02.1080p.en.srt", name: "Show.S01E02.1080p.en.srt")])
        XCTAssertEqual(item.url, "smb://nas.local/Media/Show/Show.S01E02.1080p.mkv")
        XCTAssertEqual(item.historyKey, "smb:99999999-8888-7777-6666-555555555555:/Media/Show/Show.S01E02.1080p.mkv")
        XCTAssertEqual(item.title, TitleParser.clean("Show.S01E02.1080p.mkv"))
        XCTAssertEqual(item.subtitle, "Show")
        XCTAssertEqual(item.remote?.parent, "/Media/Show")
        XCTAssertEqual(item.anime?.episode, 2)

        let ready = ServerPlayback.prepared(item, item.remote!, server: server, token: nil, password: "s3cr#t")
        XCTAssertEqual(ready.url, "smb://neo:s3cr%23t@nas.local/Media/Show/Show.S01E02.1080p.mkv")
        XCTAssertEqual(ready.subtitles.first?.url, "smb://neo:s3cr%23t@nas.local/Media/Show/Show.S01E02.1080p.en.srt")

        let saved = String(decoding: try JSONEncoder().encode(HistoryEntry(item: ready, position: 30, duration: 1400, updated: Date())), as: UTF8.self)
        XCTAssertFalse(saved.contains("s3cr"), saved)
        let back = try JSONDecoder().decode(HistoryEntry.self, from: Data(saved.utf8))
        XCTAssertEqual(back.item.url, "smb://neo@nas.local/Media/Show/Show.S01E02.1080p.mkv")
        XCTAssertEqual(back.item.subtitles.first?.url, "smb://neo@nas.local/Media/Show/Show.S01E02.1080p.en.srt")
        XCTAssertEqual(back.id, item.id)
    }

    func testLibsmbclientStarts() async throws {
        try await SMBClient(host: "nas.invalid", username: "", password: "").startContext()
    }

    // MARK: MediaItem coding (MediaItem.swift's hand-written encode)

    /// History written by 1.20.2 (no "remote"): a WebDAV, an addon and a library entry.
    func testOldHistoryStillReads() throws {
        let json = """
        [{"item":{"url":"https://dav.example/Show/Show.S01E01.mkv","title":"Show · S01E01","subtitle":"Show","headers":{},"subtitles":[],
                  "source":{"webdav":{"serverID":"12345678-1234-1234-1234-123456789012"}},"anime":{"title":"Show","episode":1}},
          "position":120.5,"duration":1400,"updated":750000000},
         {"item":{"url":"https://cdn.example/x.mkv","title":"Film","headers":{"User-Agent":"x"},"subtitles":[{"url":"https://s/x.srt","lang":"en"}],
                  "source":{"addon":{"name":"Torrentio"}},"historyKey":"movie|tt1|tt1","addonRef":"movie|tt1|tt1","durationHint":5400},
          "position":10,"duration":5400,"updated":750000100,"watched":true},
         {"item":{"url":"/var/mobile/Documents/Media/clip.mp4","title":"Clip","headers":{},"subtitles":[],"source":{"local":{}}},
          "position":0,"duration":60,"updated":750000200}]
        """
        let entries = try JSONDecoder().decode([HistoryEntry].self, from: Data(json.utf8))
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].item.source, .webdav(serverID: UUID(uuidString: "12345678-1234-1234-1234-123456789012")!))
        XCTAssertEqual(entries[1].id, "movie|tt1|tt1")
        XCTAssertEqual(entries[1].item.source, .addon(name: "Torrentio"))
        XCTAssertEqual(entries[2].item.source, .local)
        XCTAssertNil(entries[0].item.remote)
        // Written again, they read back the same.
        let again = try JSONDecoder().decode([HistoryEntry].self, from: JSONEncoder().encode(entries))
        XCTAssertEqual(again, entries)
    }

    /// A field added to MediaItem but not to its encode() would be lost from
    /// history: every stored property must come out.
    func testEveryFieldIsWritten() throws {
        var m = MediaItem(url: "https://a/b.mkv", title: "T", subtitle: "S", source: .webdav(serverID: UUID()))
        m.artwork = "https://a/art.jpg"
        m.headers = ["Authorization": "Basic x", "User-Agent": "u"]
        m.subtitles = [ExternalSubtitle(url: "https://a/b.srt", lang: "en", title: "b.srt")]
        m.anime = AnimeHint(title: "T", episode: 1, malId: 1, anilistId: 2, kitsuId: 3, anidbId: 4)
        m.bookmark = Data([1, 2, 3])
        m.historyKey = "k"
        m.addonRef = "series|tt1|tt1:1:1"
        m.durationHint = 60
        m.streamPick = StreamPick(addonID: "a", bingeGroup: "g", streamName: "n", resolution: "1080p",
                                  context: PlayContext(name: "T", poster: nil, type: "series", metaId: "tt1", isAnime: false, videoId: "tt1:1:1", videoLabel: nil, episode: 1))
        m.remote = ServerItemRef(kind: .plex, serverID: UUID(), id: "1", part: "/p", parent: "/c")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as? [String: Any])
        let stored = Set(Mirror(reflecting: m).children.compactMap(\.label))
        XCTAssertEqual(Set(object.keys), stored)
        let back = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back.remote, m.remote)
        XCTAssertEqual(back.streamPick, m.streamPick)
        XCTAssertNil(back.headers["Authorization"], "a server item's login headers stay out")
        XCTAssertEqual(back.headers["User-Agent"], "u")
    }

    /// Items that aren't server items are written as before (WebDAV's
    /// Authorization is dropped by HistoryStore, as it was).
    func testOtherItemsAreWrittenAsBefore() throws {
        var m = MediaItem(url: "https://dav.example/a.mkv", title: "A", source: .webdav(serverID: UUID()))
        m.headers["Authorization"] = "Basic x"
        let back = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back, m)
    }

    func testServerListSkipsWhatItCantRead() throws {
        let json = """
        [{"id":"99999999-8888-7777-6666-555555555555","kind":"smb","name":"NAS","address":"nas.local"},
         {"id":"11111111-2222-3333-4444-555555555555","kind":"ftp","name":"Later"},
         {"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","kind":"plex","name":"Plex","address":"10.0.0.2","futureField":[1]}]
        """
        let list = try JSONDecoder().decode(LenientList<MediaServer>.self, from: Data(json.utf8)).items
        XCTAssertEqual(list.map(\.name), ["NAS", "Plex"])
        XCTAssertNil(list[0].share)
        XCTAssertEqual(try JSONDecoder().decode([MediaServer].self, from: JSONEncoder().encode(list)), list)
    }
}
