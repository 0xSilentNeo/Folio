import XCTest
@testable import Folio

/// Automatic downloads (1.22.0): which episodes "Download next episodes"
/// picks from a WebDAV folder (AutoDownload.next), when the network counts
/// as Wi-Fi (NetworkGate), and which downloads "Delete watched downloads"
/// removes (WatchedCleanup).
final class AutoDownloadTests: XCTestCase {
    private let folder = URL(string: "https://dav.example.invalid/shows/Mob.Land.S01/")!

    private func file(_ name: String, in dir: URL? = nil) -> DAVItem {
        let base = dir ?? folder
        return DAVItem(url: base.appendingPathComponent(name), name: name, isDirectory: false, size: 1_000_000, modified: nil, contentType: nil)
    }

    private func names(_ items: [DAVItem]) -> [String] { items.map(\.name) }

    // MARK: Next episodes

    func testTheNextEpisodesInEpisodeOrder() {
        // Listed out of order, with a subtitle and a folder.
        let listing = [
            file("Mob.Land.S01E10.1080p.mkv"), file("Mob.Land.S01E02.1080p.mkv"), file("Mob.Land.S01E01.1080p.mkv"),
            file("Mob.Land.S01E03.1080p.mkv"), file("Mob.Land.S01E02.1080p.en.srt"),
            DAVItem(url: folder.appendingPathComponent("Extras", isDirectory: true), name: "Extras", isDirectory: true, size: nil, modified: nil, contentType: nil),
        ]
        let watched = folder.appendingPathComponent("Mob.Land.S01E01.1080p.mkv")
        XCTAssertEqual(names(AutoDownload.next(after: watched, in: listing, count: 1)), ["Mob.Land.S01E02.1080p.mkv"])
        XCTAssertEqual(names(AutoDownload.next(after: watched, in: listing, count: 3)),
                       ["Mob.Land.S01E02.1080p.mkv", "Mob.Land.S01E03.1080p.mkv", "Mob.Land.S01E10.1080p.mkv"])
    }

    func testNothingAfterTheLastEpisode() {
        let listing = [file("Show.S01E01.mkv"), file("Show.S01E02.mkv")]
        XCTAssertTrue(AutoDownload.next(after: folder.appendingPathComponent("Show.S01E02.mkv"), in: listing, count: 2).isEmpty)
    }

    func testFewerLeftThanAskedFor() {
        let listing = [file("Show.S01E01.mkv"), file("Show.S01E02.mkv"), file("Show.S01E03.mkv")]
        XCTAssertEqual(names(AutoDownload.next(after: folder.appendingPathComponent("Show.S01E02.mkv"), in: listing, count: 3)), ["Show.S01E03.mkv"])
    }

    func testOnlyTheSameShow() {
        // A flat folder with two shows: the other show's next file isn't "next".
        let listing = [file("Show.S01E01.mkv"), file("Another.Show.S01E01.mkv"), file("Another.Show.S01E02.mkv"), file("Show.S01E02.mkv")]
        XCTAssertEqual(names(AutoDownload.next(after: folder.appendingPathComponent("Show.S01E01.mkv"), in: listing, count: 2)), ["Show.S01E02.mkv"])
    }

    func testAShowsNameWrittenTwoWays() {
        let listing = [file("Mob.Land.S01E01.mkv"), file("Mob Land - S01E02.mkv")]
        XCTAssertEqual(names(AutoDownload.next(after: folder.appendingPathComponent("Mob.Land.S01E01.mkv"), in: listing, count: 1)), ["Mob Land - S01E02.mkv"])
    }

    func testNumbersOnlyAnimeAndTheNextSeason() {
        let anime = [file("[Group] Frieren - 12 (1080p).mkv"), file("[Group] Frieren - 9 (1080p).mkv"), file("[Group] Frieren - 10 (1080p).mkv")]
        XCTAssertEqual(names(AutoDownload.next(after: folder.appendingPathComponent("[Group] Frieren - 9 (1080p).mkv"), in: anime, count: 2)),
                       ["[Group] Frieren - 10 (1080p).mkv", "[Group] Frieren - 12 (1080p).mkv"])
        // A folder with two seasons: S01E10 comes before S02E01.
        let seasons = [file("Show.S02E01.mkv"), file("Show.S01E10.mkv"), file("Show.S01E09.mkv")]
        XCTAssertEqual(names(AutoDownload.next(after: folder.appendingPathComponent("Show.S01E09.mkv"), in: seasons, count: 2)),
                       ["Show.S01E10.mkv", "Show.S02E01.mkv"])
    }

