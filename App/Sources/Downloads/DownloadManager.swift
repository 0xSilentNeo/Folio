import Foundation
import UIKit
import UserNotifications

/// One file being downloaded from a WebDAV server into the library.
struct DownloadItem: Codable, Identifiable, Hashable {
    enum State: String, Codable { case queued, running, paused, done, failed }

    var id = UUID()
    var url: URL
    var serverID: UUID?
    var fileName: String
    /// The server folder it came from: one card per package on the Downloads
    /// screen, and (by default) its folder in the library.
    var package: String
    var expected: Int64
    var received: Int64 = 0
    var state: State = .queued
    var error: String?
    var resumeFile: String?
    var retries = 0
    var added = Date()
    var finished: Date?
    /// Paused by the app (Low Power Mode, not charging), not by you: starts
    /// again by itself when that ends.
    var held = false
    /// Where the file goes (decided when it was added). Saved inside
    /// Documents ("Media/Show/E1.mkv", 1.22.1): iOS moves the app's
    /// container on an update or a reinstall, and a whole path saved before
    /// pointed into the old one, where the finished file couldn't be saved
    /// ("You don't have permission to save the file", 4 Nov report).
    var destination: URL
    /// Request headers an addon asked for (1.17.0: downloads from addon streams).
    var headers: [String: String]?
    /// A retry waits until then (1.20.3). Until then the wait was only a
    /// delayed queue run, and any other run (another file finishing) started
    /// it at once.
    var notBefore: Date?
    /// Queued by "Download next episodes" (1.22.0): only over Wi-Fi that
    /// isn't metered or in Low Data Mode, whatever "Use mobile data" says.
    var wifiOnly: Bool?
    /// Byte ranges downloading side by side (1.22.1, Settings → Downloads →
    /// Connections per file); nil: one connection. iOS's background session
    /// only: since 1.22.3 a new download goes to `chunks`.
    var parts: [DownloadPart]?
    /// The server didn't answer a byte range: one connection for this file.
    var singleOnly: Bool?
    /// The byte ranges of a file downloading in Folio itself (1.22.3), as
    /// they are on disk: where a pause or a relaunch carries on from.
    var chunks: [DownloadChunk]?
    /// The server answered a byte range (HTTP 206): the file resumes and splits.
    var ranges: Bool?
    /// Started in iOS's background session because iOS wouldn't run its
    /// continued task for Folio (before iOS 26, or refused): it downloads on
    /// after Folio leaves the screen, as 1.22.2's did (1.22.3).
    var inSession: Bool?

    var progress: Double { expected > 0 ? min(1, Double(received) / Double(expected)) : 0 }
    var isMedia: Bool { TitleParser.isMedia(fileName) }
    /// In iOS's background session: started there by 1.22.2 or earlier (it
    /// has that session's parts or resume data), or because iOS wouldn't run
    /// its continued task (`inSession`). It finishes there, as it began.
    var usesSession: Bool { parts != nil || resumeFile != nil || inSession == true }
}

/// One byte range of a file downloaded over several connections (1.22.1):
/// its own background transfer with its own resume data. The parts are
/// joined into the file when all are done.
struct DownloadPart: Codable, Hashable {
    var start: Int64
    /// The last byte, included.
    var end: Int64
    var received: Int64 = 0
    var done = false
    var resumeFile: String?
    /// A retry of this part waits until then.
    var notBefore: Date?

    var length: Int64 { end - start + 1 }
}

extension DownloadItem {
    enum CodingKeys: String, CodingKey {
        case id, url, serverID, fileName, package, expected, received, state, error, resumeFile, retries, added, finished, held
        case destination, destinationPath, headers, notBefore, wifiOnly, parts, singleOnly, chunks, ranges, inSession
    }

    /// Only the address, name and destination are required: a field with a
    /// default may be missing or of another type (a list saved by another
    /// version) and the item is still read. One unreadable field used to
    /// lose the whole download list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        url = try c.decode(URL.self, forKey: .url)
        serverID = try? c.decodeIfPresent(UUID.self, forKey: .serverID)
        fileName = try c.decode(String.self, forKey: .fileName)
        package = (try? c.decodeIfPresent(String.self, forKey: .package)) ?? fileName
        expected = (try? c.decodeIfPresent(Int64.self, forKey: .expected)) ?? 0
        received = (try? c.decodeIfPresent(Int64.self, forKey: .received)) ?? 0
        state = (try? c.decodeIfPresent(State.self, forKey: .state)) ?? .paused
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        resumeFile = try? c.decodeIfPresent(String.self, forKey: .resumeFile)
        retries = (try? c.decodeIfPresent(Int.self, forKey: .retries)) ?? 0
        added = (try? c.decodeIfPresent(Date.self, forKey: .added)) ?? Date()
        finished = try? c.decodeIfPresent(Date.self, forKey: .finished)
        held = (try? c.decodeIfPresent(Bool.self, forKey: .held)) ?? false
        // 1.22.1 saves the path inside Documents; before, only the whole
        // path, which is moved onto this container's Documents.
        if let rel = try? c.decodeIfPresent(String.self, forKey: .destinationPath), let u = Self.inDocuments(rel) {
            destination = u
        } else {
            destination = Self.rebased(try c.decode(URL.self, forKey: .destination))
        }
        headers = try? c.decodeIfPresent([String: String].self, forKey: .headers)
        notBefore = try? c.decodeIfPresent(Date.self, forKey: .notBefore)
        wifiOnly = try? c.decodeIfPresent(Bool.self, forKey: .wifiOnly)
        parts = try? c.decodeIfPresent([DownloadPart].self, forKey: .parts)
        singleOnly = try? c.decodeIfPresent(Bool.self, forKey: .singleOnly)
        chunks = try? c.decodeIfPresent([DownloadChunk].self, forKey: .chunks)
        ranges = try? c.decodeIfPresent(Bool.self, forKey: .ranges)
        inSession = try? c.decodeIfPresent(Bool.self, forKey: .inSession)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(url, forKey: .url)
        try c.encodeIfPresent(serverID, forKey: .serverID)
        try c.encode(fileName, forKey: .fileName)
        try c.encode(package, forKey: .package)
        try c.encode(expected, forKey: .expected)
        try c.encode(received, forKey: .received)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(resumeFile, forKey: .resumeFile)
        try c.encode(retries, forKey: .retries)
        try c.encode(added, forKey: .added)
        try c.encodeIfPresent(finished, forKey: .finished)
        try c.encode(held, forKey: .held)
        // The whole path as well: what 1.22.0 and earlier read.
        try c.encode(destination, forKey: .destination)
        try c.encodeIfPresent(Self.documentsPath(destination.path), forKey: .destinationPath)
        try c.encodeIfPresent(headers, forKey: .headers)
        try c.encodeIfPresent(notBefore, forKey: .notBefore)
        try c.encodeIfPresent(wifiOnly, forKey: .wifiOnly)
        try c.encodeIfPresent(parts, forKey: .parts)
        try c.encodeIfPresent(singleOnly, forKey: .singleOnly)
        try c.encodeIfPresent(chunks, forKey: .chunks)
        try c.encodeIfPresent(ranges, forKey: .ranges)
        // Saved: after a relaunch a session download must not start again in Folio.
        try c.encodeIfPresent(inSession, forKey: .inSession)
    }

    // MARK: Paths

    /// A path inside an app container's Documents, as "Media/Show/E1.mkv":
    /// this container's or another one's (the install before an update).
    /// Nil outside Documents.
    static func documentsPath(_ path: String, documents: String = MPVFiles.documents.path) -> String? {
        var p = path
        if p.hasPrefix("file://"), let u = URL(string: p) { p = u.path }
        var rest: Substring?
        if p.hasPrefix(documents + "/") {
            rest = p.dropFirst(documents.count + 1)
        } else if let r = p.range(of: #"/Containers/Data/Application/[^/]+/Documents/"#, options: .regularExpression) {
            rest = p[r.upperBound...]
        }
        guard let rest, !rest.isEmpty else { return nil }
        return String(rest)
    }

    /// `path` (from documentsPath) in this container's Documents; nil for
    /// one that would leave it.
    static func inDocuments(_ path: String, documents: URL = MPVFiles.documents) -> URL? {
        let parts = path.split(separator: "/")
        guard !path.hasPrefix("/"), !parts.isEmpty, !parts.contains("..") else { return nil }
        return documents.appendingPathComponent(path)
    }

    /// A destination saved as a whole path (1.22.0 and earlier), moved onto
    /// this container's Documents. One outside any Documents stays as it is.
    static func rebased(_ url: URL, documents: URL = MPVFiles.documents) -> URL {
        guard url.isFileURL, let rel = documentsPath(url.path, documents: documents.path),
              let moved = inDocuments(rel, documents: documents) else { return url }
        return moved
    }
}

