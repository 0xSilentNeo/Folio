import BackgroundTasks
import UIKit

/// iOS 26 and later: the download queue as a continued processing task
/// (BGContinuedProcessingTask, 1.22.3). iOS then draws the progress itself,
/// as for Safari's downloads: on the Lock Screen and in the Dynamic Island,
/// the app's icon, "Downloading "Name"", "102.9 MB of 137.1 MB", a ring
/// with a stop button and a check when it's done. It reads the task's
/// progress, which Folio reports every second, and Folio keeps running in
/// the background meanwhile, so its own engine carries on at full speed.
///
/// While this shows, Folio's own downloads Live Activity stays off (no
/// two of them). On older iOS, or when iOS declines or ends the task, that
/// Live Activity is used as before, and files downloading in Folio pause a
/// little after it leaves the screen (DownloadManager.enteredBackground).
///
/// A task can only be asked for while Folio is on screen: work you started.
/// Each request has an identifier of its own under `prefix`, with its own
/// handler (a handler for the wildcard itself isn't allowed, and a second
/// one for an identifier ends the app).
@MainActor
final class SystemProgress {
    static let shared = SystemProgress()

    /// Info.plist's BGTaskSchedulerPermittedIdentifiers holds this followed
    /// by "*" (project.yml, Vendor/genproj.py).
    static let prefix = "dev.silentneo.folio.downloads."
    /// A task asked for and not started by then isn't coming.
    static let startWithin: TimeInterval = 10
    /// The progress is in megabytes: iOS reads whole units, and bytes would
    /// pass Int64 nowhere near but say nothing more.
    nonisolated static let unit: Int64 = 1_000_000

    /// The running BGContinuedProcessingTask (AnyObject: the type is iOS 26's).
    private var task: AnyObject?
    private var asked: Date?
    /// Stopped (its stop button, or iOS ended it): not asked for again
    /// until the queue has been idle once, or you start a download.
    private var declined = false
    private var retryAfter = Date.distantPast
    private var last: Snapshot?
    private var shownTitle = ""
    private var shownSubtitle = ""
    /// Reasons already logged (each once per launch).
    private var told = Set<String>()
    /// iOS refused the task this launch (unavailable, not permitted, or not
    /// registered).
    private var refused = false

    /// iOS won't carry downloads in Folio while it's in the background:
    /// before iOS 26, or it refused the task this launch. New files then
    /// download in iOS's background session (DownloadManager.start).
    var cannotCarry: Bool {
        // Lab: the in-app engine in the simulator, where iOS always refuses.
        if CommandLine.arguments.contains("-labInAppDownloads") { return false }
        guard #available(iOS 26.0, *) else { return true }
        return refused
    }

    /// Its progress was stopped: true when Folio was in the background
    /// (the stop button, or iOS), false on screen (iOS ended it).
    var onStop: ((Bool) -> Void)?

    /// iOS shows the progress, or is about to: Folio's own Live Activity stays off.
    var isActive: Bool { task != nil || asked != nil }
    /// The task runs: Folio may download in the background.
    var isRunning: Bool { task != nil }

    /// For the log: what carries the downloads in the background.
    var describe: String {
        if task != nil { return "iOS's own progress running" }
        if asked != nil { return "iOS's own progress asked for" }
        guard #available(iOS 26.0, *) else { return "no continued processing before iOS 26" }
        return declined ? "iOS's own progress stopped" : "no iOS progress yet"
    }

    struct Snapshot: Equatable {
        /// Files download, or are about to (queued, allowed to run).
        var busy: Bool
        /// Every file of the run is in the library.
        var allDone: Bool
        var received: Int64
        var total: Int64
        var title: String
        var subtitle: String
    }

    private init() {}

    /// The texts iOS shows, as Safari's: `Downloading "Name"` (or "3 files"
    /// at once) over `102.9 MB of 137.1 MB` for the run.
    nonisolated static func texts(running: [String], next: String?, waiting: Bool, received: Int64, total: Int64) -> (title: String, subtitle: String) {
        let title: String
        switch running.count {
        case 0: title = next.map { "Downloading \u{201C}\($0)\u{201D}" } ?? "Downloading"
        case 1: title = "Downloading \u{201C}\(running[0])\u{201D}"
        default: title = "Downloading \(running.count) files"
        }
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        let bytes = total > 0 ? "\(f.string(fromByteCount: min(max(0, received), total))) of \(f.string(fromByteCount: total))" : "Starting"
        return (title, waiting ? "Waiting to retry · \(bytes)" : bytes)
    }

    /// The units iOS reads: (completed, total), in `unit`s.
    nonisolated static func units(received: Int64, total: Int64) -> (Int64, Int64) {
        let all = max(1, total / unit)
        return (min(all, max(0, received / unit)), all)
    }