    func testAFilmHasNoNextEpisode() {
        let listing = [file("Dune.2021.1080p.mkv"), file("Dune.Part.Two.2024.1080p.mkv")]
        XCTAssertTrue(AutoDownload.next(after: folder.appendingPathComponent("Dune.2021.1080p.mkv"), in: listing, count: 1).isEmpty)
    }

    func testAFileNoLongerInTheFolderOrNoneAskedFor() {
        let listing = [file("Show.S01E02.mkv")]
        XCTAssertTrue(AutoDownload.next(after: folder.appendingPathComponent("Show.S01E01.mkv"), in: listing, count: 1).isEmpty)
        XCTAssertTrue(AutoDownload.next(after: folder.appendingPathComponent("Show.S01E02.mkv"), in: listing + [file("Show.S01E03.mkv")], count: 0).isEmpty)
    }

    func testAPercentEncodedLinkIsFound() {
        // The player's item has the listing's own link; names with spaces are encoded in it.
        let listing = [file("Mob Land S01E01.mkv"), file("Mob Land S01E02.mkv")]
        let watched = URL(string: listing[0].url.absoluteString)!
        XCTAssertTrue(watched.absoluteString.contains("%20"))
        XCTAssertEqual(names(AutoDownload.next(after: watched, in: listing, count: 1)), ["Mob Land S01E02.mkv"])
    }

    func testShowKey() {
        XCTAssertEqual(AutoDownload.showKey("Mob.Land"), AutoDownload.showKey("Mob Land"))
        XCTAssertNotEqual(AutoDownload.showKey("Show"), AutoDownload.showKey("Another Show"))
    }

    // MARK: Wi-Fi only

    func testOnlyUnmeteredWiFi() {
        typealias P = NetworkGate.Path
        XCTAssertTrue(NetworkGate.allows(P(satisfied: true, wifi: true, expensive: false, constrained: false)))
        // A phone's hotspot (iOS marks it expensive), Low Data Mode, no network.
        XCTAssertFalse(NetworkGate.allows(P(satisfied: true, wifi: true, expensive: true, constrained: false)))
        XCTAssertFalse(NetworkGate.allows(P(satisfied: true, wifi: true, expensive: false, constrained: true)))
        XCTAssertFalse(NetworkGate.allows(P(satisfied: false, wifi: true, expensive: false, constrained: false)))
        // Mobile data, even 5G that iOS doesn't call expensive.
        XCTAssertFalse(NetworkGate.allows(P(satisfied: true, wifi: false, expensive: false, constrained: false)))
        XCTAssertFalse(NetworkGate.allows(P(satisfied: true, wifi: false, expensive: true, constrained: false)))
    }

    // MARK: Delete watched downloads

    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let day: TimeInterval = 86_400

    private func entry(_ path: String, position: Double, duration: Double = 1440, ago: TimeInterval, watched: Bool? = nil, source: MediaSource = .local) -> HistoryEntry {
        var item = MediaItem(url: path, title: "Episode", source: source)
        if case .local = source { item.historyKey = path }
        return HistoryEntry(item: item, position: position, duration: duration, updated: now.addingTimeInterval(-ago), watched: watched)
    }

