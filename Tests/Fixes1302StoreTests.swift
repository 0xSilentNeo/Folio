import XCTest
@testable import Folio

/// 1.30.2: the review's fixes in the stores, WebDAV and downloads.
final class Fixes1302StoreTests: XCTestCase {
    // MARK: WebDAV: where a listing's addresses may point

    private let base = URL(string: "https://dav.example.com/dav/")!

    func testARelativeHrefIsOnTheServer() {
        XCTAssertEqual(PropfindParser.resolve("/dav/Films/A%20b.mkv", base: base)?.absoluteString, "https://dav.example.com/dav/Films/A%20b.mkv")
        XCTAssertEqual(PropfindParser.resolve("/dav/Films/A b.mkv", base: base)?.absoluteString, "https://dav.example.com/dav/Films/A%20b.mkv",
                       "raw characters are encoded, as before")
    }

    func testAFullHrefOnTheServerStaysAsItIs() {
        let href = "https://dav.example.com/dav/Films/A%20b.mkv"
        XCTAssertEqual(PropfindParser.resolve(href, base: base)?.absoluteString, href)
        let nas = URL(string: "http://nas.example.org:8080/dav/")!
        XCTAssertEqual(PropfindParser.resolve("http://nas.example.org:8080/dav/a.mkv", base: nas)?.absoluteString, "http://nas.example.org:8080/dav/a.mkv")
    }

    func testAnotherHostKeepsOnlyItsPath() {
        let other = PropfindParser.resolve("https://files.example.net/dav/Films/a.mkv?t=1", base: base)
        XCTAssertEqual(other?.absoluteString, "https://dav.example.com/dav/Films/a.mkv?t=1", "the login never goes to a host the listing names")
        let noScheme = PropfindParser.resolve("//files.example.net/dav/a.mkv", base: base)
        XCTAssertEqual(noScheme?.host, "dav.example.com")
        XCTAssertEqual(noScheme?.path, "/dav/a.mkv")
        let nas = URL(string: "http://nas.example.org:8080/dav/")!
        XCTAssertEqual(PropfindParser.resolve("http://nas.example.org:9000/dav/a.mkv", base: nas)?.absoluteString, "http://nas.example.org:8080/dav/a.mkv")
    }

    func testHTTPSIsNeverLeftForHTTP() {
        XCTAssertEqual(PropfindParser.resolve("http://dav.example.com/dav/a.mkv", base: base)?.absoluteString, "https://dav.example.com/dav/a.mkv")
        // The other way is the server's own choice.
        let plain = URL(string: "http://dav.example.com/dav/")!
        XCTAssertEqual(PropfindParser.resolve("https://dav.example.com/dav/a.mkv", base: plain)?.absoluteString, "https://dav.example.com/dav/a.mkv")
    }

    func testUnderTheBasePathIsByFolder() {
        XCTAssertTrue(WebDAVClient.isUnder("/dav/Films", "/dav"))
        XCTAssertTrue(WebDAVClient.isUnder("/dav", "/dav/"))
        XCTAssertFalse(WebDAVClient.isUnder("/davfiles/Films", "/dav"), "a name that only begins like the base")
        XCTAssertFalse(WebDAVClient.isUnder("/", "/dav"))

        let client = WebDAVClient(server: WebDAVServer(name: "Lab", baseURL: "https://dav.example.com/dav", username: ""))
        XCTAssertEqual(client.url(forPath: "/davfiles")?.path, "/dav/davfiles")
        XCTAssertEqual(client.url(forPath: "/dav/Films")?.path, "/dav/Films")
    }

