import XCTest
@testable import Folio

/// The Continue Watching widget's data (1.20.3): the snapshot the app writes
/// into the App Group's container, the folio://continue link back, and the
/// shows Siri offers.
final class WidgetSnapshotTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("WidgetSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Link

    func testTheLinkCarriesAnyHistoryID() {
        let ids = [
            "/var/mobile/Containers/Data/Application/0A1B/Documents/Media/MobLand S01E03 [1080p].mkv",
            "https://dav.example.com/Shows/Ep%2001.mkv?token=a+b&sig=c=d#t=10",
            "addon:tt31510819:1:3",
            "Ünïcødé 名前 100%.mp4",
        ]
        for id in ids {
            let url = ContinueLink.url(id: id)
            XCTAssertEqual(url.scheme, "folio")
            XCTAssertEqual(url.host, "continue")
            XCTAssertEqual(ContinueLink.id(from: url), id, url.absoluteString)
        }
    }

    func testOtherLinksAreNotContinueLinks() {
        XCTAssertNil(ContinueLink.id(from: URL(string: "folio://play?url=https%3A%2F%2Fexample.com%2Fa.mkv")!))
        XCTAssertNil(ContinueLink.id(from: URL(string: "folio://continue")!))
        XCTAssertNil(ContinueLink.id(from: URL(string: "folio://continue?id=")!))
        XCTAssertNil(ContinueLink.id(from: URL(string: "https://continue?id=abc")!))
    }

    // MARK: Snapshot file

    func testTheSnapshotReadsBackAsWritten() throws {
        let snapshot = ContinueSnapshot(items: [
            .init(id: "a", title: "MobLand", line: "S1 · E3 · Funeral Plans", progress: 0.25, remaining: 1500, picture: "a-1.jpg"),
            .init(id: "b", title: "A film", line: nil, progress: 0.5, remaining: 3000),
        ])
        try snapshot.write(to: dir)
        XCTAssertEqual(ContinueSnapshot.read(from: dir), snapshot)
    }

    /// No group (a sideloading tool didn't grant it): nothing to read, and
    /// the widget shows Open Folio.
    func testWithoutTheGroupThereIsNoSnapshot() {
        XCTAssertNil(ContinueSnapshot.directory(in: nil, create: true))
        XCTAssertNil(ContinueSnapshot.read(from: nil))
        XCTAssertNil(ContinueSnapshot.read(from: dir))          // the group, but nothing written yet
    }

    func testTheWidgetFolderIsMadeInTheContainer() throws {
        let made = try XCTUnwrap(ContinueSnapshot.directory(in: dir, create: true))
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: made.path, isDirectory: &isDir) && isDir.boolValue)
        XCTAssertEqual(made.lastPathComponent, "Widget")
    }

    /// A snapshot from a later version with fields this one doesn't know
    /// still reads.
    func testUnknownFieldsAreIgnored() throws {
        let json = #"{"items":[{"id":"a","title":"T","progress":0.5,"remaining":60,"poster":"x"}],"version":2}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("continue.json"))
        XCTAssertEqual(ContinueSnapshot.read(from: dir)?.items.first?.title, "T")
    }

    func testTimeLeftIsInMinutes() {
        func left(_ s: Double) -> String { ContinueSnapshot.Item(id: "", title: "", progress: 0, remaining: s).remainingText }
        XCTAssertEqual(left(0), "Almost done")
        XCTAssertEqual(left(30), "1 min left")
        XCTAssertEqual(left(840), "14 min left")
        XCTAssertEqual(left(3600), "1 h left")
        XCTAssertEqual(left(3900), "1 h 5 min left")
    }

    @MainActor
    func testPicturesNoEntryUsesAreRemoved() throws {
        for f in ["a-1.jpg", "b-2.jpg", "continue.json"] { try Data([1]).write(to: dir.appendingPathComponent(f)) }
        ContinueSnapshotWriter.sweep(dir, keeping: ["a-1.jpg"])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), ["a-1.jpg", "continue.json"])
    }

    // MARK: Rows

    @MainActor
    private func libraryEntry(_ name: String, position: Double = 600, duration: Double = 1800) -> HistoryEntry {
        HistoryEntry(item: HistoryStore.libraryItem("/lab/Documents/Media/" + name), position: position, duration: duration, updated: Date())
    }

    @MainActor
    private func addonEntry() -> HistoryEntry {
        var item = MediaItem(url: "https://debrid.example.com/x.mkv", title: "Daemons of the Shadow Realm",
                             subtitle: "S1 · E24 — Higashi Village and Nishino Village", source: .url)
        item.historyKey = "addon:tt31510819:1:24"
        item.addonRef = "series|tt31510819|tt31510819:1:24"
        return HistoryEntry(item: item, position: 300, duration: 1440, updated: Date())
    }

    /// The widget's row says what Home's card says.
    @MainActor
    func testARowIsHomesCard() {
        let e = libraryEntry("MobLand S01E03.mkv")
        let meta = MediaMeta(id: "tt31510819", type: "series", name: "MobLand", episodeTitle: "Funeral Plans", episodeSeason: 1, episodeNumber: 3)
        let row = ContinueSnapshotWriter.item(for: e, meta: meta)
        XCTAssertEqual(row.id, e.id)
        XCTAssertEqual(row.title, "MobLand")
        XCTAssertEqual(row.line, "S1 · E3 · Funeral Plans")
        XCTAssertEqual(row.line, HeroCard.line(e.item, meta: meta))
        XCTAssertEqual(row.progress, 1.0 / 3, accuracy: 0.001)
        XCTAssertEqual(row.remaining, 1200)
        XCTAssertNil(row.picture)

        // No metadata (off, or not looked up yet): the file's own title and numbers.
        let bare = ContinueSnapshotWriter.item(for: e, meta: nil)
        XCTAssertEqual(bare.title, e.item.displayTitle)
        XCTAssertEqual(bare.line.map { $0.hasPrefix("S1 · E3") }, true)
    }

    @MainActor
    func testAnAddonRowKeepsItsEpisodeLabel() {
        let row = ContinueSnapshotWriter.item(for: addonEntry(), meta: nil)
        XCTAssertEqual(row.title, "Daemons of the Shadow Realm")
        XCTAssertEqual(row.line, "S1 · E24 · Higashi Village and Nishino Village")
        XCTAssertEqual(ContinueLink.id(from: ContinueLink.url(id: row.id)), "addon:tt31510819:1:24")
    }

    @MainActor
    func testAFilmsSynopsisIsCut() {
        let e = libraryEntry("Some Film 2024.mkv")
        let meta = MediaMeta(id: "tt1", type: "movie", name: "Some Film", description: String(repeating: "word ", count: 100))
        XCTAssertEqual(ContinueSnapshotWriter.item(for: e, meta: meta).line?.count, 200)
    }

    // MARK: Shows (Siri, Shortcuts)

    @MainActor
    func testAShowIsNamedAfterTheShowNotTheEpisode() {
        XCTAssertEqual(ShowCatalog.name(of: libraryEntry("MobLand S01E03.mkv")), "MobLand")
        XCTAssertEqual(ShowCatalog.name(of: addonEntry()), "Daemons of the Shadow Realm")
    }

    /// A library episode's Continue Watching card and its library series
    /// are one show (one entry in Siri's list, not two).
    @MainActor
    func testAContinueWatchingShowIsItsLibrarySeries() {
        let file = URL(fileURLWithPath: "/lab/Documents/Media/MobLand S01E03.mkv")
        XCTAssertEqual(HistoryStore.showKey(libraryEntry(file.lastPathComponent)), LibraryOrganizer.titleKey(file))
    }
}
