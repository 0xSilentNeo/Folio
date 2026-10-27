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
    /// Where the file goes (decided when it was added).
    var destination: URL
    /// Request headers an addon asked for (1.17.0: downloads from addon streams).
    var headers: [String: String]?

    var progress: Double { expected > 0 ? min(1, Double(received) / Double(expected)) : 0 }
    var isMedia: Bool { TitleParser.isMedia(fileName) }
}

/// Downloads from WebDAV servers into Media (1.15.0, #13).
///
/// Uses a background URLSession (`URLSessionConfiguration.background`): iOS
/// carries on with the transfers while Folio is suspended and relaunches it
/// when they end. Pause keeps resume data, so a paused file continues where
/// it stopped (when the server supports byte ranges, which WebDAV servers do).
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var items: [DownloadItem] = []
    /// Total speed now (bytes per second) and the last 30 readings (sparkline).
    @Published private(set) var speed: Double = 0
    @Published private(set) var speedHistory: [Double] = Array(repeating: 0, count: 30)

    private let engine = DownloadEngine.shared
    private var lastBytes: [UUID: Int64] = [:]
    private var ticker: Timer?
    private var saveWork: DispatchWorkItem?
    private let file: URL
    private var notifiedRun = false

    var active: [DownloadItem] { items.filter { $0.state == .running } }
    var hasWork: Bool { items.contains { $0.state == .running || $0.state == .queued } }

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("downloads.json")
        if let d = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([DownloadItem].self, from: d) { items = list }

        engine.onProgress = { [weak self] id, got, total in self?.progress(id, got, total) }
        engine.onFinished = { [weak self] id, tmp in self?.finished(id, tmp) }
        engine.onFailed = { [weak self] id, msg, resume in self?.failed(id, msg, resume) }

        NotificationCenter.default.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DownloadManager.shared.conditionsChanged() }
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DownloadManager.shared.conditionsChanged() }
        }
        Task { await reattach() }
    }

    // MARK: Adding

    /// Where a file from `package` is saved (Settings → Downloads → Save to).
    static func destination(fileName: String, package: String) -> URL {
        let root = MPVFiles.mediaDir
        let perFolder = (UserDefaults.standard.string(forKey: SettingsKey.downloadSaveTo) ?? "folder") == "folder"
        let clean = package.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let dir = perFolder && !clean.isEmpty ? root.appendingPathComponent(clean, isDirectory: true) : root
        return dir.appendingPathComponent(fileName)
    }

    /// Queues files from a server folder. Matching subtitle files (same name
    /// start) come along so they load with the video.
    func enqueue(_ files: [DAVItem], server: WebDAVServer, package: String) {
        let skip = UserDefaults.standard.bool(forKey: SettingsKey.downloadSkipExisting)
        var added = 0
        for f in files where !f.isDirectory {
            if items.contains(where: { $0.url == f.url && $0.state != .failed }) { continue }
            items.removeAll { $0.url == f.url && $0.state == .failed }
            let dest = Self.destination(fileName: f.name, package: package)
            var item = DownloadItem(url: f.url, serverID: server.id, fileName: f.name, package: package,
                                    expected: f.size ?? 0, destination: dest)
            if !UserDefaults.standard.bool(forKey: SettingsKey.downloadAutoStart) { item.state = .paused }
            if skip, let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, Int64(size) == item.expected, size > 0 {
                item.state = .done; item.received = item.expected; item.finished = Date()
            }
            items.append(item)
            added += 1
        }
        guard added > 0 else { return }
        dlog("dl", "queued \(added) file(s) from \(package)")
        notifiedRun = false
        if UserDefaults.standard.bool(forKey: SettingsKey.downloadNotify) { Self.askForNotifications() }
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
        if UserDefaults.standard.bool(forKey: SettingsKey.downloadNotify) { Self.askForNotifications() }
        save()
        pump()
        return true
    }

    func item(for url: URL) -> DownloadItem? { items.last { $0.url == url } }

    // MARK: Controls

    func pause(_ id: UUID) {
        guard let i = index(id) else { return }
        switch items[i].state {
        case .running:
            items[i].state = .paused
            items[i].held = false
            Task { if let name = await engine.pause(id) { setResume(id, name) } }
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
        notifiedRun = false
        save(); pump()
    }

    func retry(_ id: UUID) { resume(id) }

    func remove(_ id: UUID, deleteFile: Bool = false) {
        guard let i = index(id) else { return }
        let item = items[i]
        if item.state == .running { Task { await engine.cancel(id) } }
        if let r = item.resumeFile { try? FileManager.default.removeItem(at: DownloadEngine.resumeDir.appendingPathComponent(r)) }
        if deleteFile, item.state == .done { LocalMediaStore.shared.delete(item.destination) }
        items.remove(at: i)
        save(); pump()
    }

    func pauseAll() { for it in items where it.state == .running || it.state == .queued { pause(it.id) } }
    func resumeAll() { for it in items where it.state == .paused { resume(it.id) } }
    func clearFinished() { items.removeAll { $0.state == .done }; save() }

    /// Cancels every download not finished yet (paused, queued, running,
    /// failed), deleting what was downloaded of them.
    func cancelUnfinished(package: String? = nil) {
        for it in items where it.state != .done && (package == nil || it.package == package) { remove(it.id) }
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

    func pausePackage(_ name: String) { for it in items where it.package == name && (it.state == .running || it.state == .queued) { pause(it.id) } }
    func resumePackage(_ name: String) { for it in items where it.package == name && (it.state == .paused || it.state == .failed) { resume(it.id) } }

    // MARK: Queue

    private var conditionsOK: Bool {
        let d = UserDefaults.standard
        if d.bool(forKey: SettingsKey.downloadPauseLowPower), ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        if d.bool(forKey: SettingsKey.downloadOnlyCharging) {
            let s = UIDevice.current.batteryState
            if s != .charging && s != .full { return false }
        }
        return true
    }

    private var maxConcurrent: Int { max(1, min(6, UserDefaults.standard.integer(forKey: SettingsKey.downloadConcurrent))) }

    /// Starts queued files up to the limit; holds running ones when Low Power
    /// Mode or "only while charging" says so.
    private func pump() {
        if !conditionsOK {
            for i in items.indices where items[i].state == .running {
                let id = items[i].id
                items[i].state = .queued
                items[i].held = true
                Task { if let name = await engine.pause(id) { setResume(id, name) } }
            }
            updateTicker(); save()
            return
        }
        var running = items.filter { $0.state == .running }.count
        for i in items.indices where running < maxConcurrent && items[i].state == .queued {
            start(i)
            running += 1
        }
        updateTicker()
        checkAllDone()
    }

    private func start(_ i: Int) {
        // (Queued files only; paused ones wait for Resume.)
        var item = items[i]
        let server = ServerStore.shared.servers.first { $0.id == item.serverID }
        var headers: [String: String] = item.headers ?? [:]
        if let auth = server?.authHeader { headers["Authorization"] = auth }
        let resume = item.resumeFile.flatMap { try? Data(contentsOf: DownloadEngine.resumeDir.appendingPathComponent($0)) }
        if resume == nil { item.received = 0 }
        item.state = .running
        item.held = false
        item.error = nil
        items[i] = item
        lastBytes[item.id] = item.received
        let cellular = UserDefaults.standard.bool(forKey: SettingsKey.downloadCellular)
        engine.start(id: item.id, url: item.url, headers: headers, resumeData: resume, allowCellular: cellular)
        dlog("dl", "start \(item.fileName)\(resume != nil ? " (resuming)" : "")")
        save()
    }

    private func conditionsChanged() { pump() }

    /// Transfers survive an app relaunch inside the background session.
    private func reattach() async {
        let live = Set(await engine.liveIDs())
        for i in items.indices where items[i].state == .running && !live.contains(items[i].id) {
            items[i].state = .queued
            items[i].held = true             // was running: start again without asking
        }
        save()
        pump()
    }

    // MARK: Engine callbacks

    private func progress(_ id: UUID, _ got: Int64, _ total: Int64?) {
        guard let i = index(id), items[i].state == .running else { return }
        items[i].received = got
        if let total, total > 0 { items[i].expected = total }
    }

    private func finished(_ id: UUID, _ tmp: URL) {
        guard let i = index(id) else { try? FileManager.default.removeItem(at: tmp); return }
        let dest = items[i].destination
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: tmp, to: dest)
            items[i].state = .done
            items[i].received = max(items[i].received, items[i].expected)
            if items[i].expected == 0, let s = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize { items[i].expected = Int64(s); items[i].received = Int64(s) }
            items[i].finished = Date()
            if let r = items[i].resumeFile { try? fm.removeItem(at: DownloadEngine.resumeDir.appendingPathComponent(r)) }
            items[i].resumeFile = nil
            dlog("dl", "done \(items[i].fileName)")
            LocalMediaStore.shared.refresh()
        } catch {
            items[i].state = .failed
            items[i].error = "Couldn't save the file: \(error.localizedDescription)"
            try? fm.removeItem(at: tmp)
        }
        save(); pump()
    }

    private func failed(_ id: UUID, _ message: String, _ resume: String?) {
        guard let i = index(id) else { return }
        if let resume { items[i].resumeFile = resume }
        let limit = UserDefaults.standard.integer(forKey: SettingsKey.downloadRetries)
        if items[i].retries < limit {
            items[i].retries += 1
            items[i].state = .queued
            items[i].held = true
            dlog("dl", "retry \(items[i].retries)/\(limit) \(items[i].fileName): \(message)")
            let delay = Double(min(30, 2 << min(items[i].retries, 4)))
            save()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.pump() }
            return
        }
        items[i].state = .failed
        items[i].error = message
        dlog("dl/error", "failed \(items[i].fileName): \(message)")
        save(); pump()
    }

    private func setResume(_ id: UUID, _ name: String) {
        guard let i = index(id) else { return }
        items[i].resumeFile = name
        save()
    }

    // MARK: Speed

    private func updateTicker() {
        let need = items.contains { $0.state == .running }
        if need, ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { DownloadManager.shared.tick() }
            }
        } else if !need, let t = ticker {
            t.invalidate(); ticker = nil
            speed = 0
            speedHistory = Array(repeating: 0, count: 30)
        }
    }

    private func tick() {
        var delta: Int64 = 0
        for it in items where it.state == .running {
            delta += max(0, it.received - (lastBytes[it.id] ?? it.received))
            lastBytes[it.id] = it.received
        }
        let now = Double(delta)
        speed = speed == 0 ? now : speed * 0.6 + now * 0.4
        speedHistory = Array((speedHistory + [speed]).suffix(30))
    }

    // MARK: Done

    private func checkAllDone() {
        guard !hasWork, !notifiedRun else { return }
        let done = items.filter { $0.state == .done && ($0.finished ?? .distantPast) > Date().addingTimeInterval(-3600) }
        guard !done.isEmpty else { return }
        notifiedRun = true
        guard UserDefaults.standard.bool(forKey: SettingsKey.downloadNotify), UIApplication.shared.applicationState != .active else { return }
        let c = UNMutableNotificationContent()
        c.title = "Downloads finished"
        c.body = done.count == 1 ? done[0].fileName : "\(done.count) files are in your library."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "downloads-done", content: c, trigger: nil))
    }

    static func askForNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: Store

    private func index(_ id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    private func save() {
        saveWork?.cancel()
        let snapshot = items, url = file
        let w = DispatchWorkItem { if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url, options: .atomic) } }
        saveWork = w
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4, execute: w)
    }
}

