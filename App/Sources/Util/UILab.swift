import UIKit

/// Scripted run for the CI simulator recording (launch argument `-uiLab`):
/// plays the bundled clip and drives the player chrome on a timer so the
/// resulting video shows every panel opening, switching and closing.
@MainActor
enum UILab {
    static var enabled: Bool { CommandLine.arguments.contains("-uiLab") || uiTest }
    /// XCUITest run: just open the player with the bundled clip; the test taps.
    static var uiTest: Bool { CommandLine.arguments.contains("-uiTest") }

    static func start() {
        guard enabled else { return }
        if uiTest {
            UserDefaults.standard.set(false, forKey: SettingsKey.resumePlayback)
            guard let url = Bundle.main.url(forResource: "lab", withExtension: "mp4", subdirectory: "lab") ?? Bundle.main.url(forResource: "lab", withExtension: "mp4") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                var m = MediaItem(url: url.path, title: "Lab clip", source: .local); m.historyKey = "lab"
                PlayerPresenter.play(m)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { PlayerPresenter.current?.ui.showControls(autoHide: false) }
            return
        }
        dlog("lab", "UI lab run")
        UserDefaults.standard.set(false, forKey: SettingsKey.resumePlayback)
        UserDefaults.standard.set(true, forKey: SettingsKey.landscapeOnOpen)
        if CommandLine.arguments.contains("-labGL") { UserDefaults.standard.set("gl", forKey: SettingsKey.renderer) }
        guard let url = Bundle.main.url(forResource: "lab", withExtension: "mp4", subdirectory: "lab") ?? Bundle.main.url(forResource: "lab", withExtension: "mp4") else { dlog("lab/error", "lab.mp4 missing"); return }
        let steps: [(Double, String, () -> Void)] = [
            // Ground truth: can anything animate in this process at all?
            (0.5, "flags", {
                dlog("lab", "animationsEnabled=\(UIView.areAnimationsEnabled) reduceMotion=\(UIAccessibility.isReduceMotionEnabled) crossFade=\(UIAccessibility.prefersCrossFadeTransitions) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)")
                alphaTest()
            }),
            // Control experiment: a plain UIKit popover in the main window, before any video.
            (1.5, "test popover (main window)", { presentTestPopover() }),
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

    /// A plain UIView.animate alpha fade, traced: if this snaps, nothing in the process animates.
    private static func alphaTest() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.windows.first(where: { $0.isKeyWindow }) else { return }
        let v = UIView(frame: CGRect(x: 40, y: 200, width: 120, height: 120))
        v.backgroundColor = .systemTeal
        window.addSubview(v)
        UIView.animate(withDuration: 0.6) { v.alpha = 0.2; v.transform = CGAffineTransform(scaleX: 2, y: 2) } completion: { _ in v.removeFromSuperview() }
    }
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
        dlog("lab", "test popover presented from main window")
    }
}
