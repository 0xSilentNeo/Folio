import XCTest
@testable import Folio

/// The in-app engine's decisions (1.22.3): how a file is split after the
/// first answer, which range a free connection takes over, which connection
/// is started again, and what a resumed download carries on from.
final class ChunkPlanTests: XCTestCase {
    private let mb: Int64 = 1_048_576

    private func coverEveryByteOnce(_ chunks: [DownloadChunk], total: Int64, file: StaticString = #filePath, line: UInt = #line) {
        let sorted = chunks.sorted { $0.start < $1.start }
        XCTAssertEqual(sorted.first?.start, 0, file: file, line: line)
        XCTAssertEqual(sorted.last?.end, total - 1, file: file, line: line)
        for (a, b) in zip(sorted, sorted.dropFirst()) { XCTAssertEqual(b.start, a.end + 1, file: file, line: line) }
    }

    // MARK: Split

    func testTheFileIsSplitAmongTheConnections() {
        for (total, n) in [(Int64(209_715_200), 4), (Int64(209_715_200), 8), (Int64(1_000_000_007), 3), (Int64(123_456_789), 1)] {
            let chunks = ChunkPlan.split(total: total, connections: n)
            coverEveryByteOnce(chunks, total: total)
            XCTAssertEqual(chunks.count, n)
            XCTAssertTrue(chunks.allSatisfy { $0.current == $0.start && !$0.isDone })
        }
        // No range under 4 MB: a 10 MB file in 2, a 3 MB one whole.
        XCTAssertEqual(ChunkPlan.split(total: 10 * mb, connections: 8).count, 2)
        XCTAssertEqual(ChunkPlan.split(total: 3 * mb, connections: 8).count, 1)
        XCTAssertTrue(ChunkPlan.split(total: 0, connections: 4).isEmpty)
    }

    func testWhatTheFirstRequestHasIsKept() {
        // The first (open) request had 6 MB when the length came: those are
        // one finished range, the rest is split, and the first range of the
        // rest starts where that request is.
        let total = 100 * mb
        let chunks = ChunkPlan.split(total: total, connections: 4, from: 6 * mb)
        coverEveryByteOnce(chunks, total: total)
        XCTAssertEqual(chunks.count, 5)
        XCTAssertTrue(chunks[0].isDone)
        XCTAssertEqual(chunks[0].received, 6 * mb)
        XCTAssertEqual(chunks[1].start, 6 * mb)
        XCTAssertEqual(ChunkPlan.received(chunks), 6 * mb)
    }

    // MARK: Taking over

    func testAFreeConnectionTakesHalfAtEqualSpeeds() throws {
        let chunks = [DownloadChunk(start: 0, end: 99 * mb, current: 99 * mb + 1),          // done
                      DownloadChunk(start: 100 * mb, end: 199 * mb - 1, current: 140 * mb)]  // 59 MB left
        let (i, new) = try XCTUnwrap(ChunkPlan.takeOver(chunks, busy: [1: 2_500_000], reference: 2_500_000))
        XCTAssertEqual(i, 1)
        XCTAssertEqual(new.end, chunks[1].end)
        XCTAssertEqual(Double(new.remaining), Double(chunks[1].remaining) / 2, accuracy: 1)
        XCTAssertEqual(new.current, new.start)
    }

    func testTheRangeThatWouldEndLastIsTaken() throws {
        // Range 0 has more left, but range 1's connection is far slower.
        let chunks = [DownloadChunk(start: 0, end: 50 * mb - 1, current: 10 * mb),     // 40 MB at 2.5 MB/s: 16 s
                      DownloadChunk(start: 50 * mb, end: 80 * mb - 1, current: 60 * mb)]  // 20 MB at 0.5 MB/s: 40 s
        let (i, _) = try XCTUnwrap(ChunkPlan.takeOver(chunks, busy: [0: 2_500_000, 1: 500_000], reference: 2_500_000))
        XCTAssertEqual(i, 1)
    }

    func testACrawlingConnectionGivesUpNearlyAll() throws {
        // A stuck connection (125 KB/s) on the last 5 MB, the others at
        // 2.5 MB/s: the free one takes 95% (1.22.3 lab: the last 5 MB took
        // 35 s when nothing under 8 MB was split).
        let chunk = DownloadChunk(start: 150 * mb, end: 155 * mb - 1, current: 150 * mb)
        let (_, new) = try XCTUnwrap(ChunkPlan.takeOver([chunk], busy: [0: 125_000], reference: 2_500_000))
        XCTAssertEqual(Double(new.remaining) / Double(chunk.remaining), 0.95, accuracy: 0.01)
        // Below a megabyte for a crawling one: still worth it.
        let small = DownloadChunk(start: 0, end: Int64(1.5 * Double(mb)), current: 0)
        XCTAssertNotNil(ChunkPlan.takeOver([small], busy: [0: 50_000], reference: 2_500_000))
    }

