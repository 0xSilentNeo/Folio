import Foundation

/// One byte range of a file downloading in Folio itself (1.22.3), written
/// at its own offset into the one file the whole download goes to: when
/// the last range is in, the file is whole (nothing to join).
struct DownloadChunk: Codable, Hashable {
    var start: Int64
    /// The last byte, included; -1 while the file's length isn't known (one open request).
    var end: Int64
    /// The next byte to fetch: from `start` up to here is on disk.
    var current: Int64

    var isDone: Bool { end >= 0 && current > end }
    var remaining: Int64 { end < 0 ? .max : max(0, end - current + 1) }
    var received: Int64 { max(0, current - start) }
}

/// The decisions of the in-app engine (1.22.3), kept apart from the
/// transfers so tests can check them: how a file is split, which range a
/// free connection takes, which connection is started again.
enum ChunkPlan {
    /// No range smaller than this: a new connection costs a round trip and
    /// TCP's slow start, which a few MB don't make up for.
    static let minimum: Int64 = 4 * 1_048_576
    /// Retries of one range before the whole file fails (and its own retries take over).
    static let rangeRetries = 4
    /// How often the connections' speeds are compared; how long one runs
    /// before it can be judged slow (past TCP's slow start), and before its
    /// speed counts in the median the others are judged by.
    static let window: TimeInterval = 8
    static let judgeAfter: TimeInterval = 12
    static let countAfter: TimeInterval = 4
    /// A connection under this share of the median speed is started again
    /// (a stuck server node or route); none while the median is under `slowFloor`.
    static let slowShare = 0.15
    static let slowFloor: Double = 64 * 1024

    /// What the chunks have on disk.
    static func received(_ chunks: [DownloadChunk]) -> Int64 { chunks.reduce(0) { $0 + $1.received } }

    /// The first answer gave the length: the rest of the file from `from`
    /// (what the first request has reached) in up to `connections` ranges
    /// of equal size, none under `minimum`. Bytes before `from` are one
    /// finished range. The first range of the rest is the first request's.
    static func split(total: Int64, connections: Int, from: Int64 = 0) -> [DownloadChunk] {
        guard total > 0 else { return [] }
        let from = min(max(0, from), total)
        var out: [DownloadChunk] = []
        if from > 0 { out.append(DownloadChunk(start: 0, end: from - 1, current: from)) }
        let rest = total - from
        guard rest > 0 else { return out }
        let count = Int(max(1, min(Int64(max(1, connections)), rest / minimum)))
        let size = rest / Int64(count)
        for k in 0..<count {
            let start = from + Int64(k) * size
            out.append(DownloadChunk(start: start, end: k == count - 1 ? total - 1 : start + size - 1, current: start))
        }
        return out
    }

    /// A connection is free and no range waits: the range that would take
    /// longest at its connection's speed (`busy`: range → bytes per second,
    /// nil while too new to say) gives its end to the free connection, as
    /// much as that one fetches in the time the old one needs for the rest
    /// at `reference` (the file's usual speed per connection): half at equal
    /// speeds, nearly all of it when the old one crawls. Worth it for at
    /// least `minimum`, or, for a range that would take more than
    /// `endgame` seconds as it goes, at least `endgameMinimum` (a stuck
    /// connection on the last few MB held a file up for half a minute).
    /// Nil when nothing is. The running request keeps going and stops at
    /// the range's new end.
    static func takeOver(_ chunks: [DownloadChunk], busy: [Int: Double?], reference: Double?) -> (index: Int, chunk: DownloadChunk)? {
        func speed(_ i: Int) -> Double? { (busy[i] ?? nil).flatMap { $0 > 0 ? $0 : nil } ?? reference }
        func eta(_ i: Int) -> Double { speed(i).map { Double(chunks[i].remaining) / $0 } ?? Double(chunks[i].remaining) }
        let candidates = busy.keys.filter { chunks.indices.contains($0) && !chunks[$0].isDone && chunks[$0].end >= 0 }
        guard let i = candidates.max(by: { eta($0) < eta($1) }) else { return nil }
        let left = chunks[i].remaining
        var share = 0.5
        if let s = (busy[i] ?? nil), s > 0, let r = reference, r > 0 { share = min(0.95, max(0.1, r / (s + r))) }
        let part = Int64(Double(left) * share)
        let slowEnd = (busy[i] ?? nil).map { $0 > 0 ? Double(left) / $0 > endgame : true } ?? false
        guard part >= minimum || (slowEnd && part >= endgameMinimum) else { return nil }
        let cut = chunks[i].end - part + 1
        guard cut > chunks[i].current else { return nil }
        return (i, DownloadChunk(start: cut, end: chunks[i].end, current: cut))
    }