    func testAPropstatThatWasRefusedGivesNothing() {
        let xml = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:">
        <d:response><d:href>/dav/Films/a.mkv</d:href>
        <d:propstat><d:prop><d:getcontentlength>123</d:getcontentlength><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
        <d:propstat><d:prop><d:displayname>Not this</d:displayname><d:getetag>x</d:getetag></d:prop><d:status>HTTP/1.1 403 Forbidden</d:status></d:propstat>
        </d:response>
        <d:response><d:href>/dav/Films/Season/</d:href>
        <d:propstat><d:prop><d:displayname>Season</d:displayname><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
        <d:propstat><d:prop><d:getcontentlength/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>
        </d:response>
        </d:multistatus>
        """
        let parser = PropfindParser(base: base)
        XCTAssertTrue(parser.parse(Data(xml.utf8)))
        XCTAssertEqual(parser.items.count, 2)
        XCTAssertEqual(parser.items.first?.name, "a.mkv", "the status comes after the values it speaks for")
        XCTAssertEqual(parser.items.first?.size, 123)
        XCTAssertNil(parser.items.first?.etag)
        XCTAssertEqual(parser.items.first?.isDirectory, false)
        XCTAssertEqual(parser.items.last?.name, "Season")
        XCTAssertEqual(parser.items.last?.isDirectory, true)
    }

    // MARK: The share inbox

    func testOnlyAFileInItsOwnInboxFolderIsTaken() {
        let inbox = URL(fileURLWithPath: "/group/Share/Inbox", isDirectory: true)
        XCTAssertTrue(SharedInbox.isInside(inbox.appendingPathComponent("ABC/Film.mkv"), inbox: inbox))
        XCTAssertFalse(SharedInbox.isInside(inbox.appendingPathComponent("Film.mkv"), inbox: inbox), "its folder would be the inbox itself")
        XCTAssertFalse(SharedInbox.isInside(URL(fileURLWithPath: "/group/Library/Preferences/x.plist"), inbox: inbox))
        XCTAssertFalse(SharedInbox.isInside(URL(fileURLWithPath: "/group/Share/Inbox/ABC/../../../Library/x.plist"), inbox: inbox))
        XCTAssertFalse(SharedInbox.isInside(URL(fileURLWithPath: "/group/Share/Inboxes/ABC/Film.mkv"), inbox: inbox))
    }

    // MARK: History

    private func entry(_ position: Double, of duration: Double, watched: Bool? = nil) -> HistoryEntry {
        HistoryEntry(item: MediaItem(url: "file:///lab/Media/Show S01E01.mkv", title: "Show", source: .url),
                     position: position, duration: duration, updated: Date(), watched: watched)
    }

    func testAWatchedMarkOutlastsPlayingItAgain() {
        let again = HistoryStore.carryingWatched(entry(5, of: 1400), from: entry(1400, of: 1400, watched: true))
        XCTAssertEqual(again.watched, true)
        XCTAssertTrue(again.isFinished)
        XCTAssertEqual(again.position, 5, "the new place is kept under the mark")
        // Well into it again: being rewatched, its place decides and it can be resumed.
        XCTAssertNil(HistoryStore.carryingWatched(entry(400, of: 1400), from: entry(1400, of: 1400, watched: true)).watched)
        // Not marked by hand: its place decides, as before.
        XCTAssertNil(HistoryStore.carryingWatched(entry(5, of: 1400), from: entry(1400, of: 1400)).watched)
        XCTAssertNil(HistoryStore.carryingWatched(entry(5, of: 1400), from: entry(300, of: 1400)).watched)
        // Played to the end again: finished by its place, no mark needed.
        XCTAssertTrue(HistoryStore.carryingWatched(entry(1390, of: 1400), from: entry(0, of: 0, watched: true)).isFinished)
    }


    // MARK: Downloads

    func testAFullDiskIsNotTriedAgain() {
        XCTAssertTrue(ChunkPlan.isOutOfSpace(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)))
        XCTAssertTrue(ChunkPlan.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
        let under = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotWriteToFile,
                            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        XCTAssertTrue(ChunkPlan.isOutOfSpace(under), "URLSession's error with the reason under it")
        XCTAssertFalse(ChunkPlan.isOutOfSpace(URLError(.networkConnectionLost)))
        XCTAssertTrue(DownloadManager.isPermanent(ChunkPlan.noSpace))
        XCTAssertFalse(DownloadManager.isPermanent("Couldn't write the download: The operation couldn't be completed."))
    }

    // MARK: Pictures and icons

    func testAPosterIsDecodedForItsTile() {
        XCTAssertEqual(PosterImage.maxPixel(width: nil, aspect: 2.0 / 3.0, scale: 3), 700, "no width known: as before")
        XCTAssertEqual(PosterImage.maxPixel(width: 108, aspect: 2.0 / 3.0, scale: 3), 540)      // 162 pt tall
        XCTAssertEqual(PosterImage.maxPixel(width: 118, aspect: 2.0 / 3.0, scale: 3), 540)
        XCTAssertEqual(PosterImage.maxPixel(width: 108, aspect: 2.0 / 3.0, scale: 2), 360)
        XCTAssertEqual(PosterImage.maxPixel(width: 210, aspect: 16.0 / 9.0, scale: 3), 700)
        XCTAssertEqual(PosterImage.maxPixel(width: 400, aspect: 2.0 / 3.0, scale: 3), 700, "never over what it was")
    }

    func testOnlyTheListedServicesAreLookedUpElsewhere() {
        XCTAssertTrue(BrandIcon.isPreset(BrandIcon.domain(for: "dav.real-debrid.com")))
        XCTAssertTrue(BrandIcon.isPreset(BrandIcon.domain(for: "webdav.torbox.app")))
        XCTAssertFalse(BrandIcon.isPreset(BrandIcon.domain(for: "nas.myfamily.example.org")))
    }
}
