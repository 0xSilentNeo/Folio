import XCTest
@testable import Folio

/// The in-app engine end to end (1.22.3), against a stand-in server in the
/// test process (a URLProtocol) that answers byte ranges, or not, and can be
/// slow on one connection or drop one: the file must come out byte for byte.
@MainActor
final class ChunkedDownloadTests: XCTestCase {
    private var dir: URL!
    private let mb = 1_048_576

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("chunked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ChunkedDownload.protocolClasses = [RangeStub.self]
    }

    override func tearDown() {
        ChunkedDownload.protocolClasses = []
        RangeStub.reset()
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func random(_ count: Int) -> Data {
        var d = Data(count: count)
        d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
        return d
    }

    /// Runs an engine until `until` says so (or the time is up); returns its events.
    private func run(_ engine: ChunkedDownload, events: EventLog, timeout: TimeInterval = 20, until: @escaping (ChunkedDownload.Event) -> Bool) {
        let done = expectation(description: "event")
        events.waiter = { e in if until(e) { done.fulfill(); return true }; return false }
        engine.start()
        wait(for: [done], timeout: timeout)
    }

    private func engine(_ file: URL, chunks: [DownloadChunk] = [], total: Int64? = nil, ranges: Bool? = nil,
                        connections: Int = 4, events: EventLog) -> ChunkedDownload {
        ChunkedDownload(id: UUID(), request: DownloadEngine.Request(url: RangeStub.url, headers: ["Authorization": "Basic eA=="],
                                                                    allowCellular: true, unmeteredOnly: false),
                        file: file, fileName: "E1.mkv", chunks: chunks, total: total, ranges: ranges,
                        connections: connections) { e in MainActor.assumeIsolated { events.add(e) } }
    }

    private func finished(_ e: ChunkedDownload.Event) -> Bool { if case .finished = e { return true }; if case .failed = e { return true }; return false }

    func testAFileComesInOverSeveralConnectionsIntoOneFile() throws {
        let data = random(24 * mb)
        RangeStub.configure(data: data)
        let file = dir.appendingPathComponent("a.download")
        let events = EventLog()
        let e = engine(file, events: events)
        run(e, events: events, until: finished)
        XCTAssertTrue(events.finished, "events: \(events.summary)")
        XCTAssertEqual(try Data(contentsOf: file), data)
        // The first request is open; once it's answered with a range, three more.
        let asked = RangeStub.ranges
        XCTAssertEqual(asked.first, "bytes=0-")
        XCTAssertGreaterThanOrEqual(asked.count, 4)
        XCTAssertTrue(RangeStub.headers.allSatisfy { $0["Authorization"] == "Basic eA==" && $0["Accept-Encoding"] == "identity" })
        XCTAssertEqual(events.answered?.total, Int64(data.count))
        XCTAssertEqual(events.answered?.ranges, true)
        XCTAssertEqual(events.maxConnections, 4)
    }

    func testAPausedDownloadCarriesOnFromTheBytesOnDisk() throws {
        let data = random(24 * mb)
        RangeStub.configure(data: data, bytesPerTick: 16 * 1024)
        let file = dir.appendingPathComponent("b.download")
        let first = EventLog()
        let e1 = engine(file, events: first)
        // Paused once a few MB are on disk.
        run(e1, events: first) { e in
            if case .progress(let got, _, _) = e, got > 3 * 1_048_576 { e1.pause(); return false }
            if case .paused = e { return true }
            return false
        }
        let (got, chunks) = try XCTUnwrap(first.paused)
        XCTAssertGreaterThan(got, Int64(3 * mb))
        XCTAssertLessThan(got, Int64(data.count))
        XCTAssertEqual(ChunkPlan.received(chunks), got)
        // What's on disk is what the ranges say.
        let disk = try Data(contentsOf: file)
        for c in chunks where c.current > c.start {
            XCTAssertEqual(disk.subdata(in: Int(c.start)..<Int(c.current)), data.subdata(in: Int(c.start)..<Int(c.current)))
        }

        // A new engine (a relaunch) from the saved ranges: none of it is fetched again.
        RangeStub.configure(data: data)
        let resumable = try XCTUnwrap(ChunkPlan.resumable(chunks, total: Int64(data.count), fileExists: true))
        let second = EventLog()
        let e2 = engine(file, chunks: resumable, total: Int64(data.count), ranges: true, events: second)
        run(e2, events: second, until: finished)
        XCTAssertTrue(second.finished, "events: \(second.summary)")
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertFalse(RangeStub.ranges.contains("bytes=0-"), "no request from the first byte")
        let left = Int64(data.count) - got
        XCTAssertLessThanOrEqual(RangeStub.served, left + Int64(4 * RangeStub.piece), "only what was missing (and a piece per connection cut short)")
    }

    func testAServerWithoutRangesGetsOneConnection() throws {
        let data = random(9 * mb)
        RangeStub.configure(data: data, ranges: false)
        let file = dir.appendingPathComponent("c.download")
        let events = EventLog()
        run(engine(file, events: events), events: events, until: finished)
        XCTAssertTrue(events.finished, "events: \(events.summary)")
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertEqual(RangeStub.ranges.count, 1)
        XCTAssertEqual(events.answered?.ranges, false)
    }

    func testADroppedConnectionIsAskedAgainFromWhereItWas() throws {
        let data = random(16 * mb)
        // The second request breaks after 1 MB.
        RangeStub.configure(data: data, dropRequest: 2, dropAfter: 1 * mb)
        let file = dir.appendingPathComponent("d.download")
        let events = EventLog()
        run(engine(file, events: events), events: events, until: finished)
        XCTAssertTrue(events.finished, "events: \(events.summary)")
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertTrue(events.notes.contains { $0.contains("again in 2 s") }, "notes: \(events.notes)")
    }

    func testAFreeConnectionTakesOverFromACrawlingOne() throws {
        let data = random(24 * mb)
        // The third request (a range) crawls at a fortieth of the others.
        RangeStub.configure(data: data, slowRequest: 3)
        let file = dir.appendingPathComponent("e.download")
        let events = EventLog()
        let t0 = Date()
        run(engine(file, events: events), events: events, timeout: 30, until: finished)
        XCTAssertTrue(events.finished, "events: \(events.summary)")
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertTrue(events.notes.contains { $0.contains("taken over by a free connection") }, "notes: \(events.notes)")
        // At its own speed the slow range (6 MB) would take ~45 s.
        XCTAssertLessThan(Date().timeIntervalSince(t0), 20)
    }

    func testAPageInsteadOfTheFileStops() throws {
        RangeStub.configure(data: Data("<html>expired</html>".utf8), contentType: "text/html")
        let file = dir.appendingPathComponent("f.download")
        let events = EventLog()
        run(engine(file, events: events), events: events, until: finished)
        guard case .failed(let message, let chunks)? = events.last else { return XCTFail("events: \(events.summary)") }
        XCTAssertTrue(message.contains("web page"), message)
        XCTAssertTrue(chunks.isEmpty)
        XCTAssertEqual((try? Data(contentsOf: file))?.count ?? 0, 0, "nothing of the page written")
    }

    func testAMissingFileIsAPermanentFailure() throws {
        RangeStub.configure(data: Data(), status: 404)
        let file = dir.appendingPathComponent("g.download")
        let events = EventLog()
        run(engine(file, events: events), events: events, until: finished)
        guard case .failed(let message, _)? = events.last else { return XCTFail("events: \(events.summary)") }
        XCTAssertTrue(DownloadManager.isPermanent(message), message)
    }
}

/// The events an engine sent, on the main thread.
@MainActor
private final class EventLog {
    var events: [ChunkedDownload.Event] = []
    var waiter: ((ChunkedDownload.Event) -> Bool)?

