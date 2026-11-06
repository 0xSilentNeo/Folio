import UIKit
import UserNotifications

/// Schedules the engagement notifications (1.24.0, EngagePlanner has the
/// rules and the texts).
///
/// While you're in Folio none are pending: they're planned when it leaves
/// the screen, a chain of up to two weeks ahead (Folio may not run again for
/// days, and "a week away" has to be waiting already), and taken back when
/// it comes back, since what you then watch changes what's worth saying.
///
/// Nothing asks for permission here: they come only once notifications are
/// allowed (by Tracking, Downloads, or this setting's own Allow button).
@MainActor
enum EngagementNotifications {
    static let prefix = "engage."
    /// The pending ones at most (iOS keeps 64 per app; the tracker uses up to 40).
    static let maxPending = 8
    private static let sentKey = "engageSent"
    private static let scheduledKey = "engageScheduled"

    nonisolated static var isOn: Bool { UserDefaults.standard.bool(forKey: SettingsKey.engageNotes) }
    /// `-labEngage`: every moment's text, a few seconds apart, shown over the app too.
    nonisolated static var lab: Bool { CommandLine.arguments.contains("-labEngage") }

    private static var started = false
    private static var running: Task<Void, Never>?
    private static var backgroundTask = UIBackgroundTaskIdentifier.invalid

