import XCTest
@testable import Folio

/// Downloads in parts (1.22.1): a big file in byte ranges side by side,
/// joined when all are in.
final class DownloadPartsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("parts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testSplitCoversEveryByteOnce() {
        for (total, n) in [(Int64(200_000_000), 4), (Int64(67_108_864), 8), (Int64(1_000_000_007), 3), (Int64(123_456_789), 1)] {
            let parts = DownloadManager.split(total: total, into: n)
            XCTAssertEqual(parts.first?.start, 0)
            XCTAssertEqual(parts.last?.end, total - 1)
            XCTAssertEqual(parts.reduce(0) { $0 + $1.length }, total)
            for (a, b) in zip(parts, parts.dropFirst()) { XCTAssertEqual(b.start, a.end + 1) }
            XCTAssertLessThanOrEqual(parts.count, n)
        }
        XCTAssertEqual(DownloadManager.split(total: 200_000_000, into: 4).count, 4)
        // No part under 8 MB: 64 MB in 8 parts, not 16.
        XCTAssertEqual(DownloadManager.split(total: 64 * 1_048_576, into: 16).count, 8)
        XCTAssertEqual(DownloadManager.split(total: 10_000_000, into: 4).count, 1)
        XCTAssertTrue(DownloadManager.split(total: 0, into: 4).isEmpty)
    }

    func testContentRangeTotal() {
        XCTAssertEqual(DownloadEngine.totalLength("bytes 0-0/1234567"), 1_234_567)
        XCTAssertEqual(DownloadEngine.totalLength("bytes 0-0/ 42"), 42)
        XCTAssertNil(DownloadEngine.totalLength("bytes 0-0/*"))
        XCTAssertNil(DownloadEngine.totalLength(nil))
    }

    func testKeys() throws {
        let id = UUID()
        XCTAssertEqual(DownloadEngine.key(id, nil), id.uuidString)
        let (a, none) = try XCTUnwrap(DownloadEngine.parse(id.uuidString))
        XCTAssertEqual(a, id)
        XCTAssertNil(none)
        let (b, three) = try XCTUnwrap(DownloadEngine.parse(DownloadEngine.key(id, 3)))
        XCTAssertEqual(b, id)
        XCTAssertEqual(three, 3)
        XCTAssertNil(DownloadEngine.parse("nonsense"))
        XCTAssertNil(DownloadEngine.parse(id.uuidString + "/x"))
    }

    func testAResumedTransferCountsWhatItHad() {
        // Fresh: 30 of 100 received.
        XCTAssertEqual(DownloadEngine.Reading(received: 30, toReceive: 100).got(of: 100), 30)
        // Resumed at 60: it fetches the last 40 and has 10 of them.
        XCTAssertEqual(DownloadEngine.Reading(received: 10, toReceive: 40).got(of: 100), 70)
        XCTAssertEqual(DownloadEngine.Reading(received: 0, toReceive: -1).got(of: 100), 0, "length unknown")
    }

    // MARK: Join

    private func write(_ id: UUID, _ parts: [Data]) throws {
        for (n, d) in parts.enumerated() { try d.write(to: dir.appendingPathComponent("\(id.uuidString).\(n).part")) }
    }

    private func random(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255) }) }

    func testJoinIsTheFileInOrder() throws {
        let id = UUID()
        // Bigger than the 4 MB the join copies at a time.
        let file = random(9_000_123)
        let cuts = [0, 4_500_000, 4_500_001, 8_000_000, file.count]
        let pieces = zip(cuts, cuts.dropFirst()).map { file.subdata(in: $0..<$1) }
        try write(id, pieces)
        let joined = try DownloadEngine.join(id: id, lengths: pieces.map { Int64($0.count) }, in: dir)
        XCTAssertEqual(try Data(contentsOf: joined), file)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(left, [id.uuidString + ".part"], "the parts are gone, the file is there")
    }

    func testAJoinCutShortIsPickedUp() throws {
        let id = UUID()
        let pieces = [random(3_000_000), random(2_500_000), random(1_000_001)]
        try write(id, pieces)
        // As if Folio was closed in the middle of appending the third part:
        // the second is in (and gone), the first has a bit of the third.
        let first = dir.appendingPathComponent("\(id.uuidString).0.part")
        let h = try FileHandle(forWritingTo: first)
        try h.seekToEnd()
        try h.write(contentsOf: pieces[1])
        try h.write(contentsOf: pieces[2].prefix(4000))
        try h.close()
        try FileManager.default.removeItem(at: dir.appendingPathComponent("\(id.uuidString).1.part"))
        let joined = try DownloadEngine.join(id: id, lengths: pieces.map { Int64($0.count) }, in: dir)
        XCTAssertEqual(try Data(contentsOf: joined), pieces[0] + pieces[1] + pieces[2])
    }

    func testAMissingOrShortPartIsAnError() throws {
        let id = UUID()
        try write(id, [random(1000), random(999)])
        XCTAssertThrowsError(try DownloadEngine.join(id: id, lengths: [1000, 1000], in: dir), "a part of the wrong size")
        XCTAssertThrowsError(try DownloadEngine.join(id: UUID(), lengths: [10], in: dir), "no parts at all")
    }
}