    /// A range left to a crawling connection takes over this long: worth a new connection for less than `minimum`.
    static let endgame: TimeInterval = 8
    static let endgameMinimum: Int64 = 512 * 1024
    /// Less than this left isn't worth starting a connection again for.
    static let restartFloor: Int64 = 1_048_576

    /// A range not done and not downloading (after a pause, a retry, or more
    /// ranges than connections): the one with the most left first.
    static func waiting(_ chunks: [DownloadChunk], busy: Set<Int>) -> Int? {
        chunks.indices.filter { !busy.contains($0) && !chunks[$0].isDone }.max { chunks[$0].remaining < chunks[$1].remaining }
    }

    struct Reading: Equatable {
        var task: Int
        /// Bytes per second over its time in the last window.
        var speed: Double
        /// Seconds since the connection started.
        var age: TimeInterval
        var remaining: Int64
    }

    /// The connections to start again: running at least `judgeAfter`, under
    /// `slowShare` of the median speed, with more than `restartFloor` left.
    /// The median counts every connection past `countAfter` and the speeds
    /// of those that finished their range (`finished`): connections that
    /// took over ranges a moment ago say how fast the server is as well as
    /// old ones, and a stuck connection left alone at the end is judged by
    /// the ones that were done before it.
    static func slow(_ readings: [Reading], finished: [Double] = []) -> [Int] {
        let counted = readings.filter { $0.age >= countAfter }
        let speeds = (counted.map(\.speed) + finished).sorted()
        guard speeds.count >= 2, !counted.isEmpty else { return [] }
        let median = speeds[speeds.count / 2]
        guard median > slowFloor else { return [] }
        return counted.filter { $0.age > judgeAfter && $0.speed < median * slowShare && $0.remaining > restartFloor }.map(\.task)
    }

    /// The usual speed of one connection: the median of those running past
    /// `countAfter` and those that finished. Nil before there's any.
    static func reference(running: [Double], finished: [Double]) -> Double? {
        let all = (running + finished).filter { $0 > 0 }.sorted()
        return all.isEmpty ? nil : all[all.count / 2]
    }

    /// "bytes 100-199/12345" → (100, 199, 12345); the length is nil for "*".
    static func contentRange(_ value: String?) -> (start: Int64, end: Int64, total: Int64?)? {
        guard let value else { return nil }
        let v = value.trimmingCharacters(in: .whitespaces)
        guard v.lowercased().hasPrefix("bytes") else { return nil }
        let body = v.dropFirst(5).trimmingCharacters(in: .whitespaces)
        let halves = body.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }
        let bounds = halves[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2, let a = Int64(bounds[0].trimmingCharacters(in: .whitespaces)),
              let b = Int64(bounds[1].trimmingCharacters(in: .whitespaces)), a >= 0, b >= a else { return nil }
        let total = Int64(halves[1].trimmingCharacters(in: .whitespaces))
        if let total, b >= total { return nil }
        return (a, b, total)
    }

    /// Saved ranges a download can carry on from: they cover the file from
    /// 0 to its length without a gap or an overlap and the file is on disk.
    /// Nil: start again from the first byte.
    static func resumable(_ chunks: [DownloadChunk]?, total: Int64?, fileExists: Bool) -> [DownloadChunk]? {
        guard fileExists, let chunks, !chunks.isEmpty else { return nil }
        // One open request (no length known): it carries on where it was.
        if chunks.count == 1, chunks[0].end < 0 { return chunks[0].start == 0 && chunks[0].current >= 0 ? chunks : nil }
        guard let total, total > 0 else { return nil }
        let ordered = chunks.sorted { $0.start < $1.start }
        var next: Int64 = 0
        for c in ordered {
            guard c.start == next, c.end >= c.start, c.current >= c.start, c.current <= c.end + 1 else { return nil }
            next = c.end + 1
        }
        return next == total ? ordered : nil
    }