    func add(_ e: ChunkedDownload.Event) {
        events.append(e)
        if waiter?(e) == true { waiter = nil }
    }

    var last: ChunkedDownload.Event? { events.last { if case .note = $0 { return false }; if case .progress = $0 { return false }; return true } }
    var finished: Bool { events.contains { if case .finished = $0 { return true }; return false } }
    var answered: (total: Int64?, ranges: Bool)? {
        for e in events { if case .answered(let t, let r, _) = e { return (t, r) } }
        return nil
    }
    var paused: (Int64, [DownloadChunk])? {
        for e in events { if case .paused(let got, let chunks) = e { return (got, chunks) } }
        return nil
    }
    var notes: [String] { events.compactMap { if case .note(let s) = $0 { return s }; return nil } }
    var maxConnections: Int { events.reduce(0) { if case .progress(_, _, let n) = $1 { return max($0, n) }; return $0 } }
    var summary: String { events.map { "\($0)".prefix(120) }.joined(separator: " | ") }
}

/// A server in the test process: byte ranges (206) from `data`, in pieces
/// on the loading thread's run loop.
final class RangeStub: URLProtocol, @unchecked Sendable {
    static let url = URL(string: "https://stub.folio.invalid/E1.mkv")!
    static let piece = 64 * 1024

