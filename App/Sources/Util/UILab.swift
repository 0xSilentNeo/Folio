import UIKit

/// Scripted run for the CI simulator recording (launch argument `-uiLab`):
/// plays the bundled clip and drives the player chrome on a timer so the
/// resulting video shows every panel opening, switching and closing.
@MainActor
enum UILab {
    static var enabled: Bool { CommandLine.arguments.contains("-uiLab") }

    static func start() {
        guard enabled else { return }
        dlog("lab", "UI lab run")
        UserDefaults.standard.set(false, forKey: SettingsKey.resumePlayback)
        UserDefaults.standard.set(true, forKey: SettingsKey.landscapeOnOpen)
        if CommandLine.arguments.contains("-labGL") { UserDefaults.standard.set("gl", forKey: SettingsKey.renderer) }
        guard let url = Bundle.main.url(forResource: "lab", withExtension: "mp4", subdirectory: "lab") ?? Bundle.main.url(forResource: "lab", withExtension: "mp4") else { dlog("lab/error", "lab.mp4 missing"); return }
        let steps: [(Double, String, () -> Void)] = [
            (2.0, "play", { var m = MediaItem(url: url.path, title: "Lab clip", source: .local); m.historyKey = "lab"; PlayerPresenter.play(m) }),
            (5.0, "controls", { ui?.showControls(autoHide: false) }),
            (6.0, "open tracks", { ui?.toggle(.tracks) }),
            (8.0, "close", { ui?.closePanel() }),
            (9.5, "open settings", { ui?.toggle(.settings) }),
            (11.5, "switch to now playing", { ui?.toggle(.nowPlaying) }),
            (13.5, "close", { ui?.closePanel() }),
            (14.5, "media info", { ui?.showInfo = true }),
            (16.0, "stats", { ui?.showInfo = false; ui?.showStats = true }),
            (17.5, "stats off", { ui?.showStats = false }),
            (18.0, "open now playing", { ui?.toggle(.nowPlaying) }),
            (20.0, "close", { ui?.closePanel() }),
            (21.0, "done", { dlog("lab", "done") }),
        ]
        for (t, name, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                dlog("lab", "t=\(t) \(name)")
                action()
            }
        }
    }

    private static var ui: PlayerUIState? { PlayerPresenter.current?.ui }
}
