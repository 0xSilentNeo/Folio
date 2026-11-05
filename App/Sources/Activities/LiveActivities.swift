import ActivityKit
import UIKit

/// Live Activities (1.22.0): downloads (DownloadActivity), on the Lock Screen
/// and in the Dynamic Island. Settings → Downloads → Live Activities (on by
/// default). The widget extension draws it (App/Widget/Extension). What's
/// playing had one too until 1.23.0; Now Playing shows it since 1.22.7.
@MainActor
enum LiveActivities {
    private static let authorization = ActivityAuthorizationInfo()
    private static var started = false
    /// iOS's switch, read again each time Folio comes back to the screen
    /// (where it's changed): the downloads activity asks several times a second.
    private static var systemAllows = authorization.areActivitiesEnabled

    /// Folio's switch, and iOS's own (Settings → Folio → Live Activities).
    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.liveActivities) && systemAllows
    }

    /// Off in iOS Settings, whatever Folio's switch says.
    static var blockedBySystem: Bool { !authorization.areActivitiesEnabled }

    /// iOS starts an activity only for an app on screen; one already
    /// running can be updated and ended from the background.
    static var canStart: Bool { UIApplication.shared.applicationState != .background }

    /// At launch (DownloadManager): a now-playing activity an older version
    /// left goes; the downloads one is picked up again (Folio is often
    /// relaunched in the background for its downloads).
    static func start() {
        guard !started else { return }
        started = true
        NowPlayingActivity.endLeftovers()
        DownloadActivity.shared.start()
        // Back on screen: an activity that couldn't start in the background can now.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                systemAllows = authorization.areActivitiesEnabled
                DownloadActivity.shared.refresh()
            }
        }
        if CommandLine.arguments.contains("-labLiveActivities") { lab() }
    }

    /// Settings → Downloads → Live Activities was switched.
    static func settingChanged() {
        dlog("activity", "Live Activities \(UserDefaults.standard.bool(forKey: SettingsKey.liveActivities) ? "on" : "off")")
        DownloadActivity.shared.refresh()
    }

    // MARK: Lab

    /// -labLiveActivities: the downloads activity with sample content, to see
    /// it in the simulator.
    private static func lab() {
        dlog("activity", "lab: sample activity")
        DownloadActivity.shared.lab()
    }
}
