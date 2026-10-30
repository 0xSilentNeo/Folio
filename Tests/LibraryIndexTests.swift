import XCTest
@testable import GlassPlayer

/// The WebDAV library index: saved and read back, a broken file rebuilt, and
/// refreshes that list only what changed (additions, removals, renames).
final class LibraryIndexTests: XCTestCase {
    /// An in-memory WebDAV server: folder → its listing, and a count of listings asked for.
    final class FakeServer: @unchecked Sendable {
        private let lock = NSLock()
        private var tree: [String: [DAVItem]] = [:]
        private(set) var asked: [String] = []
        var failing: Set<String> = []
        var refuseLogin = false

        func set(_ folder: URL, _ items: [DAVItem]) { lock.lock(); tree[LibraryIndex.key(folder)] = items; lock.unlock() }
        func resetCount() { lock.lock(); asked = []; lock.unlock() }

        func list(_ url: URL) throws -> [DAVItem] {
            lock.lock(); defer { lock.unlock() }
            let k = LibraryIndex.key(url)
            asked.append(k)
            if refuseLogin { throw WebDAVError.unauthorized }
            if failing.contains(k) { throw WebDAVError.http(503) }
            return tree[k] ?? []
        }
    }

    let root = URL(string: "https://dav.example.invalid/torrents/")!
    func folder(_ name: String, modified: TimeInterval, etag: String? = nil) -> DAVItem {
        var d = DAVItem(url: root.appendingPathComponent(name, isDirectory: true), name: name, isDirectory: true, size: nil,
                        modified: Date(timeIntervalSince1970: modified), contentType: nil)
        d.etag = etag
        return d
    }
    func file(_ folder: String, _ name: String) -> DAVItem {
        DAVItem(url: root.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(name), name: name, isDirectory: false,
                size: 1_000_000, modified: Date(timeIntervalSince1970: 1), contentType: nil)
    }

    /// Server with releases A, B and D, one episode each.
    func makeServer() -> FakeServer {
        let s = FakeServer()
        s.set(root, [folder("A", modified: 100), folder("B", modified: 200), folder("D", modified: 400)])
        for n in ["A", "B", "D"] { s.set(root.appendingPathComponent(n, isDirectory: true), [file(n, "\(n).S01E01.1080p.mkv")]) }
        return s
    }

    func indexer(_ s: FakeServer) -> LibraryIndexer { LibraryIndexer(list: { try s.list($0) }) }
    func empty() -> LibraryIndex { LibraryIndex(account: "test", root: LibraryIndex.key(root)) }
    func names(_ i: LibraryIndex) -> [String] { i.allFiles.map(\.name).sorted() }

    func testFullIndexListsEverything() async {
        let s = makeServer()
        let (i, r) = await indexer(s).refresh(empty(), rootURL: root, full: true)
        XCTAssertEqual(names(i), ["A.S01E01.1080p.mkv", "B.S01E01.1080p.mkv", "D.S01E01.1080p.mkv"])
        XCTAssertEqual(r.listed, 4)
        XCTAssertEqual(i.folders.count, 4)
        XCTAssertEqual(i.lastCheck?.ok, true)
        XCTAssertNotNil(i.refreshed)
    }

