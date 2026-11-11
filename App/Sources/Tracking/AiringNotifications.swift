import Foundation
import UIKit
import UserNotifications

/// Settings → Tracking → New episodes: when the notification comes.
enum AiringAlerts: String, CaseIterable, Identifiable {
    case air, hour, off
    var id: String { rawValue }

    var title: String {
        switch self {
        case .air: return "When it's out"
        case .hour: return "1 hour before"
        case .off: return "Off"
        }
    }

    /// How long before the air time the notification comes.
    var lead: TimeInterval { self == .hour ? 3600 : 0 }

    static var current: AiringAlerts {
        AiringAlerts(rawValue: UserDefaults.standard.string(forKey: SettingsKey.airingAlerts) ?? "") ?? .air
    }
}

/// A notification Folio means to have pending.
struct PlannedAlert: Equatable {
    var id: String
    var showID: String
    var fire: Date
    var title: String
    var body: String
}

/// Local notifications at the tracked shows' air times ("MobLand S1 · E5 is
/// out"). iOS keeps at most 64 pending per app, so only the soonest 40
/// across all shows are; they're planned again after every refresh and
/// change, so the next ones move up as these go off.
enum AiringNotifications {
    static let prefix = "airing."
    static let limit = 40

    /// The soonest `limit` episodes still to come, at their air time less
    /// the setting's lead. One whose moment has already passed (airing in
    /// 30 minutes with "1 hour before") gets none.
    /// When a day-only episode is announced: 9 in the morning of its day.
    static let dayOnlyHour: Double = 9

    /// `voice`: the engagement notifications are on (1.24.0), and an episode
    /// out in the day (9:00 to 22:00) says so in their voice; at night, and
    /// for "1 hour before" or a day-only episode, the plain wording stays.
    /// 1.25.0: `tone` is Settings → Notifications' personality (each
    /// voiced one takes the kind's next line), `kinds` says whether new
    /// episodes and new seasons are on (a season premiere with new seasons
    /// off comes as a new episode).
    static func plan(_ shows: [TrackedShow], now: Date, mode: AiringAlerts, limit: Int = limit, voice: Bool = false,
                     tone: NotifyTone = .balanced, kinds: (episodes: Bool, seasons: Bool) = (true, true),
                     calendar: Calendar = .autoupdatingCurrent) -> [PlannedAlert] {
        guard mode != .off else { return [] }
        var out: [PlannedAlert] = []
        var voiced = 0
        for s in shows {
            for e in s.upcoming(after: now) {
                let premiere = e.number == 1 && (e.season ?? 0) >= 2
                guard premiere ? (kinds.seasons || kinds.episodes) : kinds.episodes else { continue }
                let what = e.number == nil && e.season == nil ? "A new episode of \(s.name)" : "\(s.name) \(e.label)"
                let fire: Date
                var title: String
                if let day = e.day, let start = AiringFormat.date(ofDay: day, calendar: calendar) {
                    // No time known (TVmaze's 12:00 UTC stands in): the
                    // morning of its day, not a made-up hour (1.23.0; the
                    // app shows such episodes by day since 1.22.6).
                    fire = start.addingTimeInterval(dayOnlyHour * 3600)
                    title = "\(what) comes out today"
                } else {
                    fire = e.airDate!.addingTimeInterval(-mode.lead)
                    title = mode == .hour ? "\(what) is out in an hour" : "\(what) is out"
                }
                guard fire > now else { continue }
                var body = [e.title, s.network.map { "On \($0)" }].compactMap { $0 }.joined(separator: " · ")
                if voice, mode == .air, e.day == nil, !EngagePlanner.isQuiet(fire, calendar: calendar),
                   !(premiere && !kinds.seasons),
                   let w = NotifyCenter.airingWording(show: s.name, episode: e, tone: tone, variation: voiced) {
                    (title, body) = w
                    voiced += 1
                }
                let key = e.number.map { "\(e.season ?? 0).\($0)" } ?? "\(Int(e.airDate!.timeIntervalSince1970))"
                out.append(PlannedAlert(id: "\(prefix)\(s.id).\(key)", showID: s.id, fire: fire, title: title, body: body))
            }
        }
        return Array(out.sorted { $0.fire < $1.fire }.prefix(limit))
    }

    /// One planning at a time, in order: each removes what's pending and
    /// adds its own, so two at once could leave both sets.
    @MainActor private static var running: Task<Void, Never>?

    /// The alerts last scheduled, as `signature` gives them.
    @MainActor private static var lastScheduled: String?