    /// You started a download: iOS may be asked again.
    func userStarted() { declined = false }

    /// Every second while files download, and when the queue changes.
    func sync(_ s: Snapshot) {
        last = s
        guard #available(iOS 26.0, *) else { return }
        if let asked, task == nil, Date().timeIntervalSince(asked) > Self.startWithin {
            self.asked = nil
            declined = true
            note("late", "iOS's own progress didn't start within \(Int(Self.startWithin)) s: Folio's Live Activity instead")
        }
        guard s.busy else {
            finish(success: s.allDone)
            declined = false
            return
        }
        if let t = task as? BGContinuedProcessingTask {
            report(t, s)
            return
        }
        guard asked == nil, !declined, Date() >= retryAfter, UIApplication.shared.applicationState == .active else { return }
        submit(s)
    }

    @available(iOS 26.0, *)
    private func submit(_ s: Snapshot) {
        let identifier = Self.prefix + UUID().uuidString
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated { SystemProgress.shared.attach(task) }
        }
        guard registered else {
            refused = true
            retryAfter = Date().addingTimeInterval(300)
            note("register", "iOS's own progress: the task wasn't registered (not in Info.plist's BGTaskSchedulerPermittedIdentifiers?)")
            return
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: s.title, subtitle: s.subtitle)
        // Now or not at all: a queued one would start after the downloads it's for.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            asked = Date()
            shownTitle = s.title
            shownSubtitle = s.subtitle
            dlog("dl", "asked iOS to show the download progress (continued processing task)")
        } catch {
            let ns = error as NSError
            // Unavailable, not permitted or not possible: new files go to iOS's
            // background session (cannotCarry). Too many pending: soon again.
            if ns.code != 2 { refused = true }
            // Unavailable (the simulator) won't change this launch; refused
            // may once background activity is allowed again; busy soon.
            retryAfter = ns.code == 1 ? .distantFuture : Date().addingTimeInterval(ns.code == 3 ? 600 : 60)
            let why: String
            switch ns.code {
            case 1: why = "unavailable, as in the simulator, which has no background processing"
            case 2: why = "too many pending requests"
            case 3: why = "not permitted (Info.plist, or background activity off for Folio)"
            case 4: why = "iOS can't run it right now"
            default: why = ns.localizedDescription
            }
            note("submit\(ns.code)", "iOS won't show the download progress (\(ns.domain) \(ns.code): \(why)): Folio's Live Activity instead, and new files download in iOS's background session")
        }
    }

    @available(iOS 26.0, *)
    private func attach(_ bgTask: BGTask) {
        asked = nil
        guard let t = bgTask as? BGContinuedProcessingTask else {
            bgTask.setTaskCompleted(success: false)
            return
        }
        task = t
        t.progress.totalUnitCount = 1
        t.progress.completedUnitCount = 0
        t.expirationHandler = {
            DispatchQueue.main.async { MainActor.assumeIsolated { SystemProgress.shared.expired() } }
        }
        dlog("dl", "iOS shows the download progress (continued processing task running)")
        // The queue may have finished while iOS was starting it.
        if let last {
            if last.busy { report(t, last) } else { finish(success: last.allDone) }
        }
    }

    /// The stop button, or iOS ending the task.
    private func expired() {
        guard #available(iOS 26.0, *), let t = task as? BGContinuedProcessingTask else { return }
        let background = UIApplication.shared.applicationState == .background
        task = nil
        declined = true
        dlog("dl", "iOS's download progress was stopped (\(background ? "its stop button, or iOS" : "by iOS, Folio on screen"))")
        // The pauses start before the task ends (DownloadManager keeps a
        // moment for their writes).
        onStop?(background)
        t.setTaskCompleted(success: false)
    }

    @available(iOS 26.0, *)
    private func report(_ t: BGContinuedProcessingTask, _ s: Snapshot) {
        let (done, all) = Self.units(received: s.received, total: s.total)
        if t.progress.totalUnitCount != all { t.progress.totalUnitCount = all }
        if t.progress.completedUnitCount != done { t.progress.completedUnitCount = done }
        if s.title != shownTitle || s.subtitle != shownSubtitle {
            shownTitle = s.title
            shownSubtitle = s.subtitle
            t.updateTitle(s.title, subtitle: s.subtitle)
        }
    }

    private func finish(success: Bool) {
        guard #available(iOS 26.0, *), let t = task as? BGContinuedProcessingTask else { return }
        // Done: the check. Paused or failed: it goes.
        if success { t.progress.completedUnitCount = t.progress.totalUnitCount }
        t.setTaskCompleted(success: success)
        task = nil
        dlog("dl", "iOS's download progress ended (\(success ? "all downloaded" : "nothing downloading"))")
    }

    private func note(_ key: String, _ message: String) {
        guard told.insert(key).inserted else { return }
        dlog("dl", message)
    }
}
