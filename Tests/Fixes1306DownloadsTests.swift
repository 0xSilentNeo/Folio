import XCTest
@testable import Folio

/// 1.30.6: the review of 1.30.4's downloads. A file waiting for a network
/// keeps its slot against files that would wait too, and the newest beyond
/// the limit go back to the queue once it has one again; free space is kept
/// for the files running; the pill resumes only the files it counts; iOS's
/// stop button pauses; a failed file queued again carries on in place or
/// leaves no file behind, and a launch sweep deletes files no download is
/// for; a server error or a page from the address a link led to is asked
/// through the link; the pill never says "0 files".
@MainActor
final class Fixes1306DownloadsTests: XCTestCase {
    private let gb: Int64 = 1 << 30
    private var madeIDs: [UUID] = []
    private var savedDefaults: [String: Any?] = [:]

    override func tearDown() {
        let dm = DownloadManager.shared
        for id in madeIDs { dm.remove(id) }
        madeIDs = []
        for (k, v) in savedDefaults {
            if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
        savedDefaults = [:]
        ChunkedDownload.protocolClasses = []
        LinkStub.reset()
        super.tearDown()
    }

    private func setDefault(_ key: String, _ value: Any) {
        if savedDefaults.index(forKey: key) == nil { savedDefaults[key] = UserDefaults.standard.object(forKey: key) }
        UserDefaults.standard.set(value, forKey: key)
    }

    private func item(_ name: String, state: DownloadItem.State, expected: Int64 = 100, url: URL? = nil) -> DownloadItem {
        var d = DownloadItem(url: url ?? URL(string: "https://dav.example.invalid/\(UUID().uuidString)/\(name)")!, fileName: name,
                             package: "Fixes1306", expected: expected,
                             destination: MPVFiles.mediaDir.appendingPathComponent("Fixes1306").appendingPathComponent(name))
        d.state = state
        return d
    }

    // MARK: D1, a file waiting for a network keeps its slot

    func testNetworkNeedsGoFromWiFiOnlyToAnyNetwork() {
        XCTAssertEqual(DownloadManager.networkNeed(wifiOnly: true, cellular: true), 0, "next episodes: Wi-Fi only whatever the setting")
        XCTAssertEqual(DownloadManager.networkNeed(wifiOnly: false, cellular: false), 1)
        XCTAssertEqual(DownloadManager.networkNeed(wifiOnly: false, cellular: true), 2)
    }

    func testAWaitingFileHoldsItsSlotAgainstOneThatWouldWaitToo() {
        // Two files waiting for Wi-Fi, two at once: a third without mobile data would wait as well.
        XCTAssertFalse(DownloadManager.mayStart(need: 1, running: 0, waiting: [1, 1], limit: 2))
        XCTAssertFalse(DownloadManager.mayStart(need: 0, running: 0, waiting: [1, 1], limit: 2), "fewer networks: it would wait too")
        // One allowed on mobile data starts beside them (1.30.4's reason).
        XCTAssertTrue(DownloadManager.mayStart(need: 2, running: 0, waiting: [1, 1], limit: 2))
        // Once one allowed on mobile data waits too, there's no network at all: nothing more starts.
        XCTAssertFalse(DownloadManager.mayStart(need: 2, running: 0, waiting: [1, 1, 2], limit: 2))
        XCTAssertFalse(DownloadManager.mayStart(need: 1, running: 0, waiting: [1, 2], limit: 2))
        // A free slot is a free slot.
        XCTAssertTrue(DownloadManager.mayStart(need: 1, running: 0, waiting: [1], limit: 2))
        XCTAssertTrue(DownloadManager.mayStart(need: 1, running: 0, waiting: [], limit: 1))
        XCTAssertFalse(DownloadManager.mayStart(need: 2, running: 1, waiting: [], limit: 1))
        // Files waiting for Wi-Fi that isn't metered don't hold slots against ones that may use any Wi-Fi.
        XCTAssertTrue(DownloadManager.mayStart(need: 1, running: 1, waiting: [0, 0], limit: 2))
        XCTAssertFalse(DownloadManager.mayStart(need: 1, running: 2, waiting: [0, 0], limit: 2))
    }

    /// The review's case: no allowed network, 24 files queued, 2 at once.
    /// Each file started waits at once; 1.30.4 started all 24.
    func testWithNoNetworkTheQueueDoesntRunAway() {
        var waiting: [Int] = []
        for _ in 0..<24 {
            let need = DownloadManager.networkNeed(wifiOnly: false, cellular: false)
            if DownloadManager.mayStart(need: need, running: 0, waiting: waiting, limit: 2) { waiting.append(need) }
        }
        XCTAssertEqual(waiting.count, 2)

        // Mixed needs, no network at all: one try for each wider need, no more.
        waiting = []
        for k in 0..<24 {
            let need = DownloadManager.networkNeed(wifiOnly: k % 3 == 0, cellular: k % 3 == 2)
            if DownloadManager.mayStart(need: need, running: 0, waiting: waiting, limit: 2) { waiting.append(need) }
        }
        XCTAssertLessThanOrEqual(waiting.count, 4, "\(waiting)")
    }

    func testBackOnANetworkTheNewestBeyondTheLimitGoBack() {
        let t = Date()
        let a = UUID(), b = UUID(), c = UUID(), s = UUID()
        let running: [(id: UUID, started: Date, inApp: Bool)] = [
            (a, t, true), (b, t.addingTimeInterval(10), true), (c, t.addingTimeInterval(20), true),
            (s, t.addingTimeInterval(30), false),          // in iOS's session: not stopped from here
        ]
        XCTAssertEqual(DownloadManager.overLimit(running, limit: 2), [c, b])
        XCTAssertEqual(DownloadManager.overLimit(running, limit: 3), [c])
        XCTAssertEqual(DownloadManager.overLimit(running, limit: 4), [])
        XCTAssertEqual(DownloadManager.overLimit(Array(running.prefix(2)), limit: 2), [])
    }

    // MARK: D2, the pill resumes what it counts

    func testThePillResumesOnlyFilesPausedThisRun() {
        let now = item("now.mkv", state: .paused)
        let weeksAgo = item("old.mkv", state: .paused)
        let addedPaused = item("added.mkv", state: .paused)        // "Start automatically" off
        let queued = item("queued.mkv", state: .queued)
        let list = [now, weeksAgo, addedPaused, queued]
        XCTAssertEqual(DownloadManager.pillPaused(list, pausedThisRun: [now.id, queued.id]), [now.id])
        XCTAssertEqual(DownloadManager.pillPaused(list, pausedThisRun: []), [])
    }

    // MARK: D3, iOS's stop button pauses

    func testIOSsStopButtonPausesTheFilesInFolio() throws {
        let dm = DownloadManager.shared
        var inApp = item("stop.mkv", state: .queued)
        inApp.notBefore = .distantFuture           // the queue leaves it alone meanwhile
        var session = item("session.mkv", state: .queued)
        session.inSession = true
        session.notBefore = .distantFuture
        madeIDs += [inApp.id, session.id]
        dm.insertForTests([inApp, session])
        let stop = try XCTUnwrap(SystemProgress.shared.onStop)
        stop(true)                                 // in the background: its stop button, or iOS
        let a = try XCTUnwrap(dm.items.first { $0.id == inApp.id })
        XCTAssertEqual(a.state, .paused, "not held: it doesn't start again when Folio is next open")
        XCTAssertFalse(a.held)
        XCTAssertTrue(dm.pausedThisRun.contains(inApp.id), "the pill stays, with its play button")
        XCTAssertEqual(dm.items.first { $0.id == session.id }?.state, .queued, "iOS's session carries on with its own")
    }

    // MARK: D4, a failed file queued again

    func testWhatAFailedFileHasCarriesOnWhenItFits() {
        var f = item("f.mkv", state: .failed)
        f.ranges = true
        f.chunks = [DownloadChunk(start: 0, end: 49, current: 50), DownloadChunk(start: 50, end: 99, current: 70)]
        XCTAssertTrue(DownloadManager.carriesOn(f, expected: 100, partialExists: true))
        XCTAssertTrue(DownloadManager.carriesOn(f, expected: 0, partialExists: true), "size not known now")
        XCTAssertFalse(DownloadManager.carriesOn(f, expected: 120, partialExists: true), "another file on the server")
        XCTAssertFalse(DownloadManager.carriesOn(f, expected: 100, partialExists: false), "its file is gone")
        var single = f
        single.ranges = nil
        XCTAssertFalse(DownloadManager.carriesOn(single, expected: 100, partialExists: true), "no byte ranges: from the start")
        var gap = f
        gap.chunks = [DownloadChunk(start: 0, end: 49, current: 50)]
        XCTAssertFalse(DownloadManager.carriesOn(gap, expected: 100, partialExists: true))

        var resume = item("r.mkv", state: .failed)
        resume.resumeFile = "x.resume"
        XCTAssertTrue(DownloadManager.carriesOn(resume, expected: 100, partialExists: false))
        var parts = item("p.mkv", state: .failed)
        parts.parts = [DownloadPart(start: 0, end: 49, received: 50, done: true), DownloadPart(start: 50, end: 99)]
        XCTAssertTrue(DownloadManager.carriesOn(parts, expected: 100, partialExists: false))
        parts.parts = [DownloadPart(start: 0, end: 49), DownloadPart(start: 50, end: 99)]
        XCTAssertFalse(DownloadManager.carriesOn(parts, expected: 100, partialExists: false))
    }

    private func failedWithFile(_ url: URL, ranges: Bool) throws -> DownloadItem {
        var f = item("again.mkv", state: .failed, url: url)
        f.error = "Server returned HTTP 500"
        f.retries = 3
        if ranges {
            f.ranges = true
            f.chunks = [DownloadChunk(start: 0, end: 99, current: 40)]
            f.received = 40
        }
        let file = DownloadManager.inAppFile(f.id)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 40).write(to: file)
        return f
    }

