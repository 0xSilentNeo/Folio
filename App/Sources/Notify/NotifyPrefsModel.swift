import Foundation
import Observation

/// Notification switches the pages watch (1.26.1). NotifyPrefs reads and
/// writes UserDefaults and nothing told a page it changed, so the pages
/// rebuilt themselves with `.id(bump)` after every tap: the switch lost its
/// animation, and scroll position and VoiceOver focus went back to the top.
/// Values are read from NotifyPrefs each time (some live with Tracking and
/// Downloads), and every change here bumps `revision` for the pages.
@MainActor @Observable
final class NotifyPrefsModel {
    static let shared = NotifyPrefsModel()

    /// Changes with every switch: what the pages observe.
    private(set) var revision = 0

    subscript(groupOn g: NotifyGroup) -> Bool {
        get { _ = revision; return NotifyPrefs.groupOn(g) }
        set {
            NotifyPrefs.setGroup(g, on: newValue)
            revision += 1
            if g == .newReleases { AiringNotifications.reschedule(TrackingStore.shared.shows) }
            NotifyCenter.settingsChanged()
            NotifyCenter.refreshFeeds()
        }
    }

    subscript(kindOn k: NotifyKind) -> Bool {
        get { _ = revision; return NotifyPrefs.kindOn(k) }
        set {
            NotifyPrefs.setKind(k, on: newValue)
            revision += 1
            NotifyCenter.settingsChanged()
            NotifyCenter.refreshFeeds()
        }
    }

    /// The weather's city (1.28.5). Read here, not from WeatherFeed, so
    /// Just for fun's page shows a city picked on the page over it as soon
    /// as you're back (it showed the old one until it was opened again).
    var place: WeatherFeed.Place? {
        get { _ = revision; return WeatherFeed.place }
        set {
            WeatherFeed.place = newValue
            revision += 1
            NotifyCenter.settingsChanged()
        }
    }

    /// A group's sound (1.28.5), for the same reason: the Sounds list under
    /// the picker kept the sound it was drawn with.
    func sound(for g: NotifyGroup) -> NotifySound {
        _ = revision
        return NotifySounds.choice(for: g)
    }

    func setSound(_ s: NotifySound, for g: NotifyGroup) {
        NotifySounds.set(s, for: g)
        revision += 1
        if g == .newReleases { AiringNotifications.reschedule(TrackingStore.shared.shows) }
        NotifyCenter.settingsChanged()
    }

    /// Notifications on or off as a whole (1.28.5).
    var allOn: Bool {
        get { _ = revision; return NotifyPrefs.allOn }
        set {
            NotifyPrefs.allOn = newValue
            revision += 1
            dlog("notify", "all notifications \(newValue ? "on" : "off")")
            AiringNotifications.reschedule(TrackingStore.shared.shows)
            // Off: every pending one goes, "Tomorrow" too. On: planned when Folio leaves.
            NotifyCenter.takeBack(asked: !newValue)
        }
    }

    /// Something else changed a value (a kind woken from resting, Tracked Shows' "Notify me").
    func changed() { revision += 1 }
}