    /// `onlyIfChanged` (coming back to Folio, 1.28.2): left alone when the
    /// plan is the one scheduled and all of it is still pending. Every return
    /// removed and added them all again (34 times in the 10 Nov report).
    @MainActor
    static func reschedule(_ shows: [TrackedShow], onlyIfChanged: Bool = false) {
        // While Test is on (1.25.0) these are held: Test sends their samples.
        // None while notifications are off in Folio (1.28.5).
        // Nor in the kids profile (1.28.6): a tap on one opened Tracked Shows.
        let planned = NotifyPrefs.test || !NotifyPrefs.allOn || KidsProfile.isOnNow ? [] : plan(shows, now: Date(), mode: .current, voice: NotifyPrefs.tone != .subtle,
                                                 tone: NotifyPrefs.tone, kinds: (NotifyPrefs.kindOn(.newEpisode), NotifyPrefs.kindOn(.newSeason)))
        let sig = signature(planned)
        let previous = running
        running = Task {
            await previous?.value
            if onlyIfChanged, lastScheduled == sig, await stillPending(planned) { return }
            lastScheduled = await apply(planned) ? sig : nil
        }
    }

    /// What each alert is and when it fires (to the minute).
    static func signature(_ planned: [PlannedAlert]) -> String {
        planned.map { "\($0.id)@\(Int($0.fire.timeIntervalSince1970 / 60))|\($0.title)|\($0.body)" }.joined(separator: "\n")
    }

    /// The planned alerts still to come are exactly the ones pending.
    private static func stillPending(_ planned: [PlannedAlert]) async -> Bool {
        let pending = Set(await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) })
        return pending == Set(planned.filter { $0.fire.timeIntervalSinceNow > 1 }.map(\.id))
    }

    /// Scheduled (true), or nothing could be (not allowed).
    @discardableResult
    private static func apply(_ planned: [PlannedAlert]) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let ours = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)
        guard !planned.isEmpty else { return true }
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else {
            dlog("tracking", "\(planned.count) notification(s) not scheduled: notifications aren't allowed")
            return false
        }
        let now = Date()
        var added = 0
        for p in planned {
            let c = UNMutableNotificationContent()
            c.title = p.title
            c.body = p.body
            c.sound = NotifySounds.sound(for: .newReleases)
            c.threadIdentifier = prefix + p.showID
            c.userInfo = ["track": p.showID]
            // An interval, not a calendar date: the moment stays right if you change time zone before it.
            let wait = p.fire.timeIntervalSince(now)
            guard wait > 1 else { continue }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: p.id, content: c, trigger: trigger))
                added += 1
            } catch {
                dlog("tracking", "notification not scheduled: \(error.localizedDescription)")
            }
        }
        dlog("tracking", "\(added) notification(s) scheduled, the first \(planned.first.map { "in \(Int($0.fire.timeIntervalSince(now) / 60)) min" } ?? "none")")
        return true
    }

    /// The first Track (as Downloads asks when its notifications are turned on).
    static func askPermissionIfNeeded() {
        guard AiringAlerts.current != .off else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { s in
            guard s.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                dlog("tracking", "notifications \(granted ? "allowed" : "not allowed")")
                guard granted else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { reschedule(TrackingStore.shared.shows) } }
            }
        }
    }
}

/// Folio's notification delegate (1.21.0). Episode notifications show while
/// Folio is open too, and a tap opens the show's tracking page. Others keep
/// what iOS does without a delegate: Downloads' "finished" is only sent
/// while Folio is in the background, and isn't shown over the app.
final class AiringNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AiringNotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let id = notification.request.identifier
        // Folio's own (1.25.0) shown over it: Test's, the lab's, and those left pending while it's open (1.28.5).
        let show = id.hasPrefix(AiringNotifications.prefix) || NotifyCenter.showsOverApp(notification)
        completionHandler(show ? [.banner, .list, .sound] : [])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.content.userInfo["notify"] != nil {
            // Folio's own notifications and their buttons (1.25.0). The
            // delegate isn't promised the main thread: handled there, then done.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { _ = NotifyCenter.handle(response) }
                completionHandler()
            }
            return
        }
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let id = response.notification.request.content.userInfo["track"] as? String {
            DispatchQueue.main.async { MainActor.assumeIsolated { TrackingPresenter.open(id) } }
        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
                  let link = response.notification.request.content.userInfo["engage"] as? String {
            // A 1.24 reminder delivered after the update: plays what it was about.
            DispatchQueue.main.async { MainActor.assumeIsolated { NotifyCenter.open(link) } }
        }
        completionHandler()
    }
}