    /// Queued again (an addon stream asked for once more): the same download, from where it was.
    func testAFailedFileQueuedAgainCarriesOnInPlace() throws {
        setDefault(SettingsKey.downloadAutoStart, false)       // nothing starts in the test
        setDefault(SettingsKey.downloadNotify, false)
        let dm = DownloadManager.shared
        let url = URL(string: "https://stream.example.invalid/\(UUID().uuidString)/again.mkv")!
        let old = try failedWithFile(url, ranges: true)
        madeIDs.append(old.id)
        dm.insertForTests([old])
        XCTAssertTrue(dm.enqueue(stream: url, fileName: "again.mkv", package: "Fixes1306", expected: 100, headers: [:]))
        let now = dm.items.filter { $0.url == url }
        XCTAssertEqual(now.count, 1)
        let it = try XCTUnwrap(now.first)
        XCTAssertEqual(it.id, old.id, "the same download")
        XCTAssertEqual(it.chunks, old.chunks, "its ranges kept")
        XCTAssertNil(it.error)
        XCTAssertEqual(it.retries, 0)
        XCTAssertEqual(it.state, .paused, "Start automatically off, as for a new one")
        XCTAssertTrue(FileManager.default.fileExists(atPath: DownloadManager.inAppFile(old.id).path))
    }

