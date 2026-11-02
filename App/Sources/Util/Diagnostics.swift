import Foundation
import UIKit
import MetricKit
import Darwin

/// App-side diagnostics: a rolling text log, crash/hang capture and a
/// shareable report. Credentials are redacted before anything is written.
///
/// Files (Application Support/diagnostics):
///   app.log        rolling log of what the app did (opens, errors, timings)
///   crash.log      last uncaught exception / signal with a backtrace
///   hangs.log      main-thread stalls over 1 s with the stack at the time
///   metrickit.log  crash/hang diagnostics delivered by iOS (next launch)
final class Diagnostics: NSObject {
    static let shared = Diagnostics()

    let dir: URL
    private let queue = DispatchQueue(label: "folio.diag", qos: .utility)
    private var handle: FileHandle?
    private let maxBytes = 2_000_000
    private var watchdog: Thread?
    private let heartbeatLock = NSLock()
    private var lastHeartbeat = Date()
    private var hangReported = false
    private var isActive = true
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    override private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        super.init()
    }

    var appLog: URL { dir.appendingPathComponent("app.log") }
    var crashLog: URL { dir.appendingPathComponent("crash.log") }
    var hangLog: URL { dir.appendingPathComponent("hangs.log") }
    var metricLog: URL { dir.appendingPathComponent("metrickit.log") }

    // MARK: Start

    func start() {
        rotateIfNeeded()
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        log("app", "launch v\(v) (\(b)) iOS \(UIDevice.current.systemVersion) \(Self.model()) free=\(Self.freeDisk())")
        if let last = try? String(contentsOf: crashLog, encoding: .utf8), !last.isEmpty, !last.hasPrefix("[reported]") {
            log("app", "previous session ended with a crash (see crash.log)")
            try? ("[reported]\n" + last).write(to: crashLog, atomically: true, encoding: .utf8)
        }
        installCrashHandlers()
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.heartbeatLock.lock(); self?.isActive = true; self?.lastHeartbeat = Date(); self?.heartbeatLock.unlock()
            self?.log("app", "active")
        }
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.heartbeatLock.lock(); self?.isActive = false; self?.heartbeatLock.unlock()
            self?.log("app", "resign active")
        }
        nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            self?.log("app/warn", "memory warning: \(EnergyMonitor.memory)")
        }
        startWatchdog()
        MXMetricManager.shared.add(self)
    }

    // MARK: Logging

    /// Filtering (redact) runs on the log's own queue, not the caller's thread
    /// (usually main). Writes use the throwing API: the old `write(_:)` raised an
    /// Objective-C exception on a full disk and ended the app (review, 2 Nov).
    /// The log moves to app.previous.log once it passes `maxBytes` within a
    /// session too, not only at launch.
    func log(_ tag: String, _ message: String) {
        let stamp = Self.fmt.string(from: Date())
        queue.async { [self] in
            let line = "\(stamp) [\(tag)] \(Self.redact(message))\n"
            if handle == nil {
                if !FileManager.default.fileExists(atPath: appLog.path) { FileManager.default.createFile(atPath: appLog.path, contents: nil) }
                handle = try? FileHandle(forWritingTo: appLog)
                written = Int((try? handle?.seekToEnd()) ?? 0)
            }
            let data = Data(line.utf8)
            try? handle?.write(contentsOf: data)
            written += data.count
            if written > maxBytes {
                try? handle?.close()
                handle = nil
                rotateIfNeeded()
            }
            #if DEBUG
            print(line, terminator: "")
            #endif
        }
    }
    private var written = 0

    /// Settings → Diagnostics → Clear logs. Until 1.20.3 the button deleted
    /// app.log while this kept writing to the deleted file through its open
    /// handle, so the session had no log until the next launch, and the older
    /// logs and PiP pictures still went into the next report (review, 2 Nov).
    func clearLogs() {
        queue.sync {
            try? handle?.close()
            handle = nil
            written = 0
            let fm = FileManager.default
            for f in [appLog, hangLog, metricLog, crashLog, dir.appendingPathComponent("app.previous.log")] { try? fm.removeItem(at: f) }
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.lastPathComponent.hasPrefix("pip-ui-") {
                try? fm.removeItem(at: f)
            }
        }
        log("app", "logs cleared")
    }

    func error(_ tag: String, _ message: String) { log(tag + "/error", message) }

    /// Measures a block and logs it when it takes longer than `warnAbove`.
    func time<T>(_ tag: String, _ what: String, warnAbove: Double = 0.05, _ body: () throws -> T) rethrows -> T {
        let t0 = CFAbsoluteTimeGetCurrent()
        defer {
            let dt = CFAbsoluteTimeGetCurrent() - t0
            if dt > warnAbove { log(tag + "/slow", String(format: "%@ took %.0f ms%@", what, dt * 1000, Thread.isMainThread ? " on main" : "")) }
        }
        return try body()
    }

    private func rotateIfNeeded() {
        guard let size = try? FileManager.default.attributesOfItem(atPath: appLog.path)[.size] as? Int, size > maxBytes else { return }
        let old = dir.appendingPathComponent("app.previous.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: appLog, to: old)
    }

    // MARK: Redaction

    /// Strips passwords, tokens and auth headers from anything we log.
    static func redact(_ s: String) -> String {
        var out = s
        let rules: [(String, String)] = [
            (#"(?i)(authorization\s*[:=]\s*)(basic|bearer)?\s*[A-Za-z0-9+/=._\-]{8,}"#, "$1$2 ••••"),
            (#"(?i)(password|passwd|pass|token|apikey|api_key|key|secret)=([^&\s"']+)"#, "$1=••••"),
            (#"(?i)(password|token|apikey|secret)\"?\s*:\s*\"[^\"]+\""#, "$1: \"••••\""),
            (#"://([^/\s:@]+):([^@\s/]+)@"#, "://$1:••••@"),
            (#"/dav\.real-debrid\.com/[^\s]*"#, "/dav.real-debrid.com/…"),
            (#"(?i)(config=|configuration/)[A-Za-z0-9+/=]{20,}"#, "$1••••"),
            // Addon links carry their settings in the path, base64-encoded —
            // debrid API keys included (27 Oct report: a key in a loadfile
            // line). Any long base64 path segment is hidden.
            (#"/[A-Za-z0-9+_\-]{40,}={0,2}(?=[/?#\s"]|$)"#, "/••••"),
            // …or in plain text, Torrentio style ("sort=size|realdebrid=KEY"),
            // which the rule above missed: a "|" and "=" break the segment
            // (review, 31 Oct). Any setting with a long key-like value goes.
            (#"(?i)(\b|%7C)(realdebrid|alldebrid|premiumize|debridlink|torbox|offcloud|putio|easydebrid|pikpak|stremthru)=([^|&/\s"'%]+)"#, "$1$2=••••"),
            (#"(?i)/(realdebrid|alldebrid|premiumize|debridlink|torbox|offcloud|putio|easydebrid|pikpak)/([A-Za-z0-9_\-]{12,})(?=[/?#\s"]|$)"#, "/$1/••••"),
            // \b: without it the engine retries the name at every offset of
            // a long run (20 000 characters: 3.7 s; with it, about 1 ms).
            (#"\b([A-Za-z0-9_]+)=([A-Za-z0-9_\-]{24,})"#, "$1=••••"),
            (#"(?i)(x-api-key|api-key|x-auth-token)(\s*[:=]\s*)\S+"#, "$1$2••••"),
        ]
        for (p, r) in rules {
            out = out.replacingOccurrences(of: p, with: r, options: .regularExpression)
        }
        return out
    }

    // MARK: Crash capture

    private func installCrashHandlers() {
        Self.crashLogPath = strdup(crashLog.path)
        Self.signalLine = strdup("\nsignal 00\n")
        Self.frames = .allocate(capacity: 128)
        NSSetUncaughtExceptionHandler { exc in
            let text = "Uncaught exception: \(exc.name.rawValue): \(exc.reason ?? "")\n" + exc.callStackSymbols.joined(separator: "\n")
            Diagnostics.writeCrash(text)
        }
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig) { s in
                Diagnostics.writeSignalCrash(s)
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }

    private static var crashLogPath: UnsafeMutablePointer<CChar>?
    /// Made at install, so the signal handler allocates nothing.
    private static var signalLine: UnsafeMutablePointer<CChar>?
    private static var frames: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
    /// An uncaught exception is followed by abort(), whose signal handler
    /// used to open crash.log afresh and replace the exception's name and
    /// reason with a bare backtrace: the 1 Nov report's crash.log says only
    /// "signal 05". The backtrace now goes after the exception.
    private static var exceptionWritten = false

    private static func writeCrash(_ text: String) {
        guard let p = crashLogPath else { return }
        let fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return }
        let header = "time \(Date())\n"
        _ = header.withCString { write(fd, $0, strlen($0)) }
        _ = text.withCString { write(fd, $0, strlen($0)) }
        close(fd)
        exceptionWritten = true
    }

    /// Async-signal-safe: only write(2)/backtrace, no allocation.
    private static func writeSignalCrash(_ sig: Int32) {
        guard let p = crashLogPath, let line = signalLine, let frames else { return }
        let fd = open(p, O_WRONLY | O_CREAT | (exceptionWritten ? O_APPEND : O_TRUNC), 0o644)
        guard fd >= 0 else { return }
        line[8] = CChar(48 + (sig / 10)); line[9] = CChar(48 + (sig % 10))
        _ = write(fd, line, 11)
        let n = backtrace(frames, 128)
        backtrace_symbols_fd(frames, n, fd)
        close(fd)
    }

    // MARK: Hang watchdog (main thread stalls)

    func heartbeat() {
        heartbeatLock.lock(); lastHeartbeat = Date(); hangReported = false; heartbeatLock.unlock()
    }

    private func startWatchdog() {
        // Main-thread heartbeat twice a second (with tolerance, so it rides
        // along with other timers instead of waking the CPU on its own).
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.heartbeat() }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        let thread = Thread { [weak self] in
            while true {
                guard let self else { return }
                self.heartbeatLock.lock(); let active = self.isActive; self.heartbeatLock.unlock()
                // Nothing to watch in the background: sleep long there.
                Thread.sleep(forTimeInterval: active ? 1.0 : 5.0)
                self.heartbeatLock.lock()
                let stalled = self.isActive ? Date().timeIntervalSince(self.lastHeartbeat) : 0
                let reported = self.hangReported
                if stalled > 1.5 && !reported { self.hangReported = true }
                self.heartbeatLock.unlock()
                if stalled > 1.5 && !reported {
                    self.log("hang", String(format: "main thread unresponsive for %.1f s", stalled))
                    let text = "\(Date()) main thread stalled \(String(format: "%.1f", stalled)) s\n\n"
                    if let h = try? FileHandle(forWritingTo: self.hangLog) { _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(text.utf8)); try? h.close() }
                    else { try? text.write(to: self.hangLog, atomically: true, encoding: .utf8) }
                }
            }
        }
        thread.name = "folio.watchdog"
        thread.qualityOfService = .utility
        thread.start()
        watchdog = thread
    }

    // MARK: Report

    /// A log as text even when a line in it isn't valid UTF-8 (mpv prints
    /// file and track names as they are). A strict read gave nil, and the
    /// whole log was left out of the report.
    private static func lenientText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Zips app log, crash/hang logs, mpv log and settings into one file.
    func makeReport() -> URL? {
        queue.sync { try? handle?.synchronize() }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Folio-report-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        for f in [appLog, crashLog, hangLog, metricLog, dir.appendingPathComponent("app.previous.log")] where FileManager.default.fileExists(atPath: f.path) {
            if let s = Self.lenientText(f) {
                try? Self.redact(s).write(to: tmp.appendingPathComponent(f.lastPathComponent), atomically: true, encoding: .utf8)
            }
        }
        // PiP trace (PiPTrace): the window images, and the snapshots iOS
        // keeps for the app switcher (Library/SplashBoard, newest first).
        if UserDefaults.standard.bool(forKey: SettingsKey.pipTrace) {
            let fm = FileManager.default
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.lastPathComponent.hasPrefix("pip-ui-") {
                try? fm.copyItem(at: f, to: tmp.appendingPathComponent(f.lastPathComponent))
            }
            let splash = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("SplashBoard", isDirectory: true)
            var found: [(URL, Date)] = []
            if let e = fm.enumerator(at: splash, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) {
                for case let u as URL in e {
                    guard let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
                    found.append((u, v.contentModificationDate ?? .distantPast))
                }
            }
            let out = tmp.appendingPathComponent("splashboard", isDirectory: true)
            try? fm.createDirectory(at: out, withIntermediateDirectories: true)
            for (i, (u, _)) in found.sorted(by: { $0.1 > $1.1 }).prefix(6).enumerated() {
                try? fm.copyItem(at: u, to: out.appendingPathComponent("\(i)-" + u.lastPathComponent))
            }
        }
        if let mpv = Self.lenientText(MPVFiles.logFile) {
            try? Self.redact(String(mpv.suffix(600_000))).write(to: tmp.appendingPathComponent("mpv.log"), atomically: true, encoding: .utf8)
        }
        // Settings go through the same filter, and a setting named like a
        // secret (the TMDB key) is left out whole: until 1.20.2 they were
        // written as they were (review, 31 Oct), addon links with keys too.
        var settings: [String: Any] = [:]
        for (k, v) in UserDefaults.standard.dictionaryRepresentation() where !k.hasPrefix("Apple") && !k.hasPrefix("NS") && !k.contains("webdavServers") {
            settings[k] = k.range(of: "key|token|secret|pass", options: [.regularExpression, .caseInsensitive]) != nil ? "••••" : Self.redact("\(v)")
        }
        settings["device"] = Self.model(); settings["ios"] = UIDevice.current.systemVersion
        settings["version"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? ""
        if let d = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: tmp.appendingPathComponent("settings.json"))
        }
        let zip = FileManager.default.temporaryDirectory.appendingPathComponent(tmp.lastPathComponent + ".zip")
        try? FileManager.default.removeItem(at: zip)
        var error: NSError?
        var ok = false
        NSFileCoordinator().coordinate(readingItemAt: tmp, options: .forUploading, error: &error) { zipped in
            ok = (try? FileManager.default.copyItem(at: zipped, to: zip)) != nil
        }
        return ok ? zip : nil
    }

    static func model() -> String {
        var s = utsname(); uname(&s)
        return withUnsafePointer(to: &s.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
    }

    static func freeDisk() -> String {
        let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return ByteCountFormatter.string(fromByteCount: v?.volumeAvailableCapacityForImportantUsage ?? 0, countStyle: .file)
    }
}

extension Diagnostics: MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var text = ""
        for p in payloads {
            for c in p.crashDiagnostics ?? [] { text += "CRASH \(c.applicationVersion) signal=\(c.signal ?? 0) code=\(c.exceptionCode ?? 0) type=\(c.exceptionType ?? 0)\n\(String(decoding: c.callStackTree.jsonRepresentation(), as: UTF8.self))\n\n" }
            for h in p.hangDiagnostics ?? [] { text += "HANG \(h.hangDuration)\n\(String(decoding: h.callStackTree.jsonRepresentation(), as: UTF8.self))\n\n" }
        }
        guard !text.isEmpty else { return }
        if let h = try? FileHandle(forWritingTo: metricLog) { _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(text.utf8)); try? h.close() }
        else { try? text.write(to: metricLog, atomically: true, encoding: .utf8) }
        log("metrickit", "received \(payloads.count) diagnostic payload(s)")
    }

    func didReceive(_ payloads: [MXMetricPayload]) {}
}

func dlog(_ tag: String, _ message: @autoclosure () -> String) { Diagnostics.shared.log(tag, message()) }

/// Launch timing in the app log: process start → first screen. When iOS
/// prewarmed the process (started it ahead of time), the gap includes the
/// wait before you tapped, so it's flagged.
enum LaunchTiming {
    private nonisolated(unsafe) static var logged = false

    static func processStart() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
    }

    /// When the root view appeared (Home's share of launch is measured from it).
    private nonisolated(unsafe) static var rootAppeared: CFTimeInterval?
    private nonisolated(unsafe) static var homeLogged = false
    private nonisolated(unsafe) static var frameWatch: FrameWatch?

    /// Home's own share of launch (1.20.0, to compare Home before and after
    /// a change): from the root view appearing to Home appearing, to the next
    /// frame the screen draws, and to the first moment after it the main
    /// thread is free to take a touch. Once per launch.
    @MainActor
    static func homeAppeared() {
        guard !homeLogged else { return }
        homeLogged = true
        let t0 = rootAppeared ?? CACurrentMediaTime()
        let appeared = CACurrentMediaTime()
        frameWatch = FrameWatch { frame in
            DispatchQueue.main.async {
                let free = CACurrentMediaTime()
                func ms(_ t: CFTimeInterval) -> Int { Int((t - t0) * 1000) }
                dlog("app", "Home: appeared \(ms(appeared)) ms after the root view, next frame at \(ms(frame)) ms, main thread free at \(ms(free)) ms")
                frameWatch = nil
            }
        }
    }

    /// Calls back once, on the next frame the display draws.
    private final class FrameWatch: NSObject {
        private var link: CADisplayLink?
        private let done: (CFTimeInterval) -> Void
        init(_ done: @escaping (CFTimeInterval) -> Void) {
            self.done = done
            super.init()
            link = CADisplayLink(target: self, selector: #selector(tick))
            link?.add(to: .main, forMode: .common)
        }
        @objc private func tick(_ l: CADisplayLink) {
            l.invalidate()
            link = nil
            done(CACurrentMediaTime())
        }
    }

    static func firstFrame() {
        if rootAppeared == nil { rootAppeared = CACurrentMediaTime() }
        guard !logged else { return }
        logged = true
        let prewarmed = ProcessInfo.processInfo.environment["ActivePrewarm"] == "1"
        guard let start = processStart() else { return }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        dlog("app", "first screen \(ms) ms after process start\(prewarmed ? " (prewarmed by iOS)" : "")")
    }
}
