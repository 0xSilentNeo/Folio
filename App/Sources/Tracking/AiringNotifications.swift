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
    static func plan(_ shows: [TrackedShow], now: Date, mode: AiringAlerts, limit: Int = limit) -> [PlannedAlert] {
        guard mode != .off else { return [] }
        var out: [PlannedAlert] = []
        for s in shows {
            for e in s.upcoming(after: now) {
                let fire = e.airDate!.addingTimeInterval(-mode.lead)
                guard fire > now else { continue }
                let what = e.number == nil && e.season == nil ? "A new episode of \(s.name)" : "\(s.name) \(e.label)"
                let title = mode == .hour ? "\(what) is out in an hour" : "\(what) is out"
                let body = [e.title, s.network.map { "On \($0)" }].compactMap { $0 }.joined(separator: " · ")
                let key = e.number.map { "\(e.season ?? 0).\($0)" } ?? "\(Int(e.airDate!.timeIntervalSince1970))"
                out.append(PlannedAlert(id: "\(prefix)\(s.id).\(key)", showID: s.id, fire: fire, title: title, body: body))
            }
        }
        return Array(out.sorted { $0.fire < $1.fire }.prefix(limit))
    }

    /// One planning at a time, in order: each removes what's pending and
    /// adds its own, so two at once could leave both sets.
    @MainActor private static var running: Task<Void, Never>?

    @MainActor
    static func reschedule(_ shows: [TrackedShow]) {
        let planned = plan(shows, now: Date(), mode: .current)
        let previous = running
        running = Task {
            await previous?.value
            await apply(planned)
        }
    }

    private static func apply(_ planned: [PlannedAlert]) async {
        let center = UNUserNotificationCenter.current()
        let ours = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)
        guard !planned.isEmpty else { return }
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else {
            dlog("tracking", "\(planned.count) notification(s) not scheduled: notifications aren't allowed")
            return
        }
        let now = Date()
        var added = 0
        for p in planned {
            let c = UNMutableNotificationContent()
            c.title = p.title
            c.body = p.body
            c.sound = .default
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
        completionHandler(notification.request.identifier.hasPrefix(AiringNotifications.prefix) ? [.banner, .list, .sound] : [])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let id = response.notification.request.content.userInfo["track"] as? String {
            DispatchQueue.main.async { MainActor.assumeIsolated { TrackingPresenter.open(id) } }
        }
        completionHandler()
    }
}