/// Downloads from WebDAV servers into Media (1.15.0, #13).
///
/// Since 1.22.3 Folio downloads a file itself, over several connections at
/// once (ChunkedDownload): iOS's background session, used until then, runs
/// transfers in iOS's download daemon, which on the 4 Nov phone report gave
/// half to a third of the Wi-Fi's speed. On iOS 26 and later the queue runs
/// as a continued processing task (SystemProgress): iOS shows its progress
/// as for Safari's downloads and Folio keeps downloading in the background.
/// Without one (older iOS, declined, ended, or its stop button), files
/// downloading in Folio carry on for the time iOS gives an app leaving the
/// screen, then pause where they are and start again when Folio is back;
/// the stop button pauses them as Safari's does.
///
/// Files a version before 1.22.3 started in the background session (with
/// its resume data or parts) finish there, as they began: iOS carries on
/// with those transfers while Folio is suspended and relaunches it when
/// they end. A big one downloads in parts side by side (1.22.1), each a
/// background transfer of its own with its own resume data, joined into the
/// file off the main thread when all are done.
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var items: [DownloadItem] = []
    /// Total speed now (bytes per second) and the last 30 readings (sparkline).
    @Published private(set) var speed: Double = 0
    @Published private(set) var speedHistory: [Double] = Array(repeating: 0, count: 30)
    /// Each running file's speed (1.24.1), over the same few seconds as the
    /// total (SpeedMeter), so the Downloads list shows how the total is
    /// shared out without the numbers jumping from one reading to the next.
    @Published private(set) var itemSpeeds: [UUID: Double] = [:]
    private var itemMeters: [UUID: SpeedMeter] = [:]
    /// The speed the Live Activity estimates the time left from: 0 until it
    /// has settled (SpeedMeter, 1.22.3).
    private(set) var estimateSpeed: Double = 0

    /// No part of the background session's smaller than this (1.22.1; in
    /// Folio itself ChunkPlan.minimum).
    nonisolated static let smallestPart: Int64 = 8 * 1_048_576
    /// Files from this size download in parts in iOS's background session.
    nonisolated static let splitFrom: Int64 = 64 * 1_048_576

    private let engine = DownloadEngine.shared
    private var lastBytes: [UUID: Int64] = [:]
    private var lastTick: CFTimeInterval = 0
    /// When the background speed was last logged (once a minute, 1.27.0).
    private var lastBackgroundNote: CFTimeInterval = 0
    private var ticker: Timer?
    private var saveWork: DispatchWorkItem?
    private let file: URL
    private var notifiedRun = false
    /// Transfers handed to the engine and not ended yet, by task key.
    private var inFlight = Set<String>()
    /// Bumped each time a file starts or stops: an answer (a range check, a
    /// join) that comes back after a pause or a removal is dropped.
    private var runs: [UUID: Int] = [:]
    private var joining = Set<UUID>()
    /// When each file last started and its bytes then (the log's average speed).
    private var startedAt: [UUID: (time: Date, bytes: Int64)] = [:]
    /// Until reattach has seen which transfers still run, nothing starts:
    /// a part still downloading would be started twice.
    private var attached = false

    /// Files downloading in Folio itself (1.22.3), with the number their
    /// events carry: an event of an earlier run of the file is dropped.
    private var transfers: [UUID: (engine: ChunkedDownload, run: Int)] = [:]
    /// Asked to pause and not answered yet: their answer brings the ranges to save.
    private var stopping: [UUID: (engine: ChunkedDownload, run: Int)] = [:]
    private var engineRuns = 0
    /// Connections each in-app file runs now (the Downloads screen), and
    /// the most it ran (the log's "done" line).
    private(set) var connectionCounts: [UUID: Int] = [:]
    private var peakConnections: [UUID: Int] = [:]
    private var lastChunkSave: [UUID: Date] = [:]
    private var meter = SpeedMeter()
    /// The time iOS gives Folio when it leaves the screen with files
    /// downloading in it and no continued processing task (1.22.3).
    private var grace: UIBackgroundTaskIdentifier = .invalid
    private var graceHolding = false
    /// What iOS's own progress counts: the in-app files of this run.
    private var systemRun = Set<UUID>()

    var active: [DownloadItem] { items.filter { $0.state == .running } }
    var hasWork: Bool { items.contains { $0.state == .running || $0.state == .queued } }
    /// Files download in Folio itself: their progress comes in while Folio
    /// runs in the background too (iOS's background session's doesn't).
    var measuresInBackground: Bool { !transfers.isEmpty }
    /// Files paused in the background (no continued task) wait for Folio to
    /// be open again: the downloads Live Activity ends rather than say
    /// "waiting to retry" until then.
    var waitsForApp: Bool { !mayRunInApp && transfers.isEmpty && items.contains { $0.state == .queued && !$0.usesSession } }

    /// The connections a running file uses now (the Downloads screen).
    func connectionCount(_ item: DownloadItem) -> Int {
        if let n = connectionCounts[item.id] { return n }
        return item.parts.map { ps in ps.filter { !$0.done }.count } ?? 0
    }

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("downloads.json")
        if let d = try? Data(contentsOf: file), let list = JSONDecoder().decodeLossy(DownloadItem.self, from: d) { items = list }

        engine.onProgress = { [weak self] key, got, total in self?.progress(key, got, total) }
        engine.onFinished = { [weak self] key, tmp in self?.taskFinished(key, tmp) }
        engine.onFailed = { [weak self] key, msg, resume, rangesIgnored in self?.taskFailed(key, msg, resume, rangesIgnored: rangesIgnored) }
        // Woken by iOS for the session's events: the bytes and speed since
        // the last look, for the Live Activity, before Folio sleeps again.
        engine.onEventsDone = { await DownloadManager.shared.catchUp(); await DownloadActivity.shared.refreshNow() }

        NotificationCenter.default.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DownloadManager.shared.conditionsChanged() }
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DownloadManager.shared.conditionsChanged() }
        }
        // Back on screen: what the transfers did while Folio was suspended,
        // and the files that paused in the background carry on (1.22.3).
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                DownloadManager.shared.becameActive()
                _ = Task<Void, Never> { @MainActor in await DownloadManager.shared.catchUp() }
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DownloadManager.shared.enteredBackground() }
        }
        SystemProgress.shared.onStop = { background in DownloadManager.shared.systemProgressStopped(background: background) }
        let moved = items.filter { $0.state != .done && !$0.destination.path.hasPrefix(MPVFiles.documents.path) }.count
        dlog("dl", "list: \(items.count) item(s), \(items.filter { $0.state == .done }.count) done"
             + (moved > 0 ? ", \(moved) saving outside this container's Documents" : ""))
        Task { await reattach() }
        // Live Activities and "Delete watched downloads" (1.22.0) read
        // `shared`: started after this init.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                LiveActivities.start()
                WatchedCleanup.start()
                DownloadManager.shared.labArguments()
            }
        }
    }

    // MARK: Adding

    /// Where a file from `package` is saved (Settings → Downloads → Save to).
    static func destination(fileName: String, package: String) -> URL {
        let fileName = safeName(fileName)
        let root = MPVFiles.mediaDir
        let perFolder = (UserDefaults.standard.string(forKey: SettingsKey.downloadSaveTo) ?? "folder") == "folder"
        let clean = package.trimmingCharacters(in: .whitespacesAndNewlines)
        // The folder's name made safe as well: a package ".." went above Media.
        let dir = perFolder && !clean.isEmpty ? root.appendingPathComponent(safeName(clean), isDirectory: true) : root
        return dir.appendingPathComponent(fileName)
    }

    /// A file or folder name from a server, made safe as one path component:
    /// no "/" or ":", no leading dots (so "../" can't climb out of Media),
    /// not empty. Until 1.20.3 a server's name went in as it was (review, 2 Nov).
    nonisolated static func safeName(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "download" : s
    }

    /// The package (and Media folder) for files from a server folder: its
    /// title, or, for a sub-folder with no title of its own ("Season 1",
    /// "Extras"), the release folder above it plus that name. Until 1.20.3
    /// two shows' "Season 1" folders became one package and one Media
    /// folder, and same-named episodes replaced each other (review, 2 Nov).
    nonisolated static func packageName(folder url: URL, title: String) -> String {
        let own = url.lastPathComponent
        let subFolder = #"(?i)^((season|series|s)[\s._-]*\d{1,2}|specials?|extras?|featurettes?|bonus|subs?|subtitles|disc[\s._-]*\d+|cd[\s._-]*\d+)$"#
        guard own.range(of: subFolder, options: .regularExpression) != nil else { return title }
        let parent = url.deletingLastPathComponent()
        guard parent.path.count > 1 else { return title }
        let name = parent.lastPathComponent
        return "\(ReleaseName.folder(name)?.title ?? name) – \(title)"
    }

    /// Queues files from a server folder. Matching subtitle files (same name
    /// start) come along so they load with the video. `auto`: "Download
    /// next episodes" (AutoDownload), which starts them whatever "Start
    /// automatically" says (it was asked for) and on Wi-Fi only.
    func enqueue(_ files: [DAVItem], server: WebDAVServer, package: String, auto: Bool = false) {
        let skip = UserDefaults.standard.bool(forKey: SettingsKey.downloadSkipExisting)
        var added = 0, skipped = 0
        for f in files where !f.isDirectory {
            items.removeAll { $0.url == f.url && Self.isGone($0) }
            if items.contains(where: { $0.url == f.url && $0.state != .failed }) { continue }
            items.removeAll { $0.url == f.url && $0.state == .failed }
            let dest = Self.destination(fileName: f.name, package: package)
            var item = DownloadItem(url: f.url, serverID: server.id, fileName: f.name, package: package,
                                    expected: f.size ?? 0, destination: dest)
            if auto { item.wifiOnly = true }
            if !auto, !UserDefaults.standard.bool(forKey: SettingsKey.downloadAutoStart) { item.state = .paused }
            if skip, let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, Int64(size) == item.expected, size > 0 {
                item.state = .done; item.received = item.expected; item.finished = Date()
                skipped += 1
            }
            items.append(item)
            added += 1
        }
        guard added > 0 else { return }
        dlog("dl", "queued \(added) file(s) from \(package)\(auto ? " (next episodes)" : "")\(skipped > 0 ? ", \(skipped) already in the library" : "")")
        notifiedRun = false
        SystemProgress.shared.userStarted()
        // Not over the player for an automatic one: it asks when you tap Download.
        if !auto, UserDefaults.standard.bool(forKey: SettingsKey.downloadNotify) { Self.askForNotifications() }
        save()
        pump()
    }

    /// An addon stream (1.17.0): one file from its link, debrid links included
    /// (redirects are followed). Goes to Media/<title>/ like WebDAV downloads.
    /// Returns false when that link is already in the list.
    @discardableResult
    func enqueue(stream url: URL, fileName: String, package: String, expected: Int64, headers: [String: String]) -> Bool {
        if items.contains(where: { $0.url == url && $0.state != .failed }) { return false }
        items.removeAll { $0.url == url && $0.state == .failed }
        var item = DownloadItem(url: url, serverID: nil, fileName: fileName, package: package, expected: expected,
                                destination: Self.destination(fileName: fileName, package: package))
        item.headers = headers.isEmpty ? nil : headers
        if !UserDefaults.standard.bool(forKey: SettingsKey.downloadAutoStart) { item.state = .paused }
        items.append(item)
        dlog("dl", "queued addon stream \(fileName) → \(package)")
        notifiedRun = false
        SystemProgress.shared.userStarted()
        if UserDefaults.standard.bool(forKey: SettingsKey.downloadNotify) { Self.askForNotifications() }
        save()
        pump()
        return true
    }

    func item(for url: URL) -> DownloadItem? { items.last { $0.url == url && !Self.isGone($0) } }

    /// A finished download whose file was deleted since (from the library or
    /// in Files). Until 1.20.3 it still showed as downloaded, with nothing to
    /// play, and the file couldn't be downloaded again (review, 2 Nov).
    private static func isGone(_ it: DownloadItem) -> Bool {
        it.state == .done && !FileManager.default.fileExists(atPath: it.destination.path)
    }

    /// Forgets finished downloads whose files are gone (LocalMediaStore.delete).
    func forgetDeleted() {
        let before = items.count
        items.removeAll(where: Self.isGone)
        if items.count != before { dlog("downloads", "forgot \(before - items.count) finished download(s) whose files were deleted"); save() }
        DownloadLedger.prune()
    }

    // MARK: Controls

    func pause(_ id: UUID) {
        guard let i = index(id) else { return }
        switch items[i].state {
        case .running:
            items[i].state = .paused
            items[i].held = false
            dlog("dl", "pause \(items[i].fileName) at \(items[i].received.byteString)")
            halt(id)
        case .queued:
            items[i].state = .paused
            items[i].held = false
        default: return
        }
        save(); pump()
    }

    func resume(_ id: UUID) {
        guard let i = index(id), items[i].state == .paused || items[i].state == .failed else { return }
        if items[i].state == .failed { items[i].retries = 0 }
        items[i].state = .queued
        items[i].error = nil
        items[i].held = false
        items[i].notBefore = nil
        if let parts = items[i].parts { items[i].parts = parts.map { var p = $0; p.notBefore = nil; return p } }
        notifiedRun = false
        SystemProgress.shared.userStarted()
        save(); pump()
    }

    func retry(_ id: UUID) { resume(id) }

    func remove(_ id: UUID, deleteFile: Bool = false) {
        guard let i = index(id) else { return }
        let item = items[i]
        // Off the list first, by id, before anything else can change it:
        // deleting the file calls forgetDeleted, which takes this item off
        // too, and the index looked up above was then removed again: out of
        // range for the last item, another download's otherwise (4 Nov crash).
        items.remove(at: i)
        // In Folio: stopped and its file deleted on its own queue, after its last write.
        transfers[id]?.engine.cancel(deleting: true)
        stopping[id]?.engine.cancel(deleting: true)
        forgetRun(id)
        if item.state == .running || item.parts != nil { Task { await engine.cancel(id) } }
        removeFiles(of: item)
        if deleteFile, item.state == .done { LocalMediaStore.shared.delete(item.destination) }
        save(); pump()
    }

    /// Several at once without starting the queued ones in between (1.25.0:
    /// pausing a running file freed its slot, so `pump` started a queued one
    /// that was paused a moment later, opening its connections for nothing).
    private var batching = false
    private func batch(_ work: () -> Void) {
        batching = true
        work()
        batching = false
        pump()
    }

    func pauseAll() { batch { for it in items where it.state == .running || it.state == .queued { pause(it.id) } } }
    func resumeAll() { batch { for it in items where it.state == .paused { resume(it.id) } } }
    func clearFinished() { items.removeAll { $0.state == .done }; save() }

    /// Cancels every download not finished yet (paused, queued, running,
    /// failed), deleting what was downloaded of them.
    func cancelUnfinished(package: String? = nil) {
        batch { for it in items where it.state != .done && (package == nil || it.package == package) { remove(it.id) } }
    }
    /// A removed server's unfinished downloads (finished files stay).
    func cancelUnfinished(server: UUID) {
        batch { for it in items where it.state != .done && it.serverID == server { remove(it.id) } }
    }
    /// Finished downloads: off the list (deleteFiles: their files too).
    func removeFinished(package: String, deleteFiles: Bool) {
        for it in items where it.state == .done && it.package == package { remove(it.id, deleteFile: deleteFiles) }
    }

    /// Lab (-uiTestDownloads): two paused downloads and a finished one.
    func labSeed() {
        guard !items.contains(where: { $0.package == "Lab Package" }) else { return }
        let dir = MPVFiles.mediaDir
        for (n, state) in [("Lab Ep 1.mkv", DownloadItem.State.paused), ("Lab Ep 2.mkv", .paused), ("Lab Ep 3.mkv", .done)] {
            var d = DownloadItem(url: URL(string: "https://example.invalid/lab/\(n.replacingOccurrences(of: " ", with: "%20"))")!, fileName: n,
                                 package: "Lab Package", expected: 50_000_000, destination: dir.appendingPathComponent(n))
            d.state = state
            d.received = state == .done ? 50_000_000 : 12_000_000
            items.append(d)
        }
    }

    /// Lab: `-labDownloadURL=<link>` queues that link as a stream download
    /// (a local test server, to measure speed and parts in the simulator).
    private func labArguments() {
        // `-labDownloadsDone=N` (1.24.1): a package of N finished files, as a
        // season downloaded earlier, to check the list with many rows.
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("-labDownloadsDone=") }), let n = Int(arg.dropFirst("-labDownloadsDone=".count)),
           !items.contains(where: { $0.package == "Lab Season" }) {
            let dir = MPVFiles.mediaDir
            for e in 1...max(1, n) {
                let name = String(format: "Lab.Season.S01E%02d.1080p.WEB-DL.mkv", e)
                var d = DownloadItem(url: URL(string: "https://example.invalid/lab/\(name)")!, fileName: name,
                                     package: "Lab Season", expected: 900_000_000 + Int64(e) * 7_000_000, destination: dir.appendingPathComponent(name))
                d.state = .done
                d.received = d.expected
                d.finished = Date()
                items.append(d)
            }
        }
        for arg in CommandLine.arguments where arg.hasPrefix("-labDownloadURL=") {
            guard let url = URL(string: String(arg.dropFirst("-labDownloadURL=".count))) else { continue }
            let name = url.lastPathComponent
            if enqueue(stream: url, fileName: name, package: "Lab Downloads", expected: 0, headers: [:]) {
                dlog("dl", "lab: queued \(name) from \(url.host ?? "?")")
            }
        }
    }

    /// Tests (DownloadRemoveTests): items put in the list as they are; nothing starts.
    func insertForTests(_ list: [DownloadItem]) { items.append(contentsOf: list) }

    func pausePackage(_ name: String) { batch { for it in items where it.package == name && (it.state == .running || it.state == .queued) { pause(it.id) } } }
    func resumePackage(_ name: String) { batch { for it in items where it.package == name && (it.state == .paused || it.state == .failed) { resume(it.id) } } }

    // MARK: Queue

    /// Low Power Mode and "Only while charging" allow downloads now (also
    /// read by the downloads Live Activity).
    var conditionsOK: Bool {
        let d = UserDefaults.standard
        if d.bool(forKey: SettingsKey.downloadPauseLowPower), ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        if d.bool(forKey: SettingsKey.downloadOnlyCharging) {
            let s = UIDevice.current.batteryState
            if s != .charging && s != .full { return false }
        }
        return true
    }

    private var maxConcurrent: Int { max(1, min(6, UserDefaults.standard.integer(forKey: SettingsKey.downloadConcurrent))) }

    /// Connections per file (Settings → Downloads), 1...8. 8 by default
    /// since 1.22.3 (4 before): on a server that caps each connection the
    /// speed grows with them (lab: 2.5, 10 and 19.9 MB/s for 1, 4 and 8).
    nonisolated static var connectionsPerFile: Int {
        let n = UserDefaults.standard.integer(forKey: SettingsKey.downloadParts)
        return max(1, min(8, n == 0 ? 8 : n))
    }

    /// Starts queued files up to the limit; holds running ones when Low Power
    /// Mode or "only while charging" says so.
    private func pump() {
        guard !batching else { return }
        if !conditionsOK {
            var held = 0
            for i in items.indices where items[i].state == .running {
                items[i].state = .queued
                items[i].held = true
                halt(items[i].id)
                held += 1
            }
            if held > 0 { dlog("dl", "holding \(held) download(s): Low Power Mode or not charging") }
            updateTicker(); save()
            return
        }
        guard attached else { updateTicker(); syncSystemProgress(); return }
        // A part waiting for its retry, or one left over by a relaunch.
        for it in items where it.state == .running && it.parts != nil { startParts(it.id) }
        // Asks for iOS's own progress before the files start, so a refusal
        // is known when each one's way of downloading is chosen (start).
        syncSystemProgress()
        var running = items.filter { $0.state == .running }.count
        let now = Date()
        let inApp = mayRunInApp
        for i in items.indices where running < maxConcurrent && items[i].state == .queued && (items[i].notBefore ?? now) <= now {
            // In Folio only on screen or as iOS's continued task: in the
            // background without one it would be suspended in seconds.
            guard inApp || items[i].usesSession else { continue }
            // Paused a moment ago and still writing: it starts once that's done.
            guard stopping[items[i].id] == nil else { continue }
            start(i)
            running += 1
        }
        updateTicker()
        syncSystemProgress()
        checkAllDone()
    }

    /// Folio may download itself now: it's on screen (or only covered, by
    /// Control Center say), or iOS runs the queue as a continued task.
    private var mayRunInApp: Bool {
        UIApplication.shared.applicationState != .background || SystemProgress.shared.isRunning
    }

    private func start(_ i: Int) {
        // (Queued files only; paused ones wait for Resume.)
        let id = items[i].id
        items[i].state = .running
        items[i].held = false
        items[i].error = nil
        items[i].notBefore = nil
        let run = (runs[id] ?? 0) + 1
        runs[id] = run
        startedAt[id] = (Date(), items[i].received)
        if items[i].parts != nil {
            dlog("dl", "start \(items[i].fileName) (iOS's background session as it began, \(items[i].parts!.count) connections, resuming at \(items[i].received.byteString))")
            startParts(id)
            lastBytes[id] = items[i].received
            save()
            return
        }
        let item = items[i]
        if let resume = Self.loadResume(item.resumeFile) {
            lastBytes[id] = item.received
            inFlight.insert(DownloadEngine.key(id, nil))
            engine.start(key: DownloadEngine.key(id, nil), request: request(for: item), range: nil, resumeData: resume)
            dlog("dl", "start \(item.fileName) (iOS's background session as it began, resuming at \(item.received.byteString))")
            save()
            return
        }
        items[i].resumeFile = nil
        // Without iOS's continued task (before iOS 26, or iOS refused it this
        // launch) a file downloading in Folio would pause a few seconds after
        // Folio leaves the screen; iOS's background session carries on, as
        // in 1.22.2, in parts where the server allows.
        if SystemProgress.shared.cannotCarry {
            startInSession(i, run: run)
        } else {
            startInApp(i)
        }
        save()
    }

    /// 1.22.2's start: iOS's background session, in parts when the server
    /// answers byte ranges (checkRanges), else over one connection.
    private func startInSession(_ i: Int, run: Int) {
        let item = items[i], id = item.id
        let ask = request(for: item)
        items[i].inSession = true
        items[i].received = 0
        lastBytes[id] = 0
        startedAt[id] = (Date(), 0)
        let n = Self.connectionsPerFile
        let why = "iOS's background session: \(SystemProgress.shared.describe)"
        if n > 1, item.singleOnly != true, item.expected == 0 || item.expected >= Self.splitFrom {
            dlog("dl", "start \(item.fileName) (\(why)): asking \(item.url.host ?? "the server") for byte ranges (\(n) connections)")
            checkRanges(id, run: run, request: ask, connections: n)
        } else {
            startSingle(id, request: ask, why: "\(why); " + (n == 1 ? "1 connection set" : item.singleOnly == true ? "no byte ranges" : "small file"))
        }
    }

    private func startSingle(_ id: UUID, request: DownloadEngine.Request, why: String) {
        guard let i = index(id) else { return }
        let key = DownloadEngine.key(id, nil)
        inFlight.insert(key)
        engine.start(key: key, request: request, range: nil, resumeData: nil)
        dlog("dl", "start \(items[i].fileName) (\(why), \(items[i].expected > 0 ? items[i].expected.byteString : "size unknown"))")
    }

    /// Asks the server for the first byte: one that answers with that byte
    /// and the file's length (HTTP 206) gets the file in parts.
    private func checkRanges(_ id: UUID, run: Int, request: DownloadEngine.Request, connections: Int) {
        // Started by the queue while Folio is in the background: a moment
        // more, so the answer comes before iOS suspends it.
        let bg = BackgroundTime("folio.download.ranges")
        let t0 = CACurrentMediaTime()
        Task {
            let answer = await DownloadEngine.checkRanges(request)
            defer { bg.end() }
            let ms = Int((CACurrentMediaTime() - t0) * 1000)
            guard let i = index(id), items[i].state == .running, runs[id] == run else { return }
            let name = items[i].fileName
            switch answer {
            case .ranges(let total, let host):
                guard total >= Self.splitFrom else {
                    items[i].expected = total
                    startSingle(id, request: request, why: "small file")
                    return
                }
                let parts = Self.split(total: total, into: connections)
                items[i].expected = total
                items[i].parts = parts
                dlog("dl", "\(host) answers byte ranges (\(ms) ms): \(name), \(total.byteString) in \(parts.count) parts")
                startParts(id)
            case .single(let why):
                items[i].singleOnly = true
                dlog("dl", "\(name): one connection, \(why) (\(ms) ms)")
                startSingle(id, request: request, why: "no byte ranges")
            case .unknown(let why):
                dlog("dl", "\(name): couldn't check for byte ranges (\(why)), one connection")
                startSingle(id, request: request, why: "range check failed")
            }
            save()
        }
    }

    /// The file downloads in Folio itself (1.22.3), from where its saved
    /// ranges say the file on disk is.
    private func startInApp(_ i: Int) {
        // Restarted in Folio (a session download that failed without resume
        // data): from now on it's an in-app download, paused on leaving.
        items[i].inSession = nil
        let item = items[i], id = item.id
        let file = Self.inAppFile(id)
        let have = FileManager.default.fileExists(atPath: file.path)
        let chunks = item.ranges == true ? ChunkPlan.resumable(item.chunks, total: item.expected > 0 ? item.expected : nil, fileExists: have) : nil
        let from = chunks.map(ChunkPlan.received) ?? 0
        items[i].chunks = chunks
        items[i].received = from
        lastBytes[id] = from
        startedAt[id] = (Date(), from)
        let n = item.singleOnly == true ? 1 : Self.connectionsPerFile
        engineRuns += 1
        let run = engineRuns
        let t = ChunkedDownload(id: id, request: request(for: item), file: file, fileName: item.fileName, chunks: chunks ?? [],
                                total: chunks != nil && item.expected > 0 ? item.expected : nil, ranges: chunks != nil ? true : nil,
                                connections: n) { event in
            MainActor.assumeIsolated { DownloadManager.shared.engineEvent(id, run, event) }
        }
        transfers[id] = (t, run)
        t.start()
        let size = item.expected > 0 ? item.expected.byteString : "size unknown"
        dlog("dl", "start \(item.fileName): in Folio, up to \(n) connection\(n == 1 ? "" : "s")"
             + (item.singleOnly == true ? " (the server sends whole files)" : "")
             + (from > 0 ? ", resuming at \(from.byteString) of \(size)" : ", \(size)") + "; \(SystemProgress.shared.describe)")
    }

    /// The one file a download in Folio writes into, until it's whole.
    nonisolated static func inAppFile(_ id: UUID) -> URL {
        DownloadEngine.partialDir.appendingPathComponent(id.uuidString + ".download")
    }

    /// `total` bytes in up to `n` parts of equal size (the last takes the
    /// rest), none under smallestPart (the background session's parts, 1.22.1).
    nonisolated static func split(total: Int64, into n: Int) -> [DownloadPart] {
        guard total > 0 else { return [] }
        let count = Int(max(1, min(Int64(max(1, n)), total / smallestPart)))
        let size = total / Int64(count)
        return (0..<count).map { k in
            let start = Int64(k) * size
            return DownloadPart(start: start, end: k == count - 1 ? total - 1 : start + size - 1)
        }
    }

    /// Starts the parts not done, not running and not waiting for a retry;
    /// joins them once all are done.
    private func startParts(_ id: UUID) {
        guard let i = index(id), items[i].state == .running, let parts = items[i].parts else { return }
        if parts.allSatisfy(\.done) {
            join(id)
            return
        }
        let ask = request(for: items[i])
        let now = Date()
        var started: [String] = []
        for (n, p) in parts.enumerated() where !p.done {
            let key = DownloadEngine.key(id, n)
            guard !inFlight.contains(key), (p.notBefore ?? now) <= now else { continue }
            let resume = Self.loadResume(p.resumeFile)
            if resume == nil { items[i].parts?[n].received = 0 }
            inFlight.insert(key)
            engine.start(key: key, request: ask, range: p.start...p.end, resumeData: resume)
            started.append("\(n + 1)\(resume != nil ? " (resuming at \(p.received.byteString))" : "")")
        }
        recount(i)
        if !started.isEmpty { dlog("dl", "\(items[i].fileName): part \(started.joined(separator: ", ")) of \(parts.count) started") }
    }

    private func request(for item: DownloadItem) -> DownloadEngine.Request {
        let server = ServerStore.shared.servers.first { $0.id == item.serverID }
        var headers: [String: String] = item.headers ?? [:]
        if let auth = server?.authHeader { headers["Authorization"] = auth }
        return DownloadEngine.Request(url: item.url, headers: headers,
                                      allowCellular: UserDefaults.standard.bool(forKey: SettingsKey.downloadCellular),
                                      unmeteredOnly: item.wifiOnly == true)
    }

    /// Stops a file's transfers, keeping their resume data (in Folio: what
    /// arrived is written, and the answer brings the ranges to save).
    private func halt(_ id: UUID) {
        guard let i = index(id) else { return }
        runs[id] = (runs[id] ?? 0) + 1
        if let t = transfers.removeValue(forKey: id) {
            stopping[id] = t
            connectionCounts[id] = nil
            t.engine.pause()
            return
        }
        let keys: [String]
        if let parts = items[i].parts {
            keys = parts.indices.filter { !parts[$0].done }.map { DownloadEngine.key(id, $0) }
        } else {
            keys = [DownloadEngine.key(id, nil)]
        }
        for k in keys { inFlight.remove(k) }
        let engine = engine
        Task {
            await withTaskGroup(of: (String, String?).self) { group in
                for k in keys { group.addTask { (k, await engine.pause(k)) } }
                for await (k, name) in group { if let name { self.setResume(k, name) } }
            }
        }
    }

    private func conditionsChanged() { pump() }

    /// Settings → Downloads changed (limit, Low Power, charging): run the
    /// queue now. Until 1.20.3 a change waited for the next battery event.
    func settingsChanged() { pump() }

    /// Transfers survive an app relaunch inside the background session.
    private func reattach() async {
        // Making the session delivers the events of transfers that ended
        // while Folio wasn't running: a moment for them before deciding
        // what still runs (a finished file started again downloaded twice).
        _ = await engine.liveKeys()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let live = Set(await engine.liveKeys())
        var again = 0
        for i in items.indices where items[i].state == .running {
            let id = items[i].id
            if let parts = items[i].parts {
                let keys = parts.indices.filter { !parts[$0].done }.map { DownloadEngine.key(id, $0) }
                let going = keys.filter(live.contains)
                inFlight.formUnion(going)
                // None left: started again with every part's resume data;
                // some: pump starts the others.
                if going.isEmpty, !keys.isEmpty { items[i].state = .queued; items[i].held = true; again += 1 }
            } else if live.contains(DownloadEngine.key(id, nil)) {
                inFlight.insert(DownloadEngine.key(id, nil))
            } else {
                items[i].state = .queued
                items[i].held = true             // was running: start again without asking
                again += 1
            }
        }
        if !live.isEmpty || again > 0 { dlog("dl", "relaunched: \(live.count) transfer(s) still going, \(again) file(s) to start again") }
        attached = true
        save()
        pump()
    }

    /// Folio runs again (back on screen, or woken by iOS for the session's
    /// events): the bytes each transfer has now, read from the transfers
    /// (a suspended app gets no progress), and the speed over that time.
    func catchUp() async {
        let now = await engine.snapshot()
        guard !now.isEmpty else { return }
        var gained: Int64 = 0
        for (key, t) in now {
            guard let (id, part) = DownloadEngine.parse(key), let i = index(id), items[i].state == .running else { continue }
            if let part, let p = items[i].parts?[safe: part], !p.done {
                let got = t.got(of: p.length)
                if got > p.received { gained += got - p.received; items[i].parts?[part].received = got }
                recount(i)
            } else if part == nil, items[i].expected > 0 {
                let got = t.got(of: items[i].expected)
                if got > items[i].received { gained += got - items[i].received; items[i].received = got }
            }
        }
        tick(force: true)
        if gained > 0 { dlog("dl", "catch-up: \(now.count) transfer(s), \(gained.byteString) more since the last look\(speed > 0 ? ", " + speedString(speed) : "")") }
    }

    /// `url`, or "name 2.ext", "name 3.ext"… when a file is already there.
    nonisolated static func freeName(for url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent(), ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        for n in 2...999 {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    // MARK: In Folio (1.22.3)

    /// What a file downloading in Folio reports. `run`: the engine's, so an
    /// answer from an earlier start of the same file is dropped; a pause's
    /// answer is taken from the engine asked to stop.
    private func engineEvent(_ id: UUID, _ run: Int, _ event: ChunkedDownload.Event) {
        let live = transfers[id]?.run == run
        let pausing = stopping[id]?.run == run
        guard live || pausing, let i = index(id) else {
            // Removed meanwhile: a file that was finished anyway goes too.
            if case .finished(let file, _) = event, index(id) == nil { try? FileManager.default.removeItem(at: file) }
            return
        }
        let name = items[i].fileName
        switch event {
        case .answered(let total, let ranges, let host):
            guard live else { return }
            if let total, total > 0 { items[i].expected = total }
            items[i].ranges = ranges
            if !ranges { items[i].singleOnly = true }
            let size = items[i].expected > 0 ? items[i].expected.byteString : "size unknown"
            let n = Self.connectionsPerFile
            dlog("dl", ranges ? "\(host) answers byte ranges: \(name), \(size), up to \(n) connection\(n == 1 ? "" : "s")"
                              : "\(host) sends the whole file (no byte ranges): \(name), \(size), one connection")
            save()
        case .progress(let received, let chunks, let n):
            guard live, items[i].state == .running else { return }
            items[i].received = received
            items[i].chunks = chunks
            connectionCounts[id] = n
            peakConnections[id] = max(peakConnections[id] ?? 0, n)
            // The ranges are what a relaunch carries on from: saved every
            // few seconds (each save writes the whole list).
            if Date().timeIntervalSince(lastChunkSave[id] ?? .distantPast) > 5 {
                lastChunkSave[id] = Date()
                save()
            }
        case .paused(let received, let chunks):
            stopping[id] = nil
            items[i].received = received
            items[i].chunks = chunks.isEmpty ? nil : chunks
            dlog("dl", "\(name): stopped at \(received.byteString), written")
            save()
            stoppedOne()
            // Resumed while it was stopping.
            if items[i].state == .queued { pump() }
        case .finished(let file, let received):
            transfers[id] = nil
            stopping[id] = nil
            items[i].received = received
            finished(id, file)
            stoppedOne()
        case .failed(let message, let chunks):
            transfers[id] = nil
            stopping[id] = nil
            connectionCounts[id] = nil
            items[i].chunks = chunks.isEmpty ? nil : chunks
            items[i].received = ChunkPlan.received(chunks)
            // Nothing to carry on from: the next try starts with an empty file.
            if chunks.isEmpty { try? FileManager.default.removeItem(at: Self.inAppFile(id)) }
            dlog("dl", "\(name) stopped: \(message) (at \(items[i].received.byteString))")
            if live { failed(id, message, nil) } else { save() }
            stoppedOne()
        case .note(let line):
            dlog("dl", "\(name): \(line)")
        }
    }

    /// A file in Folio stopped (paused, finished or failed): once the last
    /// one asked to stop has written, the time iOS gave can end.
    private func stoppedOne() {
        guard stopping.isEmpty else { return }
        // Folio may be suspended as soon as the time ends: the list is written first.
        if UIApplication.shared.applicationState == .background { saveNow() }
        if graceHolding { endGrace() }
        stopTime?.end()
        stopTime = nil
    }

    /// Folio left the screen with files downloading in it. iOS's continued
    /// task keeps it running; without one (older iOS, declined, ended, or
    /// its stop button) they carry on for the time iOS gives an app leaving
    /// the screen and then pause where they are, to start again when Folio
    /// is back. Handing their ranges to iOS's background session instead was
    /// weighed and left: a transfer created once an app is in the background
    /// is always discretionary (iOS runs it when it likes, often only on
    /// power and Wi-Fi), the bytes it fetched can't be taken back when Folio
    /// returns without dropping them, and a second path that copies ranges
    /// into the file is a second way to lose them. A pause keeps one truth:
    /// the file on disk and its ranges.
    private func enteredBackground() {
        DownloadActivity.shared.leaving()
        guard !transfers.isEmpty else { return }
        if SystemProgress.shared.isRunning {
            dlog("dl", "in the background: \(transfers.count) file(s) carry on in Folio (iOS shows the progress), \(speedString(speed))")
            return
        }
        guard grace == .invalid else { return }
        grace = UIApplication.shared.beginBackgroundTask(withName: "folio.download.grace") {
            MainActor.assumeIsolated { DownloadManager.shared.holdForApp(why: "iOS's time is up", ending: true) }
        }
        let left = UIApplication.shared.backgroundTimeRemaining
        dlog("dl", "in the background without iOS's own progress (\(SystemProgress.shared.describe)): \(transfers.count) file(s) carry on"
             + (left < 1000 ? " for about \(Int(left)) s" : "") + ", then pause until Folio is open again")
    }

    /// Each second in the background: iOS's task came after all, or the time is nearly up.
    private func checkGrace() {
        guard grace != .invalid, !graceHolding else { return }
        if SystemProgress.shared.isRunning {
            dlog("dl", "iOS's own progress started: the files carry on in the background")
            endGrace()
        } else if UIApplication.shared.backgroundTimeRemaining < 6 {
            holdForApp(why: "iOS's time in the background is nearly up", ending: false)
        }
    }

    /// The files downloading in Folio stop where they are (what arrived is
    /// written first) and wait, queued, until Folio is open again.
    private func holdForApp(why: String, ending: Bool) {
        guard !graceHolding else {
            if ending { endGrace() }
            return
        }
        graceHolding = true
        var n = 0
        for i in items.indices where items[i].state == .running && transfers[items[i].id] != nil {
            items[i].state = .queued
            items[i].held = true
            halt(items[i].id)
            n += 1
        }
        dlog("dl", "\(n) download(s) paused in the background (\(why)): they carry on when Folio is open again")
        updateTicker()
        saveNow()
        // iOS's expiry handler must end the time now; otherwise the pauses' writes come first.
        if ending || stopping.isEmpty { endGrace() }
    }

    private func endGrace() {
        graceHolding = false
        guard grace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(grace)
        grace = .invalid
    }

    /// Back on screen: the time asked for in the background isn't needed,
    /// and files that paused there start again (pump).
    private func becameActive() {
        if grace != .invalid {
            let held = items.filter { $0.state == .queued && $0.held && !$0.usesSession }.count
            if held > 0 || !transfers.isEmpty { dlog("dl", "Folio is back: \(transfers.count) running, \(held) carry on") }
        }
        endGrace()
        pump()
    }

    /// A moment in the background for the pauses' writes after iOS's progress was stopped.
    private var stopTime: BackgroundTime?

    /// iOS's own progress was stopped. In the background that's its stop
    /// button (or iOS ending the task): the files pause, to resume when you
    /// say, as Safari's downloads do. On screen iOS ended it and Folio
    /// carries on downloading; Folio's Live Activity takes over.
    private func systemProgressStopped(background: Bool) {
        guard background else { return }
        var n = 0
        if stopTime == nil { stopTime = BackgroundTime("folio.download.stop") }
        for i in items.indices where !items[i].usesSession && (items[i].state == .running || items[i].state == .queued) {
            let running = items[i].state == .running
            items[i].state = .paused
            items[i].held = false
            if running { halt(items[i].id) }
            n += 1
        }
        dlog("dl", "\(n) download(s) paused: iOS's progress was stopped")
        updateTicker()
        saveNow()
        if stopping.isEmpty { stopTime?.end(); stopTime = nil }
    }

    /// iOS's own progress for the files downloading in Folio (iOS 26).
    private func syncSystemProgress() {
        let pending = items.filter { !$0.usesSession && ($0.state == .running || $0.state == .queued) }
        let busy = conditionsOK && !pending.isEmpty
        if busy { systemRun.formUnion(pending.map(\.id)) }
        let mine = items.filter { systemRun.contains($0.id) && $0.state != .paused && $0.state != .failed }
        let total = mine.reduce(Int64(0)) { $0 + max(0, $1.expected) }
        let got = mine.reduce(Int64(0)) { $0 + ($1.state == .done ? max(0, $1.expected) : min(max(0, $1.received), max(0, $1.expected))) }
        let running = pending.filter { $0.state == .running }
        let texts = SystemProgress.texts(running: running.map { TitleParser.clean($0.fileName) }, next: pending.first.map { TitleParser.clean($0.fileName) },
                                         waiting: running.isEmpty && !pending.isEmpty, received: got, total: total,
                                         speed: running.isEmpty ? nil : speed)
        let done = !systemRun.isEmpty && systemRun.allSatisfy { id in items.first { $0.id == id }.map { $0.state == .done } ?? true }
        SystemProgress.shared.sync(.init(busy: busy, allDone: !busy && done, received: got, total: total, title: texts.title, subtitle: texts.subtitle))
        if !busy { systemRun = [] }
    }

    // MARK: Engine callbacks

    private func progress(_ key: String, _ got: Int64, _ total: Int64?) {
        guard let (id, part) = DownloadEngine.parse(key), let i = index(id), items[i].state == .running else { return }
        if let part {
            guard let p = items[i].parts?[safe: part], !p.done else { return }
            items[i].parts?[part].received = min(got, p.length)
            recount(i)
        } else {
            items[i].received = got
            if let total, total > 0 { items[i].expected = total }
        }
    }

    /// A file's bytes: its parts' (done ones in full).
    private func recount(_ i: Int) {
        guard let parts = items[i].parts else { return }
        items[i].received = parts.reduce(Int64(0)) { $0 + ($1.done ? $1.length : min($1.received, $1.length)) }
    }

    private func taskFinished(_ key: String, _ tmp: URL) {
        inFlight.remove(key)
        guard let (id, part) = DownloadEngine.parse(key), let i = index(id) else { try? FileManager.default.removeItem(at: tmp); return }
        guard let part else { finished(id, tmp); return }
        guard let p = items[i].parts?[safe: part] else { try? FileManager.default.removeItem(at: tmp); return }
        let size = Int64((try? tmp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1)
        guard size == p.length else {
            try? FileManager.default.removeItem(at: tmp)
            fallBackToOne(i, why: "part \(part + 1) came back with \(size.byteString) of \(p.length.byteString)")
            return
        }
        items[i].parts?[part].done = true
        items[i].parts?[part].received = p.length
        items[i].parts?[part].notBefore = nil
        if let r = p.resumeFile { try? FileManager.default.removeItem(at: DownloadEngine.resumeDir.appendingPathComponent(r)) }
        items[i].parts?[part].resumeFile = nil
        recount(i)
        let parts = items[i].parts ?? []
        dlog("dl", "\(items[i].fileName): part \(part + 1) of \(parts.count) done (\(parts.filter(\.done).count) done)")
        // A part finished while the file was paused is kept: it's whole.
        if items[i].state == .running, parts.allSatisfy(\.done) { join(id) }
        save()
    }

    /// All parts are in: joined into one file off the main thread, then saved like a single download.
    private func join(_ id: UUID) {
        guard let i = index(id), let parts = items[i].parts, !joining.contains(id) else { return }
        joining.insert(id)
        let lengths = parts.map(\.length), name = items[i].fileName, run = runs[id]
        // Woken in the background for the last part: time to finish the join.
        let bg = BackgroundTime("folio.download.join")
        let t0 = CACurrentMediaTime()
        Task {
            let result = await Task.detached(priority: .utility) { Result { try DownloadEngine.join(id: id, lengths: lengths) } }.value
            joining.remove(id)
            defer { bg.end() }
            switch result {
            case .success(let joined):
                dlog("dl", "joined \(lengths.count) parts of \(name) in \(Int((CACurrentMediaTime() - t0) * 1000)) ms")
                guard index(id) != nil else { try? FileManager.default.removeItem(at: joined); return }
                finished(id, joined)
            case .failure(let error):
                dlog("dl/error", "couldn't join the parts of \(name): \(error.localizedDescription)")
                guard let i = index(id), runs[id] == run else { return }
                // Parts whose files are gone download again on Retry.
                for (n, _) in parts.enumerated() where !FileManager.default.fileExists(atPath: DownloadEngine.partFile(id, n).path) {
                    items[i].parts?[n].done = false
                    items[i].parts?[n].received = 0
                }
                if items[i].parts?.allSatisfy(\.done) == true { items[i].parts = nil; Self.removePartFiles(id) }
                recount(i)
                items[i].state = .failed
                items[i].error = "Couldn't put the file together: \(error.localizedDescription)"
                save(); pump()
            }
        }
    }

    /// The server answered something else than the part asked for: the
    /// file starts again over one connection (in Folio since 1.22.3, when
    /// Folio may download: on screen or as iOS's continued task).
    private func fallBackToOne(_ i: Int, why: String) {
        let id = items[i].id
        dlog("dl", "\(items[i].fileName): \(why); one connection from the start")
        // The parts only: the whole-file transfer started below has the file's own key.
        Task { await engine.cancel(id, partsOnly: true) }
        for k in inFlight where k.hasPrefix(id.uuidString) { inFlight.remove(k) }
        Self.removePartFiles(id)
        for p in items[i].parts ?? [] { if let r = p.resumeFile { try? FileManager.default.removeItem(at: DownloadEngine.resumeDir.appendingPathComponent(r)) } }
        items[i].parts = nil
        items[i].singleOnly = true
        items[i].received = 0
        lastBytes[id] = 0
        runs[id] = (runs[id] ?? 0) + 1
        if items[i].state == .running {
            items[i].state = .queued
            items[i].held = true
        }
        save()
        pump()
    }

    private func finished(_ id: UUID, _ tmp: URL) {
        guard let i = index(id) else { try? FileManager.default.removeItem(at: tmp); return }
        var dest = items[i].destination
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            // A different file already there keeps its place: this one gets
            // " 2", " 3"… Until 1.20.3 it was deleted first, so same-named
            // files from two folders replaced each other in "Media" mode.
            dest = Self.freeName(for: dest)
            // (A rename: the parts folder and Media are on one volume.)
            try fm.moveItem(at: tmp, to: dest)
        } catch {
            let ns = error as NSError
            items[i].state = .failed
            items[i].error = "Couldn't save the file: \(error.localizedDescription)"
            dlog("dl/error", "couldn't save \(items[i].fileName) to \(DownloadItem.documentsPath(dest.path) ?? "outside Documents")"
                 + "\(dest.path.hasPrefix(MPVFiles.documents.path) ? "" : " (not this container's)"): \(ns.domain) \(ns.code) \(error.localizedDescription)")
            // The whole file downloaded in Folio stays, so Retry tries the
            // move again instead of downloading it all again (review, 5 Nov);
            // removing the download deletes it (removePartFiles).
            if tmp.standardizedFileURL != Self.inAppFile(id).standardizedFileURL { try? fm.removeItem(at: tmp) }
            save(); pump()
            return
        }
        items[i].destination = dest
        items[i].state = .done
        items[i].received = max(items[i].received, items[i].expected)
        let size = Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        if items[i].expected == 0, size > 0 { items[i].expected = size; items[i].received = size }
        items[i].finished = Date()
        if let r = items[i].resumeFile { try? fm.removeItem(at: DownloadEngine.resumeDir.appendingPathComponent(r)) }
        items[i].resumeFile = nil
        let inApp = items[i].chunks != nil || peakConnections[id] != nil
        let connections = peakConnections.removeValue(forKey: id) ?? items[i].parts?.count ?? 1
        items[i].parts = nil
        items[i].chunks = nil
        connectionCounts[id] = nil
        var took = ""
        if let t = startedAt.removeValue(forKey: id) {
            let s = max(0.001, Date().timeIntervalSince(t.time))
            let moved = max(0, size - t.bytes)
            took = t.bytes > 0 ? String(format: " (resumed: %@ in %.1f s, %@)", moved.byteString, s, speedString(Double(moved) / s))
                               : String(format: " in %.1f s, %@", s, speedString(Double(moved) / s))
        }
        dlog("dl", "done \(items[i].fileName): \(size.byteString)\(took), \(inApp ? "in Folio, up to " : "")\(connections) connection\(connections == 1 ? "" : "s")"
             + " → \(DownloadItem.documentsPath(dest.path) ?? "outside Documents")")
        // What "Delete watched downloads" may delete (1.22.0).
        DownloadLedger.add(dest)
        LocalMediaStore.shared.refresh()
        save(); pump()
    }

    private func taskFailed(_ key: String, _ message: String, _ resume: String?, rangesIgnored: Bool) {
        inFlight.remove(key)
        guard let (id, part) = DownloadEngine.parse(key), let i = index(id) else { return }
        guard let part else { failed(id, message, resume); return }
        guard let p = items[i].parts?[safe: part] else { return }
        if rangesIgnored {
            fallBackToOne(i, why: message)
            return
        }
        if let resume {
            items[i].parts?[part].resumeFile = resume
        } else if let old = p.resumeFile {
            // As for a whole file: the saved data may be what fails.
            try? FileManager.default.removeItem(at: DownloadEngine.resumeDir.appendingPathComponent(old))
            items[i].parts?[part].resumeFile = nil
        }
        // Paused or held meanwhile: kept for its resume.
        guard items[i].state == .running else { save(); return }
        let limit = UserDefaults.standard.integer(forKey: SettingsKey.downloadRetries)
        if items[i].retries < limit, !Self.isPermanent(message) {
            items[i].retries += 1
            let delay = Double(min(30, 2 << min(items[i].retries, 4)))
            items[i].parts?[part].notBefore = Date().addingTimeInterval(delay)
            dlog("dl", "retry \(items[i].retries)/\(limit) part \(part + 1) of \(items[i].fileName) in \(Int(delay)) s: \(message)")
            save()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.1) { [weak self] in self?.pump() }
            return
        }
        // The file stops; its other parts keep what they have for Retry.
        items[i].state = .failed
        items[i].error = message
        dlog("dl/error", "failed \(items[i].fileName) (part \(part + 1)): \(message)")
        halt(id)
        save(); pump()
    }

    private func failed(_ id: UUID, _ message: String, _ resume: String?) {
        guard let i = index(id) else { return }
        if let resume {
            items[i].resumeFile = resume
        } else if let old = items[i].resumeFile {
            // It failed without new resume data: the saved data may be what
            // fails (a changed login, an expired link), so the next try starts
            // afresh. Until 1.20.3 a bad resume failed every Retry for good.
            try? FileManager.default.removeItem(at: DownloadEngine.resumeDir.appendingPathComponent(old))
            items[i].resumeFile = nil
        }
        guard items[i].state == .running else { save(); return }
        let limit = UserDefaults.standard.integer(forKey: SettingsKey.downloadRetries)
        if items[i].retries < limit, !Self.isPermanent(message) {
            items[i].retries += 1
            items[i].state = .queued
            items[i].held = true
            dlog("dl", "retry \(items[i].retries)/\(limit) \(items[i].fileName): \(message)")
            let delay = Double(min(30, 2 << min(items[i].retries, 4)))
            items[i].notBefore = Date().addingTimeInterval(delay)
            save()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.pump() }
            return
        }
        items[i].state = .failed
        items[i].error = message
        dlog("dl/error", "failed \(items[i].fileName): \(message)")
        save(); pump()
    }

    /// An answer that another try won't change: a refused login, a forbidden
    /// or missing file (HTTP 401, 403, 404, 410). Until 1.20.3 these went
    /// through every retry first.
    nonisolated static func isPermanent(_ message: String) -> Bool {
        guard let r = message.range(of: #"HTTP (\d{3})"#, options: .regularExpression),
              let code = Int(message[r].dropFirst(5)) else { return false }
        return [401, 403, 404, 410].contains(code)
    }

    private func setResume(_ key: String, _ name: String) {
        guard let (id, part) = DownloadEngine.parse(key), let i = index(id) else {
            try? FileManager.default.removeItem(at: DownloadEngine.resumeDir.appendingPathComponent(name))
            return
        }
        if let part {
            guard items[i].parts?[safe: part] != nil else { return }
            items[i].parts?[part].resumeFile = name
        } else {
            items[i].resumeFile = name
        }
        save()
    }

    // MARK: Files

    private static func loadResume(_ name: String?) -> Data? {
        name.flatMap { try? Data(contentsOf: DownloadEngine.resumeDir.appendingPathComponent($0)) }
    }

    /// A removed download's resume data, parts and file in progress.
    private func removeFiles(of item: DownloadItem) {
        let fm = FileManager.default
        if let r = item.resumeFile { try? fm.removeItem(at: DownloadEngine.resumeDir.appendingPathComponent(r)) }
        for p in item.parts ?? [] { if let r = p.resumeFile { try? fm.removeItem(at: DownloadEngine.resumeDir.appendingPathComponent(r)) } }
        if item.parts != nil || item.state != .done { Self.removePartFiles(item.id) }
    }

    private static func removePartFiles(_ id: UUID) {
        let fm = FileManager.default, dir = DownloadEngine.partialDir
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(id.uuidString) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    private func forgetRun(_ id: UUID) {
        runs[id] = nil
        startedAt[id] = nil
        lastBytes[id] = nil
        transfers[id] = nil
        stopping[id] = nil
        connectionCounts[id] = nil
        peakConnections[id] = nil
        lastChunkSave[id] = nil
        systemRun.remove(id)
        for k in inFlight where k.hasPrefix(id.uuidString) { inFlight.remove(k) }
    }

    // MARK: Speed

    private func updateTicker() {
        let need = items.contains { $0.state == .running }
        if need, ticker == nil {
            lastTick = CACurrentMediaTime()
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { DownloadManager.shared.tick(force: false) }
            }
        } else if !need, let t = ticker {
            t.invalidate(); ticker = nil
            speed = 0
            estimateSpeed = 0
            meter.reset()
            speedHistory = Array(repeating: 0, count: 30)
            itemMeters = [:]
            itemSpeeds = [:]
        }
    }

    /// The bytes since the last reading, into the speed over the last few
    /// seconds (SpeedMeter): after a suspension that's the average while
    /// iOS downloaded alone (until 1.22.1 a minute's bytes counted as one
    /// second's). In the background the progress of iOS's background
    /// session doesn't reach Folio: the timer's readings there would say the
    /// speed fell to nothing, so only catchUp, which asks the transfers,
    /// reads it there. Files downloading in Folio itself report while it
    /// runs in the background as well (1.22.3).
    private func tick(force: Bool) {
        let background = UIApplication.shared.applicationState == .background
        if !force, background, transfers.isEmpty { return }
        let now = CACurrentMediaTime()
        lastTick = now
        var delta: Int64 = 0
        var meters: [UUID: SpeedMeter] = [:]
        for it in items where it.state == .running {
            let d = max(0, it.received - (lastBytes[it.id] ?? it.received))
            delta += d
            lastBytes[it.id] = it.received
            var m = itemMeters[it.id] ?? SpeedMeter()
            m.add(d, at: now)
            meters[it.id] = m
        }
        // Files no longer running drop out of the list of speeds.
        itemMeters = meters
        let perFile = meters.mapValues(\.rate)
        if perFile != itemSpeeds { itemSpeeds = perFile }
        meter.add(delta, at: now)
        speed = meter.rate
        estimateSpeed = meter.estimate(at: now)
        speedHistory = Array((speedHistory + [speed]).suffix(30))
        if background {
            checkGrace()
            // A line a minute, so a report shows how fast it went with
            // Folio away and with the phone locked (9 Nov: "locked, it more
            // than halved").
            if now - lastBackgroundNote >= 60 {
                lastBackgroundNote = now
                let running = items.filter { $0.state == .running }.count
                let locked = UIApplication.shared.isProtectedDataAvailable ? "" : ", phone locked"
                dlog("dl", "background: \(speedString(speed)), \(running) file(s), \(SystemProgress.shared.describe)\(locked)")
            }
        }
        syncSystemProgress()
    }

    // MARK: Done

    private func checkAllDone() {
        guard !hasWork, !notifiedRun else { return }
        let done = items.filter { $0.state == .done && ($0.finished ?? .distantPast) > Date().addingTimeInterval(-3600) }
        guard !done.isEmpty else { return }
        notifiedRun = true
        guard UserDefaults.standard.bool(forKey: SettingsKey.downloadNotify), NotifyPrefs.kindOn(.downloadFinished),
              UIApplication.shared.applicationState != .active else { return }
        let c = UNMutableNotificationContent()
        c.title = "Downloads finished"
        c.body = done.count == 1 ? done[0].fileName : "\(done.count) files are in your library."
        // One file, in Settings → Notifications' personality (1.25.0; an
        // episode's name as "Show S2 · E6", a film's cleaned title), each
        // time the kind's next line.
        if done.count == 1, let what = Self.downloadName(done[0].fileName), NotifyPrefs.tone != .subtle,
           let w = NotifyWording.text(.downloadFinished, NotifyPrefs.tone, ["what": what], variation: NotifyCenter.bumpVariation(.downloadFinished)) {
            c.title = w.title ?? c.title
            c.body = w.body
        }
        c.sound = NotifySounds.sound(for: .downloads)
        c.threadIdentifier = "folio.downloads"
        NotifyCenter.appendLog(.init(id: "downloads-done.\(Int(Date().timeIntervalSince1970))", kind: .downloadFinished, at: Date(),
                                     title: c.title, body: c.body, reason: "\(done.count) download\(done.count == 1 ? "" : "s") finished", test: false))
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "downloads-done", content: c, trigger: nil))
    }

    /// "Harbor Lights S2 · E6" for an episode, the cleaned title for anything else.
    static func downloadName(_ fileName: String) -> String? {
        if let w = EngagePlanner.downloadWording(fileName: fileName) { return String(w.title.dropLast(" is downloaded".count)) }
        let t = TitleParser.parse(fileName).title
        return t.isEmpty ? nil : t
    }

    static func askForNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: Store

    private func index(_ id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    /// The list written at once, not in a moment: Folio may be suspended next (1.22.3).
    private func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: file, options: .atomic) }
    }

    private func save() {
        saveWork?.cancel()
        let snapshot = items, url = file
        let w = DispatchWorkItem { if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url, options: .atomic) } }
        saveWork = w
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4, execute: w)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// A little more time when Folio may be in the background (woken by iOS
/// for a transfer): ended when the work is, or when iOS says time is up.
@MainActor
private final class BackgroundTime {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { MainActor.assumeIsolated { self.end() } }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// The background URLSession and its delegate (callbacks arrive on its own
/// queue and are passed to the manager on the main thread). A transfer is
/// known by its key: the item's id, or "id/n" for part n of a file.
final class DownloadEngine: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = DownloadEngine()
    static let identifier = (Bundle.main.bundleIdentifier ?? "dev.silentneo.folio") + ".downloads"