    /// Nothing to carry on from: the new download starts clean, and the old one's file goes.
    func testAFailedFileThatCantCarryOnLeavesNoFileBehind() throws {
        setDefault(SettingsKey.downloadAutoStart, false)
        setDefault(SettingsKey.downloadNotify, false)
        let dm = DownloadManager.shared
        let url = URL(string: "https://stream.example.invalid/\(UUID().uuidString)/again.mkv")!
        let old = try failedWithFile(url, ranges: false)
        madeIDs.append(old.id)
        dm.insertForTests([old])
        XCTAssertTrue(dm.enqueue(stream: url, fileName: "again.mkv", package: "Fixes1306", expected: 100, headers: [:]))
        let now = dm.items.filter { $0.url == url }
        XCTAssertEqual(now.count, 1)
        let it = try XCTUnwrap(now.first)
        madeIDs.append(it.id)
        XCTAssertNotEqual(it.id, old.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: DownloadManager.inAppFile(old.id).path), "its file in progress deleted")
    }

    func testTheLaunchSweepJudgesOnlyFilesOfDownloadsNotListed() {
        let kept = UUID(), gone = UUID()
        let k = kept.uuidString, g = gone.uuidString
        let names = ["\(k).download", "\(k).2.part", "\(k).resume", k.lowercased() + ".download",
                     "\(g).download", "\(g).0.part", "\(g).part", "\(g).3.resume", g,
                     ".DS_Store", "notes.txt", "\(g)x.download", String(g.prefix(30)) + ".part"]
        XCTAssertEqual(Set(DownloadManager.orphans(names, keeping: [kept])),
                       ["\(g).download", "\(g).0.part", "\(g).part", "\(g).3.resume", g])
        XCTAssertTrue(DownloadManager.orphans(names.filter { $0.hasPrefix(k) || $0.hasPrefix(k.lowercased()) }, keeping: [kept]).isEmpty)
    }

    // MARK: D6, a server error or a page from the address a link led to

    func testAServerErrorOrAPageFromTheAddressGoesThroughTheLinkOnce() {
        let a = URL(string: "https://cdn.debrid.example/f.mkv")!, b = URL(string: "https://cdn2.debrid.example/f.mkv")!
        XCTAssertEqual(ChunkPlan.fault(status: 503, page: false, address: a, current: a, faultedBefore: false), .askLink)
        XCTAssertEqual(ChunkPlan.fault(status: 200, page: true, address: a, current: a, faultedBefore: false), .askLink)
        XCTAssertEqual(ChunkPlan.fault(status: 500, page: false, address: a, current: a, faultedBefore: true), .stopUsingAddress, "a second time: the link only")
        XCTAssertEqual(ChunkPlan.fault(status: 502, page: false, address: a, current: b, faultedBefore: true), .askLink, "an old address: where the others are")
        XCTAssertEqual(ChunkPlan.fault(status: 503, page: false, address: nil, current: a, faultedBefore: false), .stands, "through the link: a failure as before")
        XCTAssertEqual(ChunkPlan.fault(status: 200, page: true, address: nil, current: nil, faultedBefore: false), .stands)
        XCTAssertEqual(ChunkPlan.fault(status: 416, page: false, address: a, current: a, faultedBefore: false), .stands)
        XCTAssertEqual(ChunkPlan.fault(status: 404, page: false, address: a, current: a, faultedBefore: false), .stands, "refusal's to judge")
    }

    private func random(_ count: Int) -> Data {
        var d = Data(count: count)
        d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
        return d
    }

    private func runLinked(events: Log1306, timeout: TimeInterval = 20) throws -> URL {
        ChunkedDownload.protocolClasses = [LinkStub.self]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fixes1306-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("l.download")
        let engine = ChunkedDownload(id: UUID(), request: DownloadEngine.Request(url: LinkStub.link, headers: [:], allowCellular: true, unmeteredOnly: false),
                                     file: file, fileName: "E1.mkv", chunks: [], total: nil, ranges: nil, connections: 4) { e in
            MainActor.assumeIsolated { events.add(e) }
        }
        let done = expectation(description: "ended")
        events.waiter = { e in
            if case .finished = e { done.fulfill(); return true }
            if case .failed = e { done.fulfill(); return true }
            return false
        }
        engine.start()
        wait(for: [done], timeout: timeout)
        return file
    }

    /// The address answers 503 once: that range goes through the link and the file comes in whole.
    func testAServerErrorFromTheAddressIsAskedThroughTheLink() throws {
        let data = random(16 << 20)
        LinkStub.configure(data: data, directFaults: 1, page: false)
        let events = Log1306()
        let file = try runLinked(events: events)
        XCTAssertTrue(events.finished, "events: \(events.summary)")
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertTrue(events.notes.contains { $0.contains("HTTP 503") && $0.contains("through the link again") }, "notes: \(events.notes)")
        XCTAssertGreaterThanOrEqual(LinkStub.count("link"), 2, "asked through the link again: \(LinkStub.log)")
    }

    func testAPageFromTheAddressIsAskedThroughTheLink() throws {
        let data = random(16 << 20)
        LinkStub.configure(data: data, directFaults: 1, page: true)
        let events = Log1306()
        let file = try runLinked(events: events)
        XCTAssertTrue(events.finished, "events: \(events.summary)")
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertTrue(events.notes.contains { $0.contains("a web page") }, "notes: \(events.notes)")
    }

    /// Every direct request fails: the run gives up on the address, and the file still comes in.
    func testAnAddressThatKeepsFailingIsLeftForTheRun() throws {
        let data = random(24 << 20)
        LinkStub.configure(data: data, directFaults: 1000, page: false)
        let events = Log1306()
        let file = try runLinked(events: events, timeout: 30)
        XCTAssertTrue(events.finished, "events: \(events.summary)")
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertLessThanOrEqual(LinkStub.count("direct"), 8, "not tried over and over: \(LinkStub.log)")
    }

    /// Through the link itself a server error still fails the file, as before.
    func testAServerErrorThroughTheLinkStillFails() throws {
        LinkStub.configure(data: random(1 << 20), directFaults: 0, page: false, linkFaults: true)
        let events = Log1306()
        _ = try runLinked(events: events)
        guard case .failed(let message, _)? = events.last else { return XCTFail("events: \(events.summary)") }
        XCTAssertTrue(message.contains("HTTP 503"), message)
    }

    // MARK: D7, a new mobile data setting

    func testAWaitingFileStartsAgainWithANewMobileDataSetting() {
        XCTAssertTrue(DownloadManager.waitsByOldRule(wifiOnly: false, sessionCellular: false, cellular: true), "Use mobile data turned on")
        XCTAssertTrue(DownloadManager.waitsByOldRule(wifiOnly: false, sessionCellular: true, cellular: false))
        XCTAssertFalse(DownloadManager.waitsByOldRule(wifiOnly: false, sessionCellular: true, cellular: true))
        XCTAssertFalse(DownloadManager.waitsByOldRule(wifiOnly: true, sessionCellular: false, cellular: true), "next episodes: Wi-Fi only anyway")

        func engine(cellular: Bool, unmetered: Bool) -> ChunkedDownload {
            ChunkedDownload(id: UUID(), request: DownloadEngine.Request(url: LinkStub.link, headers: [:], allowCellular: cellular, unmeteredOnly: unmetered),
                            file: FileManager.default.temporaryDirectory.appendingPathComponent("unused"), fileName: "E1.mkv",
                            chunks: [], total: nil, ranges: nil, connections: 1) { _ in }
        }
        XCTAssertTrue(engine(cellular: true, unmetered: false).allowsCellular)
        XCTAssertFalse(engine(cellular: false, unmetered: false).allowsCellular)
        XCTAssertFalse(engine(cellular: true, unmetered: true).allowsCellular)
    }

    // MARK: D8, free space kept for the files running

    func testTwoBigFilesDontBothStartOnRoomForOne() throws {
        // 5 GB free, two 3 GB files: room for the first only (the second waits: spaceVerdict).
        var owed: Int64 = 0
        XCTAssertNil(DownloadManager.spaceShortfall(remaining: 3 * gb, available: 5 * gb, reserved: owed))
        owed += 3 * gb
        let why = try XCTUnwrap(DownloadManager.spaceShortfall(remaining: 3 * gb, available: 5 * gb, reserved: owed))
        XCTAssertTrue(why.hasPrefix(ChunkPlan.noSpace), why)
        XCTAssertTrue(why.contains("for the files downloading"), why)
        XCTAssertTrue(DownloadManager.isPermanent(why))
        // Nothing kept for others: the message as before.
        let alone = try XCTUnwrap(DownloadManager.spaceShortfall(remaining: 5 * gb, available: 5 * gb))
        XCTAssertFalse(alone.contains("for the files downloading"), alone)
        XCTAssertNil(DownloadManager.spaceShortfall(remaining: 3 * gb, available: nil, reserved: owed), "not known: not held")
    }

    /// The post-fix review's case: a file with room for it alone but not
    /// beside what the running files still need stays queued (a
    /// reservation can go); only one that can't fit even alone fails.
    func testAFileThatFitsAloneWaitsForTheOthers() {
        XCTAssertEqual(DownloadManager.spaceVerdict(remaining: 3 * gb, available: 5 * gb, reserved: 0), .start)
        XCTAssertEqual(DownloadManager.spaceVerdict(remaining: 3 * gb, available: 5 * gb, reserved: 3 * gb), .wait)
        guard case .hold(let why) = DownloadManager.spaceVerdict(remaining: 5 * gb, available: 5 * gb, reserved: 0) else {
            return XCTFail("a file too big even alone isn't held")
        }
        XCTAssertTrue(why.hasPrefix(ChunkPlan.noSpace), why)
        XCTAssertEqual(DownloadManager.spaceVerdict(remaining: 3 * gb, available: nil, reserved: 3 * gb), .start, "not known: started")
    }

    func testTheBytesStillToCome() {
        var d = item("r.mkv", state: .running, expected: 100)
        d.received = 30
        XCTAssertEqual(DownloadManager.remaining(d), 70)
        d.received = 120
        XCTAssertEqual(DownloadManager.remaining(d), 0)
        d.expected = 0
        XCTAssertEqual(DownloadManager.remaining(d), 0, "size not known")
    }

    // MARK: D11, D15, the pill

    func testThePillNeverSaysZeroFiles() {
        XCTAssertEqual(DownloadPillSnapshot(hasWork: true, active: 0, paused: 0, queued: 3).count, 3, "Waiting · 3 files")
        XCTAssertEqual(DownloadPillSnapshot(hasWork: true, active: 2, paused: 1, queued: 3).count, 2)
        XCTAssertEqual(DownloadPillSnapshot(hasWork: false, active: 0, paused: 2).count, 2)
        XCTAssertNil(DownloadPillSnapshot(hasWork: true, active: 0, paused: 0, queued: 0).count)
        XCTAssertNil(DownloadPillSnapshot().count)
    }

    func testThePagesRoomAgreesWithThePill() {
        let dm = DownloadManager.shared
        XCTAssertEqual(DownloadPillSnapshot.shownNow, DownloadPillSnapshot.now().shown)
        var q = item("room.mkv", state: .queued)
        q.notBefore = .distantFuture
        madeIDs.append(q.id)
        dm.insertForTests([q])
        XCTAssertTrue(DownloadPillSnapshot.shownNow)
        XCTAssertEqual(DownloadPillSnapshot.shownNow, DownloadPillSnapshot.now().shown)
        dm.pause(q.id)
        XCTAssertEqual(DownloadPillSnapshot.shownNow, DownloadPillSnapshot.now().shown)
        XCTAssertTrue(DownloadPillSnapshot.shownNow, "paused this run: the pill stays")
    }
}

