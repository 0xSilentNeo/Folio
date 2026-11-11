import UIKit

/// Home Screen quick actions (1.28.11): long-press Folio's icon for Resume,
/// with the name of what you watched last. It's the app's own menu, so it
/// works on any install; the Control Centre control is drawn by the widget
/// extension, which a re-signed install leaves blank (it draws as it
/// should on an install signed as built).
@MainActor
enum QuickActions {
    static let resume = "dev.silentneo.folio.quick.resume"

    private static var watching = false

    /// At launch: the menu follows the history each time Folio leaves the screen.
    static func start() {
        guard !watching else { return }
        watching = true
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { update() }
        }
        update()
    }

    static func update() {
        guard !KidsProfile.isOnNow, let e = HistoryStore.shared.continueWatching.first else {
            UIApplication.shared.shortcutItems = []
            return
        }
        let item = UIApplicationShortcutItem(type: resume, localizedTitle: "Resume", localizedSubtitle: ShowCatalog.name(of: e),
                                             icon: UIApplicationShortcutIcon(systemImageName: "play.fill"))
        if UIApplication.shared.shortcutItems?.first?.localizedSubtitle != item.localizedSubtitle {
            UIApplication.shared.shortcutItems = [item]
        }
    }

    @discardableResult
    static func perform(_ item: UIApplicationShortcutItem) -> Bool {
        guard item.type == resume else { return false }
        dlog("intents", "quick action: Resume")
        ResumeHook.run?()
        return true
    }
}

/// Takes the quick action for the scene; everything else stays SwiftUI's.
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        // Chosen while Folio was closed: once its window is up.
        guard let item = connectionOptions.shortcutItem else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated { _ = QuickActions.perform(item) } }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(MainActor.assumeIsolated { QuickActions.perform(shortcutItem) })
    }
}