/// The background URLSession and its delegate (callbacks arrive on its own
/// queue and are passed to the manager on the main thread).
final class DownloadEngine: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = DownloadEngine()
    static let identifier = "dev.silentneo.glassplayer.downloads"

    static var resumeDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DownloadResume", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static var partialDir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("DownloadParts", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    var onProgress: (@MainActor (UUID, Int64, Int64?) -> Void)?
    var onFinished: (@MainActor (UUID, URL) -> Void)?
    var onFailed: (@MainActor (UUID, String, String?) -> Void)?
    /// Given by iOS when it relaunches the app for this session's events.
    var backgroundCompletionHandler: (() -> Void)?

    private let lock = NSLock()
    private var lastReport: [UUID: CFTimeInterval] = [:]

    lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        c.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    func liveIDs() async -> [UUID] {
        await session.allTasks.compactMap { t in
            guard t.state == .running || t.state == .suspended else { return nil }
            return t.taskDescription.flatMap(UUID.init(uuidString:))
        }
    }

    func start(id: UUID, url: URL, headers: [String: String], resumeData: Data?, allowCellular: Bool) {
        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var req = URLRequest(url: url)
            req.allowsCellularAccess = allowCellular
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            task = session.downloadTask(with: req)
        }
        task.taskDescription = id.uuidString
        task.resume()
    }

    /// Stops the transfer, keeping resume data; returns its file name.
    func pause(_ id: UUID) async -> String? {
        let tasks = await session.allTasks
        guard let t = tasks.first(where: { $0.taskDescription == id.uuidString }) as? URLSessionDownloadTask else { return nil }
        let data: Data? = await withCheckedContinuation { c in t.cancel(byProducingResumeData: { c.resume(returning: $0) }) }
        guard let data else { return nil }
        return Self.store(data, id)
    }

    func cancel(_ id: UUID) async {
        await session.allTasks.filter { $0.taskDescription == id.uuidString }.forEach { $0.cancel() }
    }

    private static func store(_ data: Data, _ id: UUID) -> String? {
        let name = id.uuidString + ".resume"
        do { try data.write(to: resumeDir.appendingPathComponent(name), options: .atomic); return name } catch { return nil }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let now = CACurrentMediaTime()
        lock.lock()
        let report = now - (lastReport[id] ?? 0) > 0.4
        if report { lastReport[id] = now }
        lock.unlock()
        guard report else { return }
        let total: Int64? = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onProgress?(id, totalBytesWritten, total) } }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let msg = http.statusCode == 401 ? "Wrong username or password (HTTP 401)" : "Server returned HTTP \(http.statusCode)"
            DispatchQueue.main.async { MainActor.assumeIsolated { self.onFailed?(id, msg, nil) } }
            return
        }
        // The temporary file is deleted when this method returns: move it now.
        let part = Self.partialDir.appendingPathComponent(id.uuidString + ".part")
        try? FileManager.default.removeItem(at: part)
        do {
            try FileManager.default.moveItem(at: location, to: part)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.onFinished?(id, part) } }
        } catch {
            let msg = error.localizedDescription
            DispatchQueue.main.async { MainActor.assumeIsolated { self.onFailed?(id, msg, nil) } }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let ns = error as NSError
        // Our own pause / cancel.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        var resume: String?
        if let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data { resume = Self.store(data, id) }
        let msg = error.localizedDescription
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onFailed?(id, msg, resume) } }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}