    /// FolioApp, at launch.
    static func start() {
        guard !started else { return }
        started = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { replan("left the screen") }
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if !lab { takeBack() } }
        }
        if lab { Task { await runLab() } }
    }

    /// Planned again from scratch.
    static func replan(_ reason: String) {
        let previous = running
        beginBackgroundTask()
        running = Task {
            await previous?.value
            await apply(reason)
            endBackgroundTask()
        }
    }

    /// Back in Folio, or the setting turned off: none pending.
    static func takeBack() {
        let previous = running
        running = Task {
            await previous?.value
            settleScheduled(now: Date())
            await removePending()
        }
    }

    private static func apply(_ reason: String) async {
        let now = Date()
        settleScheduled(now: now)
        await removePending()
        guard isOn, !KidsProfile.isOnNow else { return }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard [.authorized, .provisional, .ephemeral].contains(status) else {
            dlog("engage", "nothing planned: notifications aren't allowed")
            return
        }
        let state = await gather(now: now)
        let planned = Array(EngagePlanner.plan(state, now: now).prefix(maxPending))
        var scheduled: [EngagePlanner.Sent] = []
        for p in planned {
            let wait = p.fire.timeIntervalSince(Date())
            guard wait > 1 else { continue }
            let c = UNMutableNotificationContent()
            c.body = p.body
            c.sound = .default
            c.threadIdentifier = "engage"
            if let link = p.link { c.userInfo = ["engage": link] }
            // An interval, as the tracker's: the moment stays right across a time zone change.
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: prefix + p.id, content: c, trigger: trigger))
                scheduled.append(.init(id: p.id, at: p.fire, showKey: p.showKey))
            } catch {
                dlog("engage", "not scheduled: \(error.localizedDescription)")
            }
        }
        save(scheduled, scheduledKey)
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM HH:mm"
        dlog("engage", "\(scheduled.count) planned (\(reason))" + (planned.isEmpty ? "" : ": " + planned.map { "\($0.moment.rawValue) \(f.string(from: $0.fire))" }.joined(separator: ", ")))
    }

    /// The ones due by `now` went out (or would have): kept as sent for the
    /// rules; the rest are planned again.
    private static func settleScheduled(now: Date) {
        let scheduled = load(scheduledKey)
        guard !scheduled.isEmpty else { return }
        let month = now.addingTimeInterval(-30 * 86400)
        let sent = (load(sentKey) + scheduled.filter { $0.at <= now }).filter { $0.at > month }
        save(sent, sentKey)
        save([], scheduledKey)
    }

    private static func removePending() async {
        let center = UNUserNotificationCenter.current()
        let ours = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        if !ours.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ours) }
    }

    private static func load(_ key: String) -> [EngagePlanner.Sent] {
        guard let d = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([EngagePlanner.Sent].self, from: d)) ?? []
    }

    private static func save(_ list: [EngagePlanner.Sent], _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key)
    }

    private static func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Engagement notifications") {
            MainActor.assumeIsolated { endBackgroundTask() }
        }
    }

    private static func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: State

    /// What the plan needs, from history, the watch log, the library and the tracker.
    static func gather(now: Date) async -> EngagePlanner.State {
        let history = HistoryStore.shared
        let groups = LibraryOrganizer.groups(await ContinueQueue.libraryFiles()).filter(\.isSeries)
        var s = EngagePlanner.State()
        s.continueWatching = history.continueWatching.prefix(6).map { entry($0, groups: groups) }
        if let latest = history.entries.max(by: { $0.updated < $1.updated }), latest.isFinished,
           HeroCard.parts(latest.item, meta: nil).number != nil {
            s.lastFinished = entry(latest, groups: groups)
        }
        s.lastWatched = [WatchLog.shared.lastWatched, history.entries.map(\.updated).max()].compactMap { $0 }.max()
        s.days = WatchLog.shared.days
        // What was on at the late night's end: the entry saved closest to it
        // (from then on, as the same episode may have gone on past 5 am).
        if let until = WatchLog.shared.days.last?.lateUntil,
           let e = history.entries.filter({ $0.updated >= until.addingTimeInterval(-15 * 60) && $0.updated <= until.addingTimeInterval(12 * 3600) })
            .min(by: { abs($0.updated.timeIntervalSince(until)) < abs($1.updated.timeIntervalSince(until)) }) {
            let x = entry(e, groups: [])
            s.lateNight = (until, x.name, x.showKey)
        }
        s.busyDays = Set(AiringNotifications.plan(TrackingStore.shared.shows, now: now, mode: .current).map { WatchLog.dayKey($0.fire) })
        s.sent = load(sentKey)
        return s
    }

    static func entry(_ e: HistoryEntry, groups: [LibraryGroup]) -> EngagePlanner.Entry {
        let episode = HeroCard.parts(e.item, meta: nil).number != nil
        var name = ShowCatalog.name(of: e)
        if !episode, e.item.addonRef == nil {
            let t = TitleParser.parse(e.item.fileName).title
            if !t.isEmpty { name = t }
        }
        return .init(id: e.id, name: name, showKey: episode ? HistoryStore.showKey(e) : nil, position: e.position, duration: e.duration,
                     updated: e.updated, finished: e.isFinished, episodesLeft: episode ? episodesLeft(e, groups: groups) : nil)
    }

    /// Episodes still to watch of the entry's show in the library: this one
    /// unless it's finished, and each later episode once (two releases of an
    /// episode are one). Nil when the file isn't a library file.
    static func episodesLeft(_ e: HistoryEntry, groups: [LibraryGroup]) -> Int? {
        guard let rel = HistoryStore.libraryRelative(e.id) ?? HistoryStore.libraryRelative(e.item.url) else { return nil }
        for g in groups {
            guard let i = g.files.firstIndex(where: { HistoryStore.libraryRelative($0.standardizedFileURL.path) == rel }) else { continue }
            return EngagePlanner.episodesLeft(g.files.map(\.lastPathComponent), at: i, finished: e.isFinished)
        }
        return nil
    }

    // MARK: A tap

    /// folio://continue?id=… plays the entry as Home's card does; with
    /// &next=1 (the cliffhanger) the episode after it, from its start.
    static func open(_ link: String) {
        guard let url = URL(string: link), let id = ContinueLink.id(from: url) else { return }
        guard !KidsProfile.isOnNow else {
            dlog("engage", "kids profile: notification's episode not played")
            return
        }
        let next = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "next" && $0.value == "1" } == true
        Task { @MainActor in
            // Tapped while Folio was closed: its window comes a moment later.
            var waited = 0
            while waited < 30, !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }) {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            guard let entry = HistoryStore.shared.entry(for: id) else {
                dlog("engage", "notification for an entry that's no longer in the history")
                return
            }
            if next {
                let (queue, index) = await ContinueQueue.build(entry.item)
                if index + 1 < queue.count {
                    dlog("engage", "notification: the episode after, \(index + 2) of \(queue.count)")
                    PlayerPresenter.play(queue: queue, index: index + 1, fromStart: true)
                    return
                }
            }
            ContinueQueue.play(entry.item)
        }
    }

    // MARK: Lab

    /// `-labEngage` (simulator): each moment's text, four seconds apart, so
    /// they can be seen. Asks for permission first if it hasn't been asked.
    static func runLab() async {
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        let status = await center.notificationSettings().authorizationStatus
        guard [.authorized, .provisional, .ephemeral].contains(status) else {
            dlog("engage", "lab: notifications aren't allowed")
            return
        }
        let samples = EngagePlanner.labSamples()
        for (i, s) in samples.enumerated() {
            let c = UNMutableNotificationContent()
            if let t = s.title { c.title = t }
            c.body = s.body
            c.threadIdentifier = "engage"
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(4 + i * 4), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: prefix + "lab.\(i)", content: c, trigger: trigger))
        }
        dlog("engage", "lab: \(samples.count) samples, 4 s apart")
    }
}
