import XCTest
@testable import GlassPlayer

/// Discover's search history store: each test has its own file in a
/// temporary folder.
final class SearchHistoryStoreTests: XCTestCase {
    private var dir: URL!
    private var file: URL { dir.appendingPathComponent("search-history.json") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("search-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store(limit: Int = 50) -> SearchHistoryStore { SearchHistoryStore(fileURL: file, limit: limit) }
    private func t(_ s: Double) -> Date { Date(timeIntervalSinceReferenceDate: 800_000_000 + s) }

    func testDuplicatesIgnoreCaseAndSpaces() async {
        let s = store()
        await s.add("Dune", at: t(1))
        await s.add("  dune  ", at: t(2))
        await s.add("DUNE   part two", at: t(3))
        let list = await s.all()
        XCTAssertEqual(list.map(\.query), ["DUNE part two", "dune"])
    }

    func testReusingMovesToTop() async {
        let s = store()
        await s.add("alien", at: t(1))
        await s.add("blade runner", at: t(2))
        await s.add("casablanca", at: t(3))
        await s.add("Alien", at: t(4))
        let list = await s.all()
        XCTAssertEqual(list.map(\.query), ["Alien", "casablanca", "blade runner"])
        XCTAssertEqual(list.first?.date, t(4))
    }

    func testCapDropsOldest() async {
        let s = store(limit: 3)
        for (i, q) in ["one", "two", "three", "four", "five"].enumerated() { await s.add(q, at: t(Double(i))) }
        let list = await s.all()
        XCTAssertEqual(list.map(\.query), ["five", "four", "three"])
    }

    func testBlankIsIgnored() async {
        let s = store()
        await s.add("   ", at: t(1))
        await s.add("\n\t", at: t(2))
        let list = await s.all()
        XCTAssertTrue(list.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testRoundTrip() async throws {
        let a = store()
        await a.add("the bear", at: t(1))
        await a.add("severance", at: t(2))
        await a.remove("THE BEAR")
        await a.add("andor", at: t(3))
        let written = await a.all()

        let b = store()                            // a fresh store reads the file
        let read = await b.all()
        XCTAssertEqual(read, written)
        XCTAssertEqual(read.map(\.query), ["andor", "severance"])

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        XCTAssertEqual(json?["version"] as? Int, SearchHistoryStore.schemaVersion)
        XCTAssertEqual((json?["entries"] as? [[String: Any]])?.count, 2)
    }

    func testClear() async {
        let s = store()
        await s.add("one", at: t(1))
        await s.clear()
        let list = await store().all()
        XCTAssertTrue(list.isEmpty)
    }

    func testCorruptFileStartsEmptyAndIsSetAside() async throws {
        try Data("{ not json".utf8).write(to: file)
        let s = store()
        let list = await s.all()
        XCTAssertTrue(list.isEmpty)
        let aside = dir.appendingPathComponent("search-history.corrupt.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.path))
        await s.add("works again", at: t(1))
        let reread = await store().all()
        XCTAssertEqual(reread.map(\.query), ["works again"])
    }

    func testNewerFormatIsNotRead() async throws {
        try Data(#"{"version": 99, "entries": [], "somethingNew": true}"#.utf8).write(to: file)
        let list = await store().all()
        XCTAssertTrue(list.isEmpty)
    }

    func testDuplicatesInTheFileAreMerged() async throws {
        let entries = [["query": "dune", "date": 100.0], ["query": "Dune", "date": 200.0], ["query": "alien", "date": 150.0]]
        try JSONSerialization.data(withJSONObject: ["version": 1, "entries": entries]).write(to: file)
        let list = await store().all()
        XCTAssertEqual(list.map(\.query), ["Dune", "alien"])
    }

    func testManyWritersAtOnce() async {
        let s = store()
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<40 { g.addTask { await s.add("title \(i % 20)", at: Date()) } }
        }
        let list = await s.all()
        XCTAssertEqual(list.count, 20)
        let reread = await store().all()
        XCTAssertEqual(Set(reread.map(\.id)), Set(list.map(\.id)))
    }
}