    func testNothingIsTakenOverWhenTheRestEndsSoon() {
        // 6 MB left at full speed: a new connection wouldn't help.
        let chunk = DownloadChunk(start: 0, end: 6 * mb - 1, current: 0)
        XCTAssertNil(ChunkPlan.takeOver([chunk], busy: [0: 2_500_000], reference: 2_500_000))
        // Nothing downloading, or only finished ranges.
        XCTAssertNil(ChunkPlan.takeOver([chunk], busy: [:], reference: nil))
        let done = DownloadChunk(start: 0, end: 99, current: 100)
        XCTAssertNil(ChunkPlan.takeOver([done], busy: [0: 1000], reference: 1000))
        // A range of unknown length (no ranges from the server) is never split.
        XCTAssertNil(ChunkPlan.takeOver([DownloadChunk(start: 0, end: -1, current: 50 * mb)], busy: [0: 100], reference: 1000))
    }

    func testANewConnectionWithoutASpeedYetSplitsInHalf() throws {
        let chunk = DownloadChunk(start: 0, end: 40 * mb - 1, current: 0)
        let (_, new) = try XCTUnwrap(ChunkPlan.takeOver([chunk], busy: [0: nil], reference: nil))
        XCTAssertEqual(new.start, 20 * mb)
    }

    func testWaitingRangesComeBeforeSplits() {
        let chunks = [DownloadChunk(start: 0, end: 9, current: 10),       // done
                      DownloadChunk(start: 10, end: 19, current: 12),     // downloading
                      DownloadChunk(start: 20, end: 99, current: 30),     // waiting, most left
                      DownloadChunk(start: 100, end: 109, current: 100)]  // waiting
        XCTAssertEqual(ChunkPlan.waiting(chunks, busy: [1]), 2)
        XCTAssertEqual(ChunkPlan.waiting(chunks, busy: [1, 2]), 3)
        XCTAssertNil(ChunkPlan.waiting(chunks, busy: [1, 2, 3]))
    }

    // MARK: Slow connections

    private func reading(_ task: Int, _ speed: Double, age: TimeInterval = 30, left: Int64 = 50 * 1_048_576) -> ChunkPlan.Reading {
        ChunkPlan.Reading(task: task, speed: speed, age: age, remaining: left)
    }

    func testAConnectionFarBelowTheOthersStartsAgain() {
        let readings = [reading(1, 2_500_000), reading(2, 2_400_000), reading(3, 120_000), reading(4, 2_600_000)]
        XCTAssertEqual(ChunkPlan.slow(readings), [3])
        // At 20% of the median it's slow but not stuck: it stays.
        XCTAssertEqual(ChunkPlan.slow([reading(1, 2_500_000), reading(2, 500_000), reading(3, 2_500_000)]), [])
    }

    func testOnlyAConnectionPastItsStartIsJudged() {
        // 8 s old: maybe still in TCP's slow start.
        XCTAssertEqual(ChunkPlan.slow([reading(1, 2_500_000), reading(2, 100_000, age: 8)]), [])
        // New connections (5 s) that took over ranges count in the median.
        XCTAssertEqual(ChunkPlan.slow([reading(1, 2_500_000, age: 5), reading(2, 2_500_000, age: 5), reading(3, 100_000, age: 20)]), [3])
        // Under 4 s they don't.
        XCTAssertEqual(ChunkPlan.slow([reading(1, 2_500_000, age: 2), reading(3, 100_000, age: 20)]), [])
    }

    func testALoneStuckConnectionIsJudgedByTheFinishedOnes() {
        XCTAssertEqual(ChunkPlan.slow([reading(7, 120_000, left: 5 * 1_048_576)], finished: [2_500_000, 2_450_000]), [7])
        XCTAssertEqual(ChunkPlan.slow([reading(7, 120_000)]), [], "nothing to compare with")
    }

    func testNoRestartsOnASlowLinkOrForTheLastBytes() {
        // Everything is slow (the median under 64 KB/s): the link, not a connection.
        XCTAssertEqual(ChunkPlan.slow([reading(1, 50_000), reading(2, 2_000), reading(3, 60_000)]), [])
        // Under a megabyte left: not worth a new connection.
        XCTAssertEqual(ChunkPlan.slow([reading(1, 2_500_000), reading(2, 2_500_000), reading(3, 10_000, left: 500_000)]), [])
    }

    func testTheReferenceSpeedIsTheMedian() {
        XCTAssertNil(ChunkPlan.reference(running: [], finished: []))
        XCTAssertEqual(ChunkPlan.reference(running: [100, 3000], finished: [2000]), 2000)
        XCTAssertEqual(ChunkPlan.reference(running: [0], finished: [500]), 500, "a stalled one isn't a speed")
    }

    // MARK: Content-Range