    struct Request: Sendable {
        var url: URL
        var headers: [String: String]
        var allowCellular: Bool
        /// Wi-Fi only, never a hotspot's or Low Data Mode's (automatic downloads).
        var unmeteredOnly: Bool
    }

    static var resumeDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DownloadResume", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    /// Finished parts until they're joined (1.22.1: Application Support, not
    /// Caches, which iOS may empty while a long download runs).
    static var partialDir: URL {
        var d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DownloadParts", isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            // Writable while the phone is locked (iOS's default for apps, said
            // here so the parts never get a stricter class, 1.27.0); files
            // made in it take the folder's class.
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                     attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var v = URLResourceValues()
            v.isExcludedFromBackup = true
            try? d.setResourceValues(v)
        }
        return d
    }

    static func key(_ id: UUID, _ part: Int?) -> String { part.map { "\(id.uuidString)/\($0)" } ?? id.uuidString }

    static func parse(_ key: String) -> (UUID, Int?)? {
        let bits = key.split(separator: "/")
        guard let first = bits.first, let id = UUID(uuidString: String(first)) else { return nil }
        if bits.count == 2, let n = Int(bits[1]), n >= 0 { return (id, n) }
        return bits.count == 1 ? (id, nil) : nil
    }

    /// A finished part's file, until the join.
    static func partFile(_ id: UUID, _ n: Int) -> URL { partialDir.appendingPathComponent("\(id.uuidString).\(n).part") }

    var onProgress: (@MainActor (String, Int64, Int64?) -> Void)?
    var onFinished: (@MainActor (String, URL) -> Void)?
    /// key, message, resume data's file, the server ignored the byte range.
    var onFailed: (@MainActor (String, String, String?, Bool) -> Void)?
    /// After the session's events were delivered to a relaunched app.
    var onEventsDone: (@MainActor () async -> Void)?
    /// Given by iOS when it relaunches the app for this session's events.
    var backgroundCompletionHandler: (() -> Void)?

    private let lock = NSLock()
    private var lastReport: [String: CFTimeInterval] = [:]
    /// Part transfers whose answer was looked at (by task identifier).
    private var checked = Set<Int>()

    lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        c.sessionSendsLaunchEvents = true
        // At once, not when iOS finds it convenient. (A transfer started
        // while Folio is in the background is left to iOS whatever this says.)
        c.isDiscretionary = false
        // Up to 8 parts of a file, two files at once: 6 per host (until
        // 1.22.1) left parts waiting for others to end.
        c.httpMaximumConnectionsPerHost = 16
        c.allowsExpensiveNetworkAccess = true
        c.allowsConstrainedNetworkAccess = true
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    func liveKeys() async -> [String] {
        await session.allTasks.compactMap { t in
            guard t.state == .running || t.state == .suspended, let key = t.taskDescription, Self.parse(key) != nil else { return nil }
            return key
        }
    }

    /// What each running transfer has received, read from the transfers.
    struct Reading: Sendable {
        var received: Int64
        var toReceive: Int64
        /// Of `length` bytes in all: a resumed transfer counts only what it
        /// fetches itself, so it's the length less what it still has to fetch.
        func got(of length: Int64) -> Int64 {
            guard toReceive > 0 else { return 0 }
            return min(length, max(0, length - max(0, toReceive - received)))
        }
    }

    func snapshot() async -> [String: Reading] {
        var out: [String: Reading] = [:]
        for t in await session.allTasks where t.state == .running {
            guard let key = t.taskDescription, Self.parse(key) != nil else { continue }
            out[key] = Reading(received: t.countOfBytesReceived, toReceive: t.countOfBytesExpectedToReceive)
        }
        return out
    }

    /// `range`: the bytes of one part (none for a whole file or a resume,
    /// whose data carries its request, range included).
    func start(key: String, request r: Request, range: ClosedRange<Int64>?, resumeData: Data?) {
        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var req = URLRequest(url: r.url)
            req.allowsCellularAccess = r.allowCellular && !r.unmeteredOnly
            if r.unmeteredOnly {
                req.allowsExpensiveNetworkAccess = false
                req.allowsConstrainedNetworkAccess = false
            }
            for (k, v) in r.headers { req.setValue(v, forHTTPHeaderField: k) }
            if let range { req.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
            task = session.downloadTask(with: req)
        }
        task.taskDescription = key
        task.resume()
    }

    /// Stops the transfer, keeping resume data; returns its file name.
    func pause(_ key: String) async -> String? {
        let tasks = await session.allTasks
        guard let t = tasks.first(where: { $0.taskDescription == key }) as? URLSessionDownloadTask else { return nil }
        let data: Data? = await withCheckedContinuation { c in t.cancel(byProducingResumeData: { c.resume(returning: $0) }) }
        guard let data else { return nil }
        return Self.store(data, key)
    }

    /// Every transfer of the file, its parts included (`partsOnly`: just those).
    func cancel(_ id: UUID, partsOnly: Bool = false) async {
        let s = id.uuidString
        await session.allTasks.filter { (!partsOnly && $0.taskDescription == s) || $0.taskDescription?.hasPrefix(s + "/") == true }.forEach { $0.cancel() }
    }

    private static func store(_ data: Data, _ key: String) -> String? {
        let name = key.replacingOccurrences(of: "/", with: ".") + ".resume"
        do { try data.write(to: resumeDir.appendingPathComponent(name), options: .atomic); return name } catch { return nil }
    }

    // MARK: Byte ranges

    enum RangeAnswer: Sendable {
        /// HTTP 206 with the file's length.
        case ranges(total: Int64, host: String)
        /// The server sends the whole file whatever is asked.
        case single(String)
        /// No answer that says (an error, a refused login): one connection,
        /// and the transfer itself reports what's wrong.
        case unknown(String)
    }

    /// The range check: no cache, no cookies, its own short timeout.
    private static let checkSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    /// Asks for the first byte and reads the answer's head only.
    static func checkRanges(_ r: Request) async -> RangeAnswer {
        var req = URLRequest(url: r.url)
        for (k, v) in r.headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        req.allowsCellularAccess = r.allowCellular && !r.unmeteredOnly
        if r.unmeteredOnly {
            req.allowsExpensiveNetworkAccess = false
            req.allowsConstrainedNetworkAccess = false
        }
        do {
            let (bytes, response) = try await checkSession.bytes(for: req)
            bytes.task.cancel()
            guard let http = response as? HTTPURLResponse else { return .unknown("not an HTTP answer") }
            let host = http.url?.host ?? "the server"
            switch http.statusCode {
            case 206:
                guard let total = totalLength(http.value(forHTTPHeaderField: "Content-Range")), total > 0 else {
                    return .single("\(host) gave no file length")
                }
                return .ranges(total: total, host: host)
            case 200: return .single("\(host) sends the whole file (HTTP 200)")
            default: return .unknown("HTTP \(http.statusCode)")
            }
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    /// "bytes 0-0/1234" → 1234.
    static func totalLength(_ contentRange: String?) -> Int64? {
        guard let s = contentRange, let r = s.range(of: #"/\s*(\d+)\s*$"#, options: .regularExpression) else { return nil }
        return Int64(s[r].dropFirst().trimmingCharacters(in: .whitespaces))
    }

    /// Joins a file's parts in order into the first one, a few MB at a time
    /// (never a whole part in memory), each part deleted once it's in.
    /// Picks up where an earlier join stopped (Folio closed meanwhile): the
    /// parts still there are those not in yet. Returns the file.
    static func join(id: UUID, lengths: [Int64], in dir: URL = partialDir) throws -> URL {
        let fm = FileManager.default
        func part(_ n: Int) -> URL { dir.appendingPathComponent("\(id.uuidString).\(n).part") }
        func size(_ u: URL) -> Int64 { Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1) }
        guard !lengths.isEmpty, fm.fileExists(atPath: part(0).path) else { throw JoinError.missing(1) }
        var next = 1
        while next < lengths.count, !fm.fileExists(atPath: part(next).path) { next += 1 }
        for n in next..<lengths.count where size(part(n)) != lengths[n] { throw JoinError.missing(n + 1) }
        let have = lengths[0..<next].reduce(0, +)
        guard size(part(0)) >= have else { throw JoinError.missing(next) }
        let out = try FileHandle(forUpdating: part(0))
        defer { try? out.close() }
        // An append cut short last time is dropped and done again.
        try out.truncate(atOffset: UInt64(have))
        try out.seekToEnd()
        for n in next..<lengths.count {
            let input = try FileHandle(forReadingFrom: part(n))
            while true {
                let chunk = try autoreleasepool { try input.read(upToCount: 4 << 20) }
                guard let chunk, !chunk.isEmpty else { break }
                try out.write(contentsOf: chunk)
            }
            try input.close()
            // On disk before the part goes: a join picked up later relies on it.
            try out.synchronize()
            try fm.removeItem(at: part(n))
        }
        let total = lengths.reduce(0, +)
        guard size(part(0)) == total else { throw JoinError.size(size(part(0)), total) }
        let joined = dir.appendingPathComponent(id.uuidString + ".part")
        try? fm.removeItem(at: joined)
        try fm.moveItem(at: part(0), to: joined)
        return joined
    }

    enum JoinError: LocalizedError {
        case missing(Int), size(Int64, Int64)
        var errorDescription: String? {
            switch self {
            case .missing(let n): return "part \(n) is missing"
            case .size(let got, let want): return "the joined file has \(got) of \(want) bytes"
            }
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription, let (_, part) = Self.parse(key) else { return }
        if part != nil {
            lock.lock()
            let first = checked.insert(downloadTask.taskIdentifier).inserted
            lock.unlock()
            // A part must come back as that range (206): a server that
            // sends the whole file instead is stopped at once.
            if first, let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 206 {
                downloadTask.cancel()
                let msg = "\(http.url?.host ?? "the server") ignored the byte range (HTTP \(http.statusCode))"
                DispatchQueue.main.async { MainActor.assumeIsolated { self.onFailed?(key, msg, nil, true) } }
                return
            }
        }
        let now = CACurrentMediaTime()
        lock.lock()
        let report = now - (lastReport[key] ?? 0) > 0.4
        if report { lastReport[key] = now }
        lock.unlock()
        guard report else { return }
        let total: Int64? = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onProgress?(key, totalBytesWritten, total) } }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription, let (id, part) = Self.parse(key) else { return }
        let http = downloadTask.response as? HTTPURLResponse
        if let http, !(200..<300).contains(http.statusCode) {
            let msg = http.statusCode == 401 ? "Wrong username or password (HTTP 401)" : "Server returned HTTP \(http.statusCode)"
            dlog("dl/error", "\(Self.label(key)): HTTP \(http.statusCode) from \(http.url?.host ?? "?")")
            DispatchQueue.main.async { MainActor.assumeIsolated { self.onFailed?(key, msg, nil, part != nil && http.statusCode == 416) } }
            return
        }
        if part != nil, let http, http.statusCode != 206 {
            let msg = "\(http.url?.host ?? "the server") ignored the byte range (HTTP \(http.statusCode))"
            DispatchQueue.main.async { MainActor.assumeIsolated { self.onFailed?(key, msg, nil, true) } }
            return
        }
        // The temporary file is deleted when this method returns: moved now,
        // on this queue, before returning.
        let target = part.map { Self.partFile(id, $0) } ?? Self.partialDir.appendingPathComponent(id.uuidString + ".part")
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.moveItem(at: location, to: target)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.onFinished?(key, target) } }
        } catch {
            let ns = error as NSError
            dlog("dl/error", "\(Self.label(key)): couldn't keep the downloaded file: \(ns.domain) \(ns.code) \(ns.localizedDescription)")
            let msg = "Couldn't keep the downloaded file: \(ns.localizedDescription)"
            DispatchQueue.main.async { MainActor.assumeIsolated { self.onFailed?(key, msg, nil, false) } }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        checked.remove(task.taskIdentifier)
        lock.unlock()
        guard let error, let key = task.taskDescription, Self.parse(key) != nil else { return }
        let ns = error as NSError
        // Our own pause / cancel.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        var resume: String?
        if let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data { resume = Self.store(data, key) }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        dlog("dl", "\(Self.label(key)) stopped after \(task.countOfBytesReceived.byteString): \(ns.domain) \(ns.code)"
             + "\(status.map { ", HTTP \($0)" } ?? "")\(resume != nil ? ", resume data kept" : "")")
        let msg = error.localizedDescription
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onFailed?(key, msg, resume, false) } }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                _ = Task<Void, Never> { @MainActor in
                    await self.onEventsDone?()
                    self.backgroundCompletionHandler?()
                    self.backgroundCompletionHandler = nil
                }
            }
        }
    }

    /// A key as logged: "file" or "part 3" (no addresses: they can carry a login or a token).
    private static func label(_ key: String) -> String {
        guard let (id, part) = parse(key) else { return "transfer" }
        let short = id.uuidString.prefix(8)
        return part.map { "\(short) part \($0 + 1)" } ?? "\(short)"
    }
}
