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
            // Control experiment: a plain UIKit popover in the main window, before any video.
            (1.0, "test popover (main window)", { presentTestPopover() }),
            (3.0, "dismiss test popover", { testPopover?.dismiss(animated: true); testPopover = nil }),
            (4.0, "play", { var m = MediaItem(url: url.path, title: "Lab clip", source: .local); m.historyKey = "lab"; PlayerPresenter.play(m) }),
            (8.0, "controls", { ui?.showControls(autoHide: false) }),
            (9.0, "open tracks", { ui?.toggle(.tracks) }),
            (11.0, "close", { ui?.closePanel() }),
            (12.5, "open settings", { ui?.toggle(.settings) }),
            (14.5, "switch to now playing", { ui?.toggle(.nowPlaying) }),
            (16.5, "close", { ui?.closePanel() }),
            (17.5, "media info", { ui?.showInfo = true }),
            (19.0, "stats", { ui?.showInfo = false; ui?.showStats = true }),
            (20.5, "stats off", { ui?.showStats = false }),
            (21.0, "open now playing", { ui?.toggle(.nowPlaying) }),
            (23.0, "close", { ui?.closePanel() }),
            (24.0, "done", { dlog("lab", "done") }),
        ]
        for (t, name, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                dlog("lab", "t=\(t) \(name)")
                action()
            }
        }
    }

    private static var ui: PlayerUIState? { PlayerPresenter.current?.ui }

    private static var testPopover: UIViewController?
    private static func presentTestPopover() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { dlog("lab/error", "no root"); return }
        let vc = UIViewController()
        vc.view.backgroundColor = UIColor.systemPink.withAlphaComponent(0.9)
        vc.preferredContentSize = CGSize(width: 240, height: 160)
        vc.modalPresentationStyle = .popover
        let anchor = UIView(frame: CGRect(x: root.view.bounds.midX - 20, y: root.view.bounds.midY + 120, width: 40, height: 40))
        anchor.backgroundColor = .systemYellow
        root.view.addSubview(anchor)
        vc.popoverPresentationController?.sourceView = anchor
        vc.popoverPresentationController?.sourceRect = anchor.bounds
        vc.popoverPresentationController?.permittedArrowDirections = [.down]
        testPopover = vc
        root.present(vc, animated: true)
        DispatchQueue.main.async { AnimTracer.trace("control popover (main window)", view: vc.view) }
        dlog("lab", "test popover presented from main window")
    }
}