    func testFinishedAndOldEnough() {
        let path = "/var/mobile/Containers/Data/Application/A/Documents/Media/Show/E1.mkv"
        XCTAssertTrue(WatchedCleanup.isDue(entry(path, position: 1400, ago: 2 * day), now: now, delay: day))
        XCTAssertFalse(WatchedCleanup.isDue(entry(path, position: 1400, ago: 2 * day), now: now, delay: 7 * day), "finished 2 days ago, rule says 7")
        XCTAssertTrue(WatchedCleanup.isDue(entry(path, position: 1400, ago: 7 * day), now: now, delay: 7 * day))
        XCTAssertFalse(WatchedCleanup.isDue(entry(path, position: 1400, ago: 3600), now: now, delay: day), "finished an hour ago")
        // Marked watched by hand, never played.
        XCTAssertTrue(WatchedCleanup.isDue(entry(path, position: 0, duration: 0, ago: 2 * day, watched: true), now: now, delay: day))
    }

    func testNeverUnfinishedOrUnplayedOrOff() {
        let path = "/x/Documents/Media/Show/E1.mkv"
        XCTAssertFalse(WatchedCleanup.isDue(entry(path, position: 600, ago: 30 * day), now: now, delay: day), "half watched")
        XCTAssertFalse(WatchedCleanup.isDue(nil, now: now, delay: day), "never played")
        XCTAssertFalse(WatchedCleanup.isDue(entry(path, position: 1400, ago: 30 * day), now: now, delay: 0), "setting off")
    }

    func testEntriesByMediaPathNotByName() {
        // Two shows' "E1.mkv": only the finished one's path is due.
        let a = entry("/old/container/Documents/Media/Show A/E1.mkv", position: 1400, ago: 9 * day)
        let b = entry("/x/Documents/Media/Show B/E1.mkv", position: 100, ago: 9 * day)
        let stream = entry("https://dav.example.invalid/Show%20C/E1.mkv", position: 1400, ago: 9 * day, source: .webdav(serverID: UUID()))
        let map = WatchedCleanup.libraryEntries([a, b, stream])
        XCTAssertEqual(Set(map.keys), ["Show A/E1.mkv", "Show B/E1.mkv"], "a stream isn't a library file")
        XCTAssertTrue(WatchedCleanup.isDue(map["Show A/E1.mkv"], now: now, delay: day))
        XCTAssertFalse(WatchedCleanup.isDue(map["Show B/E1.mkv"], now: now, delay: day))
        XCTAssertFalse(WatchedCleanup.isDue(map["Show C/E1.mkv"], now: now, delay: day))
    }

    func testTheNewerEntryForOneFileCounts() {
        // Finished a week ago, started again since: not due.
        let old = entry("/a/Documents/Media/Show/E1.mkv", position: 1400, ago: 8 * day)
        let again = entry("/b/Documents/Media/Show/E1.mkv", position: 120, ago: 3600)
        let map = WatchedCleanup.libraryEntries([old, again])
        XCTAssertFalse(WatchedCleanup.isDue(map["Show/E1.mkv"], now: now, delay: day))
    }

    func testMediaPath() {
        XCTAssertEqual(MediaPath.relative("/var/mobile/Containers/Data/Application/X/Documents/Media/Show/E1.mkv"), "Show/E1.mkv")
        XCTAssertEqual(MediaPath.relative("file:///x/Documents/Media/My%20Show/E1.mkv"), "My Show/E1.mkv")
        XCTAssertNil(MediaPath.relative("/x/Documents/Inbox/E1.mkv"), "not in the library")
        XCTAssertNil(MediaPath.relative("https://dav.example.invalid/E1.mkv"))
        XCTAssertNil(MediaPath.relative("/x/Documents/Media/"))
    }

    // MARK: Saved downloads

    func testADownloadSavedBeforeStillReads() throws {
        // A 1.21 list has no wifiOnly; a newer one's item reads in either.
        let old = #"[{"url":"https://dav.example.invalid/a.mkv","fileName":"a.mkv","package":"A","expected":10,"state":"done","destination":"file:///x/Documents/Media/A/a.mkv"}]"#
        let items = try XCTUnwrap(JSONDecoder().decodeLossy(DownloadItem.self, from: Data(old.utf8)))
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items[0].wifiOnly)
        var auto = items[0]
        auto.wifiOnly = true
        let again = try JSONDecoder().decode(DownloadItem.self, from: JSONEncoder().encode(auto))
        XCTAssertEqual(again.wifiOnly, true)
    }
}