    func testContentRange() throws {
        let r = try XCTUnwrap(ChunkPlan.contentRange("bytes 100-199/12345"))
        XCTAssertEqual(r.start, 100)
        XCTAssertEqual(r.end, 199)
        XCTAssertEqual(r.total, 12345)
        let star = try XCTUnwrap(ChunkPlan.contentRange("bytes 0-0/*"))
        XCTAssertNil(star.total)
        XCTAssertEqual(ChunkPlan.contentRange("Bytes 0-1048575/209715200")?.total, 209_715_200)
        XCTAssertEqual(ChunkPlan.contentRange(" bytes  5 - 9 / 10 ")?.start, 5)
        XCTAssertNil(ChunkPlan.contentRange(nil))
        XCTAssertNil(ChunkPlan.contentRange("bytes */12345"), "a 416's: no range")
        XCTAssertNil(ChunkPlan.contentRange("bytes 9-5/10"), "backwards")
        XCTAssertNil(ChunkPlan.contentRange("bytes 0-10/10"), "past the end")
        XCTAssertNil(ChunkPlan.contentRange("items 0-1/2"))
        XCTAssertNil(ChunkPlan.contentRange("bytes 0-1"))
    }

    func testAWebPageIsNotTheFile() {
        XCTAssertTrue(ChunkPlan.isPage(contentType: "text/html; charset=utf-8", fileName: "Show.S01E01.mkv"))
        XCTAssertFalse(ChunkPlan.isPage(contentType: "video/x-matroska", fileName: "Show.S01E01.mkv"))
        XCTAssertFalse(ChunkPlan.isPage(contentType: "application/octet-stream", fileName: "Show.S01E01.mkv"))
        XCTAssertFalse(ChunkPlan.isPage(contentType: nil, fileName: "Show.S01E01.mkv"))
        XCTAssertFalse(ChunkPlan.isPage(contentType: "text/html", fileName: "index.html"))
    }

    // MARK: Resume state

    func testSavedRangesCarryOnOnlyWhenTheyFitTheFile() throws {
        let total = 100 * mb
        var chunks = ChunkPlan.split(total: total, connections: 4)
        chunks[0].current += 3 * mb
        chunks[2].current = chunks[2].end + 1
        // Out of order on disk is fine: they're sorted.
        let saved = [chunks[3], chunks[1], chunks[0], chunks[2]]
        let resumed = try XCTUnwrap(ChunkPlan.resumable(saved, total: total, fileExists: true))
        XCTAssertEqual(resumed, chunks)
        XCTAssertEqual(ChunkPlan.received(resumed), 3 * mb + chunks[2].length)

        XCTAssertNil(ChunkPlan.resumable(chunks, total: total, fileExists: false), "the file is gone")
        XCTAssertNil(ChunkPlan.resumable(chunks, total: total + 1, fileExists: true), "another length")
        XCTAssertNil(ChunkPlan.resumable(Array(chunks.dropLast()), total: total, fileExists: true), "a gap at the end")
        var overlap = chunks
        overlap[1].start -= 1
        XCTAssertNil(ChunkPlan.resumable(overlap, total: total, fileExists: true), "an overlap")
        var ahead = chunks
        ahead[1].current = ahead[1].end + 2
        XCTAssertNil(ChunkPlan.resumable(ahead, total: total, fileExists: true), "past its range")
        XCTAssertNil(ChunkPlan.resumable(nil, total: total, fileExists: true))
        XCTAssertNil(ChunkPlan.resumable([], total: total, fileExists: true))
        // One open request (no length known) carries on where it was.
        let open = [DownloadChunk(start: 0, end: -1, current: 7 * mb)]
        XCTAssertEqual(ChunkPlan.resumable(open, total: nil, fileExists: true), open)
    }

    func testAnItemKeepsItsRangesAcrossALaunch() throws {
        var item = DownloadItem(url: URL(string: "https://dav.example.invalid/E1.mkv")!, fileName: "E1.mkv", package: "P",
                                expected: 100 * mb, destination: URL(fileURLWithPath: "/x/Documents/Media/P/E1.mkv"))
        XCTAssertFalse(item.usesSession)
        item.chunks = ChunkPlan.split(total: 100 * mb, connections: 4)
        item.chunks?[1].current += 12345
        item.ranges = true
        let back = try JSONDecoder().decode(DownloadItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(back.chunks, item.chunks)
        XCTAssertEqual(back.ranges, true)
        XCTAssertFalse(back.usesSession, "a download in Folio")
        // One begun in iOS's background session (1.22.2) finishes there.
        item.resumeFile = "x.resume"
        XCTAssertTrue(item.usesSession)
        item.resumeFile = nil
        item.parts = DownloadManager.split(total: 100 * mb, into: 4)
        XCTAssertTrue(item.usesSession)
        // A list saved by 1.22.2 (no ranges in it) reads as before.
        let old = #"{"url":"https://dav.example.invalid/E2.mkv","fileName":"E2.mkv","destinationPath":"Media/P/E2.mkv","state":"paused"}"#
        let read = try JSONDecoder().decode(DownloadItem.self, from: Data(old.utf8))
        XCTAssertNil(read.chunks)
        XCTAssertNil(read.ranges)
    }
}

private extension DownloadChunk {
    var length: Int64 { end - start + 1 }
}