    /// A web page where a file was asked for: an expired link, a login or a
    /// captcha page. It must not be written into the file.
    static func isPage(contentType: String?, fileName: String) -> Bool {
        let type = (contentType ?? "").lowercased()
        guard type.contains("text/html") else { return false }
        return !["htm", "html", "php", "asp", "aspx"].contains((fileName as NSString).pathExtension.lowercased())
    }
}

/// One file downloading in Folio itself over several connections at once
/// (1.22.3). Data tasks of an ordinary URLSession in Folio's own process:
/// iOS's background session hands transfers to its download daemon, which
/// schedules them as it sees fit (on the 4 Nov phone report half to a third
/// of the Wi-Fi's speed); in the app they run at the network's pace.
///
/// The first request is open-ended; once the server answers it with a byte
/// range (HTTP 206) and the length, the rest of the file is split among the
/// connections. When a connection finishes early it takes half of the
/// largest range left, so all of them stay busy to the end, and one that
/// crawls far below the others is started again. What arrives is gathered
/// 4 MB at a time and written at its offset into one file, so there's no
/// join at the end; progress reports only what's on disk, so a pause or a
/// relaunch carries on from there.
///
/// All its state lives on `queue`, which is also the session's delegate
/// queue. Events go to the main thread.
final class ChunkedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Event {
        /// The first answer: the file's length (nil: not given), whether the
        /// server takes byte ranges, and the host that answered.
        case answered(total: Int64?, ranges: Bool, host: String)
        /// What's on disk now, and the connections running.
        case progress(received: Int64, chunks: [DownloadChunk], connections: Int)
        /// Stopped by `pause`: everything received is written.
        case paused(received: Int64, chunks: [DownloadChunk])
        /// The file is whole.
        case finished(file: URL, received: Int64)
        /// It stopped on an error; `chunks` are what a retry carries on from
        /// (empty: start again from the first byte).
        case failed(message: String, chunks: [DownloadChunk])
        /// A line for the log (splits, restarts, retries).
        case note(String)
    }

    let id: UUID
    let file: URL
    private let request: DownloadEngine.Request
    private let fileName: String
    private let connections: Int
    private let onEvent: @Sendable (Event) -> Void

    private let queue: OperationQueue
    private var session: URLSession?
    private var handle: FileHandle?

    private var chunks: [DownloadChunk]
    private var total: Int64?
    private var ranges: Bool?
    /// Running requests by task identifier: their range, when they started
    /// and what they brought.
    private var tasks: [Int: (task: URLSessionDataTask, chunk: Int, started: Date, bytes: Int64)] = [:]
    /// Speeds of the last connections that finished their range.
    private var finishedSpeeds: [Double] = []
    private var retries: [Int: Int] = [:]
    /// Where each range was when it last stopped early.
    private var stoppedAt: [Int: Int64] = [:]
    /// What arrived per range and isn't written yet: fewer, bigger writes.
    private var buffers: [Int: (offset: Int64, data: Data)] = [:]
    private static let flushAt = 4 << 20
    /// Bytes per request since the last speed comparison.
    private var windowBytes: [Int: Int64] = [:]
    private var windowStart = Date()
    /// Requests cancelled to be started again at once (not failures).
    private var restarting = Set<Int>()
    private var stopped = false
    private var answered = false
    private var lastReport = Date.distantPast
    private var lastFlush = Date.distantPast
    /// For the log at the end: ranges a free connection took over, and slow ones started again.
    private var splits = 0
    private var restarts = 0

    /// Tests (ChunkedDownloadTests): a stand-in server's URLProtocol, put first.
    nonisolated(unsafe) static var protocolClasses: [AnyClass] = []

    /// `chunks`: where an earlier run stopped (empty: from the start).
    /// `total` and `ranges`: what the server said then.
    init(id: UUID, request: DownloadEngine.Request, file: URL, fileName: String, chunks: [DownloadChunk],
         total: Int64?, ranges: Bool?, connections: Int, onEvent: @escaping @Sendable (Event) -> Void) {
        self.id = id
        self.request = request
        self.file = file
        self.fileName = fileName
        self.chunks = chunks
        self.total = total
        self.ranges = ranges
        self.connections = max(1, connections)
        self.onEvent = onEvent
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        // 1.27.0: user-initiated (was utility). A download you started is
        // waited for; in the background iOS slows utility work the most, and
        // receiving and writing ~60 MB/s all happens on this queue
        // (9 Nov report: the speed fell once Folio left the screen).
        q.qualityOfService = .userInitiated
        q.name = "folio.download.\(id.uuidString.prefix(8))"
        queue = q
        super.init()
    }

    // MARK: Control

    func start() { queue.addOperation { [self] in begin() } }

    /// Stops, writing what arrived first; answers with `.paused`.
    func pause() {
        queue.addOperation { [self] in
            guard !stopped else { emit(.paused(received: ChunkPlan.received(chunks), chunks: chunks)); return }
            // A failed write has already rolled the ranges back and said so.
            guard flushAll() else { return }
            stopped = true
            teardown()
            emit(.paused(received: ChunkPlan.received(chunks), chunks: chunks))
        }
    }

    /// Stops without a word; `deleting`: the file goes too.
    func cancel(deleting: Bool) {
        queue.addOperation { [self] in
            stopped = true
            buffers.removeAll()
            teardown()
            if deleting { try? FileManager.default.removeItem(at: file) }
        }
    }

    // MARK: Running (on `queue`)

    private func begin() {
        guard !stopped else { return }
        let c = URLSessionConfiguration.default
        c.allowsCellularAccess = request.allowCellular && !request.unmeteredOnly
        if request.unmeteredOnly {
            c.allowsExpensiveNetworkAccess = false
            c.allowsConstrainedNetworkAccess = false
        }
        // Without an allowed network (Wi-Fi gone, mobile data off) a
        // request waits for one, as the background session's did, rather
        // than failing the file.
        c.waitsForConnectivity = true
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 7 * 24 * 3600
        c.httpMaximumConnectionsPerHost = connections + 1
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        if !Self.protocolClasses.isEmpty { c.protocolClasses = Self.protocolClasses + (c.protocolClasses ?? []) }
        session = URLSession(configuration: c, delegate: self, delegateQueue: queue)

        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) {
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: file.path, contents: nil) else {
                fail("Couldn't create the download's file in \(file.deletingLastPathComponent().lastPathComponent)")
                return
            }
            // No file: whatever was saved about it is gone too.
            chunks = []
        }
        do { handle = try FileHandle(forWritingTo: file) } catch {
            fail("Couldn't open the download's file: \(error.localizedDescription)")
            return
        }
        if ranges == true, !chunks.isEmpty {
            if chunks.allSatisfy(\.isDone) { complete(); return }
            fillConnections()
        } else {
            // From the first byte: one open request, split once the server
            // answers it with a range.
            try? handle?.truncate(atOffset: 0)
            chunks = [DownloadChunk(start: 0, end: -1, current: 0)]
            startTask(0)
        }
    }

    /// Up to `connections` requests: ranges waiting first, then halves of the largest.
    private func fillConnections() {
        guard !stopped else { return }
        while tasks.count < connections {
            let busy = Set(tasks.values.map { $0.chunk })
            if let i = ChunkPlan.waiting(chunks, busy: busy) {
                guard startTask(i) else { return }
            } else if ranges == true, let (i, new) = ChunkPlan.takeOver(chunks, busy: busySpeeds(), reference: referenceSpeed()) {
                chunks[i].end = new.start - 1
                chunks.append(new)
                splits += 1
                guard startTask(chunks.count - 1) else { return }
            } else {
                return
            }
        }
    }

    @discardableResult
    private func startTask(_ index: Int) -> Bool {
        // A delayed retry may come after the ranges changed (the server stopped answering ranges).
        guard let session, !stopped, chunks.indices.contains(index), !chunks[index].isDone,
              !tasks.values.contains(where: { $0.chunk == index }) else { return false }
        var req = URLRequest(url: request.url)
        req.timeoutInterval = 60
        req.allowsCellularAccess = request.allowCellular && !request.unmeteredOnly
        if request.unmeteredOnly {
            req.allowsExpensiveNetworkAccess = false
            req.allowsConstrainedNetworkAccess = false
        }
        for (k, v) in request.headers { req.setValue(v, forHTTPHeaderField: k) }
        let c = chunks[index]
        req.setValue(c.end >= 0 ? "bytes=\(c.current)-\(c.end)" : "bytes=\(c.current)-", forHTTPHeaderField: "Range")
        // Byte offsets mean bytes of the file, not of a compressed stream.
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: req)
        // Ahead of other traffic of Folio's (1.27.0).
        task.priority = URLSessionTask.highPriority
        tasks[task.taskIdentifier] = (task, index, Date(), 0)
        task.resume()
        return true
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !stopped, let index = tasks[dataTask.taskIdentifier]?.chunk, let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        let status = http.statusCode
        let host = http.url?.host ?? "the server"
        let chunk = chunks[index]
        if status == 416, let total, chunk.current >= total {
            chunks[index].end = total - 1
            chunks[index].current = total
            completionHandler(.cancel)
            return
        }
        guard (200..<300).contains(status) else {
            completionHandler(.cancel)
            fail(status == 401 ? "Wrong username or password (HTTP 401)" : "Server returned HTTP \(status)")
            return
        }
        if ChunkPlan.isPage(contentType: http.value(forHTTPHeaderField: "Content-Type"), fileName: fileName) {
            completionHandler(.cancel)
            fail("\(host) sent a web page instead of the file (an expired link or a login page)")
            return
        }
        let resuming = chunk.current > 0 || chunks.count > 1
        if status == 206 {
            let range = ChunkPlan.contentRange(http.value(forHTTPHeaderField: "Content-Range"))
            if let range, range.start != chunk.current {
                completionHandler(.cancel)
                fail("\(host) sent the wrong byte range (\(range.start) for \(chunk.current))")
                return
            }
            if resuming, let known = total, let now = range?.total, known != now {
                // Another file behind the link now: start again rather than mix the two.
                completionHandler(.cancel)
                chunks = []
                buffers.removeAll()
                try? handle?.truncate(atOffset: 0)
                fail("The file on the server changed (\(known) bytes, now \(now)): it downloads again from the start")
                return
            }
            ranges = true
            if let now = range?.total { total = now }
            if chunks.count == 1, chunks[0].end < 0, let total {
                chunks = ChunkPlan.split(total: total, connections: connections, from: chunks[0].current)
                // The first request is the range starting where it is.
                let first = chunks.firstIndex { $0.start == chunk.current && !$0.isDone } ?? 0
                tasks[dataTask.taskIdentifier]?.chunk = first
                if chunks.count > 1 { emit(.note("\(chunks.count) ranges over up to \(connections) connections")) }
                fillConnections()
            }
        } else {
            // HTTP 200: the whole file, whatever was asked.
            let length = http.expectedContentLength
            if resuming, ranges == true {
                // It answered ranges before: a passing mirror or node. The
                // bytes on disk stay; this range is asked for again.
                completionHandler(.cancel)
                emit(.note("\(host) ignored the byte range (HTTP 200), asking again"))
                return
            }
            ranges = false
            total = length > 0 ? length : nil
            if resuming {
                // It can't resume: one connection from the first byte.
                for (k, t) in tasks where k != dataTask.taskIdentifier { t.task.cancel() }
                tasks = tasks.filter { $0.key == dataTask.taskIdentifier }
                chunks = [DownloadChunk(start: 0, end: total.map { $0 - 1 } ?? -1, current: 0)]
                tasks[dataTask.taskIdentifier]?.chunk = 0
                retries.removeAll()
                buffers.removeAll()
                try? handle?.truncate(atOffset: 0)
                emit(.note("\(host) sends the whole file (HTTP 200): one connection from the start"))
            } else if let total {
                chunks[0].end = total - 1
            }
        }
        if !answered {
            answered = true
            emit(.answered(total: total, ranges: ranges == true, host: host))
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !stopped, let index = tasks[dataTask.taskIdentifier]?.chunk, handle != nil else { return }
        var payload = data
        let chunk = chunks[index]
        if chunk.end >= 0 {
            let allowed = chunk.end - chunk.current + 1
            // Its range was cut in two for another connection: it stops at the cut.
            guard allowed > 0 else { dataTask.cancel(); return }
            if Int64(payload.count) > allowed { payload = payload.prefix(Int(allowed)) }
        }
        // Appended in place (a copy of the buffer out of the dictionary
        // first would copy up to 4 MB on every network read).
        let follows = buffers[index].map { $0.offset + Int64($0.data.count) == chunk.current } ?? false
        if follows {
            buffers[index]?.data.append(payload)
        } else {
            guard flush(index) else { return }
            var d = Data()
            d.reserveCapacity(1 << 20)
            d.append(payload)
            buffers[index] = (chunk.current, d)
        }
        chunks[index].current += Int64(payload.count)
        windowBytes[dataTask.taskIdentifier, default: 0] += Int64(payload.count)
        tasks[dataTask.taskIdentifier]?.bytes += Int64(payload.count)
        if chunks[index].isDone || (buffers[index]?.data.count ?? 0) >= Self.flushAt {
            guard flush(index) else { return }
        }
        if chunks[index].isDone { dataTask.cancel() }

        let now = Date()
        if now.timeIntervalSince(windowStart) > ChunkPlan.window { restartSlow(now) }
        if now.timeIntervalSince(lastReport) > 0.5 {
            lastReport = now
            // Written every 2 s, not on every report: fewer, larger writes.
            if now.timeIntervalSince(lastFlush) > 2 {
                lastFlush = now
                guard flushAll() else { return }
            }
            // A free connection looks again: a range whose connection was
            // too new to judge when it came free may be worth taking over now.
            if tasks.count < connections, ranges == true { fillConnections() }
            let disk = onDisk
            emit(.progress(received: ChunkPlan.received(disk), chunks: disk, connections: tasks.count))
        }
    }

    /// The ranges as written (bytes still in memory left out), so what's
    /// saved is never ahead of the file.
    private var onDisk: [DownloadChunk] {
        var out = chunks
        for (i, b) in buffers where out.indices.contains(i) {
            out[i].current = max(out[i].start, out[i].current - Int64(b.data.count))
        }
        return out
    }

    /// The protocol the server answered with, logged once per file (1.27.0):
    /// over HTTP/2 the ranges share one connection, so more ranges don't add
    /// connections' worth of speed.
    private var protocolLogged = false

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard !protocolLogged, let p = metrics.transactionMetrics.last?.networkProtocolName else { return }
        protocolLogged = true
        let name = ["h2": "HTTP/2", "h3": "HTTP/3", "http/1.1": "HTTP/1.1"][p.lowercased()] ?? p
        // Through emit, to the main thread like every other event (1.28.3).
        // Called here on URLSession's queue, the manager's handler asserted
        // the main thread and the app ended the moment a connection
        // finished, a cancelled one too: a crash on every launch that
        // resumed the download, and on pause and delete (10 Nov report).
        emit(.note("\(fileName): the server answers over \(name)"))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = tasks.removeValue(forKey: task.taskIdentifier) else { return }
        windowBytes[task.taskIdentifier] = nil
        guard !stopped else { return }
        let index = entry.chunk
        guard flush(index) else { return }
        if restarting.remove(task.taskIdentifier) != nil {
            if !chunks[index].isDone { startTask(index) }
            return
        }
        if chunks[index].end < 0, error == nil {
            // No length given: the end of the stream is the end of the file.
            chunks[index].end = chunks[index].current - 1
            total = chunks[index].current
            if chunks[index].current == 0 { complete(); return }
        }
        if chunks[index].isDone {
            let age = Date().timeIntervalSince(entry.started)
            if age >= ChunkPlan.countAfter { finishedSpeeds = Array((finishedSpeeds + [Double(entry.bytes) / age]).suffix(8)) }
            if chunks.allSatisfy(\.isDone) {
                if tasks.isEmpty { complete() }
                return
            }
            fillConnections()
            return
        }
        // Ended early (a network error, or the server closed): this range again.
        // Counted from 0 again once the range has got further since it last
        // stopped (1.28.6): the count only went up, so four blips hours
        // apart failed a file that was downloading fine in between.
        // Only where a retry carries on (1.28.10): without ranges each one starts
        // from the first byte, and stopping a little later than last time isn't progress.
        if ranges == true, let last = stoppedAt[index], chunks[index].current - last >= 1 << 20 { retries[index] = nil }
        stoppedAt[index] = chunks[index].current
        let attempts = (retries[index] ?? 0) + 1
        retries[index] = attempts
        let message = error?.localizedDescription ?? "The connection closed before the range was in"
        guard attempts <= ChunkPlan.rangeRetries else { fail(message); return }
        if ranges != true {
            // No ranges: it can only start again from the first byte.
            buffers.removeAll()
            chunks[index].current = chunks[index].start
            try? handle?.truncate(atOffset: 0)
        }
        let delay = Double(attempts) * 2
        emit(.note("range \(index + 1) stopped at \(chunks[index].current) (\(message)), again in \(Int(delay)) s"))
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.queue.addOperation { self.startTask(index) }
        }
    }

    /// Starts again the connections running far below the others.
    private func restartSlow(_ now: Date) {
        let elapsed = now.timeIntervalSince(windowStart)
        defer {
            windowBytes.removeAll()
            windowStart = now
        }
        guard elapsed > 0 else { return }
        // Each over its own time in the window: one that started in it isn't made slower than it is.
        let readings = tasks.map { id, t in
            let span = max(1, now.timeIntervalSince(max(windowStart, t.started)))
            return ChunkPlan.Reading(task: id, speed: Double(windowBytes[id] ?? 0) / span,
                                     age: now.timeIntervalSince(t.started), remaining: chunks[t.chunk].remaining)
        }
        for id in ChunkPlan.slow(readings, finished: finishedSpeeds) {
            guard let t = tasks[id] else { continue }
            let kb = Int((readings.first { $0.task == id }?.speed ?? 0) / 1024)
            emit(.note("range \(t.chunk + 1) crawls at \(kb) KB/s, far below the others: a new connection for it"))
            restarting.insert(id)
            restarts += 1
            t.task.cancel()
        }
    }

    /// Each running range's connection speed since it started; nil while too new to say.
    private func busySpeeds() -> [Int: Double?] {
        let now = Date()
        var out: [Int: Double?] = [:]
        for t in tasks.values {
            let age = now.timeIntervalSince(t.started)
            out[t.chunk] = age >= ChunkPlan.countAfter ? Double(t.bytes) / age : nil
        }
        return out
    }

    private func referenceSpeed() -> Double? {
        ChunkPlan.reference(running: busySpeeds().values.compactMap { $0 }, finished: finishedSpeeds)
    }

    /// Writes a range's buffered bytes; false (after failing) on an error.
    @discardableResult
    private func flush(_ index: Int) -> Bool {
        guard let b = buffers.removeValue(forKey: index) else { return true }
        guard !b.data.isEmpty, let handle else { return true }
        do {
            try handle.seek(toOffset: UInt64(b.offset))
            try handle.write(contentsOf: b.data)
            return true
        } catch {
            buffers[index] = b
            fail("Couldn't write the download: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    private func flushAll() -> Bool {
        for index in Array(buffers.keys) where !flush(index) { return false }
        return true
    }

    private func complete() {
        guard !stopped, flushAll() else { return }
        stopped = true
        if let total { try? handle?.truncate(atOffset: UInt64(total)) }
        let bytes = ChunkPlan.received(chunks)
        teardown()
        if splits > 0 || restarts > 0 {
            emit(.note("\(splits) range\(splits == 1 ? "" : "s") taken over by a free connection, \(restarts) slow connection\(restarts == 1 ? "" : "s") started again"))
        }
        emit(.finished(file: file, received: bytes))
    }

    private func fail(_ message: String) {
        guard !stopped else { return }
        // What's still in memory never reached the disk: the ranges go back to what's written.
        for (i, b) in buffers where chunks.indices.contains(i) { chunks[i].current = min(chunks[i].current, b.offset) }
        buffers.removeAll()
        stopped = true
        let keep = ranges == true ? chunks : []
        teardown()
        emit(.failed(message: message, chunks: keep))
    }

    private func teardown() {
        for t in tasks.values { t.task.cancel() }
        tasks.removeAll()
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func emit(_ event: Event) {
        let handler = onEvent
        DispatchQueue.main.async { handler(event) }
    }
}