/// The events an engine sent, on the main thread.
@MainActor
private final class Log1306 {
    var events: [ChunkedDownload.Event] = []
    var waiter: ((ChunkedDownload.Event) -> Bool)?

    func add(_ e: ChunkedDownload.Event) {
        events.append(e)
        if waiter?(e) == true { waiter = nil }
    }

    var last: ChunkedDownload.Event? { events.last { if case .note = $0 { return false }; if case .progress = $0 { return false }; return true } }
    var finished: Bool { events.contains { if case .finished = $0 { return true }; return false } }
    var notes: [String] { events.compactMap { if case .note(let s) = $0 { return s }; return nil } }
    var summary: String { events.map { "\($0)".prefix(120) }.joined(separator: " | ") }
}

/// A link that redirects to a CDN address, as an addon's link to a debrid
/// service's file: the CDN answers byte ranges (206), and can answer its
/// direct requests (not through the link) with HTTP 503 or a web page.
final class LinkStub: URLProtocol, @unchecked Sendable {
    static let link = URL(string: "https://link.fixes1306.invalid/play/E1.mkv")!
    static let cdn = URL(string: "https://cdn.fixes1306.invalid/files/E1.mkv")!
    private static let viaLink = "X-Fixes1306-Via-Link"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var data = Data()
    nonisolated(unsafe) private static var directFaults = 0
    nonisolated(unsafe) private static var linkFaults = false
    nonisolated(unsafe) private static var page = false
    nonisolated(unsafe) private static var seen: [String] = []