    func testRoundTripOnDisk() async throws {
        let (i, _) = await indexer(makeServer()).refresh(empty(), rootURL: root, full: true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("index-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        LibraryIndexStore.write(i, to: url)
        let back = LibraryIndexStore.read(url, account: "test")
        XCTAssertEqual(back.index, i, "the saved index reads back the same")
        XCTAssertNil(back.note)
        XCTAssertNil(LibraryIndexStore.read(url, account: "someone else").index, "another account's index isn't used")
    }

    func testCorruptFileIsRebuiltNotACrash() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("index-\(UUID().uuidString).json")
        try Data("{ not json".utf8).write(to: url)
        let back = LibraryIndexStore.read(url, account: "test")
        XCTAssertNil(back.index)
        XCTAssertTrue(back.note?.contains("unreadable") == true, back.note ?? "no note")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the broken file is removed")
    }

    func testOlderLayoutIsRebuilt() throws {
        var i = empty()
        i.schema = 0
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("index-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode(i).write(to: url)
        XCTAssertNil(LibraryIndexStore.read(url, account: "test").index)
    }

    func testChangesOnlyListsWhatChanged() async {
        let s = makeServer()
        let (first, _) = await indexer(s).refresh(empty(), rootURL: root, full: true)
        // On the server: C added, B removed, A renamed to A2, D unchanged.
        s.set(root, [folder("A2", modified: 100), folder("C", modified: 300), folder("D", modified: 400)])
        s.set(root.appendingPathComponent("A2", isDirectory: true), [file("A2", "A.S01E01.1080p.mkv")])
        s.set(root.appendingPathComponent("C", isDirectory: true), [file("C", "C.S01E01.1080p.mkv")])
        s.resetCount()
        let (second, r) = await indexer(s).refresh(first, rootURL: root, full: false)
        XCTAssertEqual(Set(s.asked), [LibraryIndex.key(root), LibraryIndex.key(root.appendingPathComponent("A2", isDirectory: true)),
                                      LibraryIndex.key(root.appendingPathComponent("C", isDirectory: true))], "D wasn't listed again")
        XCTAssertEqual(r.kept, 1)
        XCTAssertEqual(names(second), ["A.S01E01.1080p.mkv", "C.S01E01.1080p.mkv", "D.S01E01.1080p.mkv"])
        XCTAssertNil(second.folders[LibraryIndex.key(root.appendingPathComponent("B", isDirectory: true))], "B is gone")
        XCTAssertNil(second.folders[LibraryIndex.key(root.appendingPathComponent("A", isDirectory: true))], "A (renamed) is gone")
    }

    func testChangedDateOrEtagListsAgain() async {
        let s = makeServer()
        let (first, _) = await indexer(s).refresh(empty(), rootURL: root, full: true)
        s.set(root, [folder("A", modified: 100), folder("B", modified: 250), folder("D", modified: 400)])
        s.set(root.appendingPathComponent("B", isDirectory: true), [file("B", "B.S01E01.1080p.mkv"), file("B", "B.S01E02.1080p.mkv")])
        s.resetCount()
        let (second, _) = await indexer(s).refresh(first, rootURL: root, full: false)
        XCTAssertEqual(s.asked.count, 2, "the start folder and B")
        XCTAssertTrue(names(second).contains("B.S01E02.1080p.mkv"))
    }

    func testEtagWinsOverDate() async {
        let s = FakeServer()
        s.set(root, [folder("A", modified: 100, etag: "\"1\"")])
        s.set(root.appendingPathComponent("A", isDirectory: true), [file("A", "A.S01E01.mkv")])
        let (first, _) = await indexer(s).refresh(empty(), rootURL: root, full: true)
        s.set(root, [folder("A", modified: 999, etag: "\"1\"")])
        s.resetCount()
        _ = await indexer(s).refresh(first, rootURL: root, full: false)
        XCTAssertEqual(s.asked.count, 1, "same etag: A is kept although its date moved")
    }

    func testOldListingIsListedAgain() async {
        let s = makeServer()
        let (first, _) = await indexer(s).refresh(empty(), rootURL: root, full: true, now: Date(timeIntervalSinceNow: -25 * 3600))
        s.resetCount()
        _ = await indexer(s).refresh(first, rootURL: root, full: false)
        XCTAssertEqual(s.asked.count, 4, "listings older than 24 h are listed again")
    }

    func testFullRefreshListsEverythingAgain() async {
        let s = makeServer()
        let (first, _) = await indexer(s).refresh(empty(), rootURL: root, full: true)
        s.resetCount()
        _ = await indexer(s).refresh(first, rootURL: root, full: true)
        XCTAssertEqual(s.asked.count, 4)
    }

    func testOfflineKeepsTheSavedIndex() async {
        let s = makeServer()
        let (first, _) = await indexer(s).refresh(empty(), rootURL: root, full: true)
        s.failing = [LibraryIndex.key(root)]
        let (second, r) = await indexer(s).refresh(first, rootURL: root, full: false)
        XCTAssertTrue(r.rootFailed)
        XCTAssertEqual(names(second), names(first), "nothing is lost while the server can't be reached")
        XCTAssertEqual(second.lastCheck?.ok, false)
        XCTAssertEqual(second.refreshed, first.refreshed, "a failed check doesn't count as an update")
    }

    func testRefusedLoginIsReported() async {
        let s = makeServer()
        let (first, _) = await indexer(s).refresh(empty(), rootURL: root, full: true)
        s.refuseLogin = true
        let (second, r) = await indexer(s).refresh(first, rootURL: root, full: false)
        XCTAssertTrue(r.unauthorized)
        XCTAssertEqual(second.lastCheck?.unauthorized, true)
    }

    func testAtMostThreeListingsAtOnce() async {
        final class Gauge: @unchecked Sendable {
            let lock = NSLock(); var now = 0; var most = 0
            func enter() { lock.lock(); now += 1; most = max(most, now); lock.unlock() }
            func leave() { lock.lock(); now -= 1; lock.unlock() }
        }
        let s = FakeServer()
        s.set(root, (0..<12).map { folder("F\($0)", modified: Double($0)) })
        let g = Gauge()
        let indexer = LibraryIndexer(list: { url in
            g.enter(); defer { g.leave() }
            try await Task.sleep(nanoseconds: 20_000_000)
            return try s.list(url)
        })
        _ = await indexer.refresh(empty(), rootURL: root, full: true)
        XCTAssertLessThanOrEqual(g.most, 3)
        XCTAssertEqual(s.asked.count, 13)
    }
}