    private static let lock = NSLock()
    nonisolated(unsafe) private static var data = Data()
    nonisolated(unsafe) private static var answersRanges = true
    nonisolated(unsafe) private static var bytesPerTick = 64 * 1024
    nonisolated(unsafe) private static var slowRequest = 0
    nonisolated(unsafe) private static var dropRequest = 0
    nonisolated(unsafe) private static var dropAfter = 0
    nonisolated(unsafe) private static var contentType = "video/x-matroska"
    nonisolated(unsafe) private static var status = 0
    nonisolated(unsafe) private static var requestCount = 0
    nonisolated(unsafe) private static var seen: [[String: String]] = []
    nonisolated(unsafe) private static var servedBytes: Int64 = 0

    static func configure(data: Data, ranges: Bool = true, bytesPerTick: Int = 64 * 1024, slowRequest: Int = 0,
                          dropRequest: Int = 0, dropAfter: Int = 0, contentType: String = "video/x-matroska", status: Int = 0) {
        lock.lock(); defer { lock.unlock() }
        self.data = data
        answersRanges = ranges
        self.bytesPerTick = bytesPerTick
        self.slowRequest = slowRequest
        self.dropRequest = dropRequest
        self.dropAfter = dropAfter
        self.contentType = contentType
        self.status = status
        requestCount = 0
        seen = []
        servedBytes = 0
    }

    static func reset() { configure(data: Data()) }

    static var headers: [[String: String]] { lock.lock(); defer { lock.unlock() }; return seen }
    static var ranges: [String] { headers.compactMap { $0["Range"] } }
    static var served: Int64 { lock.lock(); defer { lock.unlock() }; return servedBytes }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == url.host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var timer: Timer?
    private var stopped = false

    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        let n = Self.requestCount
        Self.seen.append(request.allHTTPHeaderFields ?? [:])
        let data = Self.data, ranges = Self.answersRanges, type = Self.contentType, status = Self.status
        var perTick = Self.bytesPerTick
        if n == Self.slowRequest { perTick = max(1024, perTick / 40) }
        let dropAt = n == Self.dropRequest ? Self.dropAfter : 0
        Self.lock.unlock()

        let total = data.count
        var start = 0, end = total - 1, code = 200
        if status != 0 {
            code = status
            end = -1
        } else if ranges, let r = request.value(forHTTPHeaderField: "Range"), r.hasPrefix("bytes=") {
            let bounds = r.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            if let a = bounds.first.flatMap({ Int($0) }) {
                start = a
                end = bounds.count > 1 ? Int(bounds[1]).map { min($0, total - 1) } ?? total - 1 : total - 1
                code = 206
            }
        }
        var head = ["Content-Type": type, "Content-Length": "\(max(0, end - start + 1))", "Accept-Ranges": ranges ? "bytes" : "none"]
        if code == 206 { head["Content-Range"] = "bytes \(start)-\(end)/\(total)" }
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: head)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard end >= start else { client?.urlProtocolDidFinishLoading(self); return }
        var offset = start, sent = 0
        let t = Timer(timeInterval: 0.004, repeats: true) { [weak self] t in
            guard let self, !self.stopped else { t.invalidate(); return }
            let count = min(perTick, end + 1 - offset)
            self.client?.urlProtocol(self, didLoad: data.subdata(in: offset..<offset + count))
            Self.lock.lock(); Self.servedBytes += Int64(count); Self.lock.unlock()
            offset += count
            sent += count
            if dropAt > 0, sent >= dropAt {
                t.invalidate()
                self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            } else if offset > end {
                t.invalidate()
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
        RunLoop.current.add(t, forMode: .common)
        timer = t
    }

    override func stopLoading() {
        stopped = true
        timer?.invalidate()
    }
}