    static func configure(data: Data, directFaults: Int, page: Bool, linkFaults: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        self.data = data
        self.directFaults = directFaults
        self.page = page
        self.linkFaults = linkFaults
        seen = []
    }

    static func reset() { configure(data: Data(), directFaults: 0, page: false) }

    /// "link", "cdn via link", "direct", "fault" per request, in order.
    static var log: [String] { lock.lock(); defer { lock.unlock() }; return seen }
    static func count(_ kind: String) -> Int { log.filter { $0 == kind }.count }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == link.host || request.url?.host == cdn.host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var timer: Timer?
    private var stopped = false

    override func startLoading() {
        guard let url = request.url else { return }
        if url.host == Self.link.host {
            Self.lock.lock(); Self.seen.append("link"); Self.lock.unlock()
            var next = request
            next.url = Self.cdn
            next.setValue("1", forHTTPHeaderField: Self.viaLink)
            let moved = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": Self.cdn.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: moved)
            return
        }
        let through = request.value(forHTTPHeaderField: Self.viaLink) != nil
        Self.lock.lock()
        Self.seen.append(through ? "cdn via link" : "direct")
        let fault = through ? Self.linkFaults : Self.directFaults > 0
        if !through, fault { Self.directFaults -= 1 }
        if fault { Self.seen.append("fault") }
        let data = Self.data, page = Self.page
        Self.lock.unlock()

        if fault {
            let body = page ? Data("<html>expired</html>".utf8) : Data()
            let head = ["Content-Type": page ? "text/html" : "text/plain", "Content-Length": "\(body.count)"]
            let r = HTTPURLResponse(url: url, statusCode: page ? 200 : 503, httpVersion: "HTTP/1.1", headerFields: head)!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let total = data.count
        var start = 0, end = total - 1
        if let r = request.value(forHTTPHeaderField: "Range"), r.hasPrefix("bytes=") {
            let bounds = r.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            start = bounds.first.flatMap { Int($0) } ?? 0
            end = bounds.count > 1 ? Int(bounds[1]).map { min($0, total - 1) } ?? total - 1 : total - 1
        }
        let head = ["Content-Type": "video/x-matroska", "Content-Length": "\(max(0, end - start + 1))", "Accept-Ranges": "bytes",
                    "Content-Range": "bytes \(start)-\(end)/\(total)"]
        let r = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: head)!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        guard end >= start else { client?.urlProtocolDidFinishLoading(self); return }
        var offset = start
        let t = Timer(timeInterval: 0.004, repeats: true) { [weak self] t in
            guard let self, !self.stopped else { t.invalidate(); return }
            let count = min(64 * 1024, end + 1 - offset)
            self.client?.urlProtocol(self, didLoad: data.subdata(in: offset..<offset + count))
            offset += count
            if offset > end {
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
