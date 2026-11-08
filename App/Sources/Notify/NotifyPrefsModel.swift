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
            NotifyCenter.refreshFeeds()
        }
    }

    subscript(kindOn k: NotifyKind) -> Bool {
        get { _ = revision; return NotifyPrefs.kindOn(k) }
        set {
            NotifyPrefs.setKind(k, on: newValue)
            revision += 1
            NotifyCenter.refreshFeeds()
        }
    }

    /// Something else changed a value (a kind woken from resting, Tracked Shows' "Notify me").
    func changed() { revision += 1 }
}
