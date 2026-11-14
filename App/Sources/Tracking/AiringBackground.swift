import BackgroundTasks
import UIKit
import UserNotifications

/// When schedules are fetched: on Track, when Folio comes to the front with
/// a schedule older than six hours, on pull to refresh, and in a background
/// refresh iOS runs now and then (BGAppRefreshTask), asked for shortly after
/// the next air time so the widget and the notifications move on to the
/// episode after it.
enum AiringTracker {
    /// FolioApp.init: before the app finishes launching, as BGTaskScheduler
    /// and a notification tapped while Folio was closed both need.
    @MainActor
    static func start() {
        AiringBackground.register()
        UNUserNotificationCenter.current().delegate = AiringNotificationDelegate.shared
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            // Air times in the zone you're in now: Foundation keeps the
            // system zone it first read until told to read it again (1.22.1).
            NSTimeZone.resetSystemTimeZone()
            MainActor.assumeIsolated {
                refreshIfStale("foreground")
                // Notifications allowed in iOS Settings meanwhile: planned now,
                // not at the next refresh up to six hours on (review, 5 Nov).
                AiringNotifications.reschedule(TrackingStore.shared.shows, onlyIfChanged: true)
            }
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AiringBackground.schedule(TrackingStore.shared.shows) }
        }
        refreshAfterUpdate()
        // `-openTrack <id|all>` (tests): opens a tracking page as folio://track does.
        if let i = CommandLine.arguments.firstIndex(of: "-openTrack"), i + 1 < CommandLine.arguments.count {
            let id = CommandLine.arguments[i + 1]
            TrackingPresenter.open(id == "all" ? nil : id)
        }
    }

    @MainActor
    private static func refreshIfStale(_ reason: String) {
        Task { await TrackingStore.shared.refresh(reason: reason) }
    }

    /// The first launch of a new version asks every show again (1.23.0):
    /// what an older version saved is worked out with its rules, which a
    /// refresh only replaces once the show is due (5 Nov: Dragon Ball kept
    /// Beerus's times and Tulsa King its made-up hour after 1.22.6).
    @MainActor
    private static func refreshAfterUpdate() {
        let key = "trackingRefreshedForBuild"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        guard UserDefaults.standard.string(forKey: key) != build else { refreshIfStale("launch"); return }
        Task {
            await TrackingStore.shared.refresh(force: true, reason: "Folio updated")
            UserDefaults.standard.set(build, forKey: key)
        }
    }
}

enum AiringBackground {
    /// Also in Info.plist's BGTaskSchedulerPermittedIdentifiers (project.yml, Vendor/genproj.py).
    static let taskID = "dev.silentneo.folio.airing-refresh"

    static func register() {
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            run(task)
        }
        if !ok { dlog("tracking", "background refresh not registered (not in Info.plist?)") }
    }

    /// The task completed once (1.30.4): when the work ends, or at once when
    /// iOS's time is up. The expiry only cancelled the work, which went on
    /// waiting for posters' downloads, so it completed late, if at all.
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let task: BGTask
        init(_ task: BGTask) { self.task = task }

        func complete(_ success: Bool) {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            if first { task.setTaskCompleted(success: success) }
        }
    }

    private static func run(_ task: BGAppRefreshTask) {
        let completion = Completion(task)
        let work = Task { @MainActor in
            let store = TrackingStore.shared
            await store.whenLoaded()
            // The next one first, in case this one runs out of time.
            schedule(store.shows)
            // In the background a schedule an hour old is fetched again:
            // these runs are few, and the next episode may just have aired.
            await store.refresh(maxAge: 3600, reason: "background")
            // Real-Debrid's library, for its widget (1.28.5).
            if !Task.isCancelled, !KidsProfile.isOnNow, let rd = ServerStore.shared.servers.first(where: RealDebrid.isRealDebrid) {
                await LibraryIndexStore.shared.refreshInBackground(rd, maxAge: 1800)
                // Now, not after the writer's usual pause: iOS may suspend the app first.
                await GlanceWriter.writeServers()
            }
            // The notifications' charts and forecast (1.25.0), then planned again with them.
            if !Task.isCancelled, UIApplication.shared.applicationState == .background {
                await NotifyCenter.refreshFeedsNow()
                // Not while Test is on (1.28.6): each background run sent its whole run again.
                if !NotifyPrefs.test { NotifyCenter.replan("background refresh") }
            }
            completion.complete(!Task.isCancelled)
        }
        task.expirationHandler = {
            work.cancel()
            dlog("tracking", "background refresh: iOS's time is up")
            completion.complete(false)
        }
    }

    /// Submitting can block (BGTaskScheduler docs): done on a queue of its own.
    private static let queue = DispatchQueue(label: "dev.silentneo.folio.airing-refresh", qos: .utility)
    private static var told = false          // on `queue`

    /// Asks iOS for the next background refresh (it decides when; this is the earliest).
    @MainActor
    static func schedule(_ shows: [TrackedShow]) {
        // The notifications' charts and forecast (1.25.0) want a refresh every 12 hours or so.
        let feeds: Date? = TrendFeed.wanted || WeatherFeed.wanted ? Date().addingTimeInterval(12 * 3600) : nil
        let earliest = [shows.isEmpty ? nil : earliest(shows, now: Date()), feeds].compactMap { $0 }.min()
        queue.async {
            guard let earliest else {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskID)
                return
            }
            let request = BGAppRefreshTaskRequest(identifier: taskID)
            request.earliestBeginDate = earliest
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                // The simulator always refuses; said once.
                if !told { dlog("tracking", "background refresh not scheduled: \(error.localizedDescription)") }
                told = true
            }
        }
    }

    /// A quarter of an hour after the soonest air time, within 15 min to 6 h from now.
    static func earliest(_ shows: [TrackedShow], now: Date) -> Date {
        let soonest = shows.compactMap { $0.upcoming(after: now).first?.airDate }.min()
        let want = soonest.map { $0.addingTimeInterval(15 * 60) } ?? now.addingTimeInterval(6 * 3600)
        return min(max(want, now.addingTimeInterval(15 * 60)), now.addingTimeInterval(6 * 3600))
    }
}
