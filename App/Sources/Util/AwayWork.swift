import UIKit

/// Work for when Folio has really left the screen, not for a pull of
/// Notification Centre or a look at the app switcher (1.28.2).
///
/// Each trip away planned every notification again (a dozen requests with
/// pictures, removed again on the way back), rewrote the widgets' files and
/// had iOS wake the widget extension to draw them anew: 50 trips in the 10
/// Nov report, most of them a few seconds long while watching a film. Now
/// that work waits a few seconds, holding the app awake for it, and isn't
/// done at all if Folio is back first. What must not wait (the history
/// written to disk, downloads handed to iOS) still runs at once where it
/// did.
@MainActor
enum AwayWork {
    /// How long Folio has to stay away before the work is done.
    static let delay: TimeInterval = 12

    private static var pending: [(name: String, work: () -> Void)] = []
    private static var timer: Task<Void, Never>?
    private static var task = UIBackgroundTaskIdentifier.invalid
    private static var observing = false

    /// Runs `work` once Folio has been away `delay` seconds (or iOS is about
    /// to end its background time); dropped if Folio comes back first.
    /// Work under the same name replaces what's waiting.
    static func onLeaving(_ name: String, _ work: @escaping () -> Void) {
        observe()
        pending.removeAll { $0.name == name }
        pending.append((name, work))
        guard timer == nil else { return }
        if task == .invalid {
            task = UIApplication.shared.beginBackgroundTask(withName: "Folio: away work") {
                // iOS is ending the app's background time: the work now, and
                // the task ended before this returns.
                MainActor.assumeIsolated { runNow(); endTask() }
            }
        }
        timer = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            runNow()
        }
    }

    private static func runNow() {
        timer?.cancel(); timer = nil
        let work = pending
        pending = []
        if UIApplication.shared.applicationState == .background {
            for w in work { w.work() }
        }
        // A moment more for what the work started (files written off the
        // main thread), unless more work has come meanwhile.
        Task {
            try? await Task.sleep(for: .seconds(4))
            if timer == nil, pending.isEmpty { endTask() }
        }
    }

    private static func comeBack() {
        guard timer != nil || !pending.isEmpty else { return }
        timer?.cancel(); timer = nil
        if !pending.isEmpty {
            dlog("energy", "back within \(Int(delay)) s: not needed this time (\(pending.map(\.name).joined(separator: ", ")))")
        }
        pending = []
        endTask()
    }

    private static func endTask() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }

    private static func observe() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { comeBack() }
        }
    }
}
