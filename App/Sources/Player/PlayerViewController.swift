import UIKit
import SwiftUI

/// UI-only state for the player screen.
@MainActor
final class PlayerUIState: ObservableObject {
    enum Panel: String, Identifiable { case settings, tracks, nowPlaying; var id: String { rawValue } }

    @Published var controlsVisible = true
    @Published var locked = false
    @Published var showInfo = false
    @Published var panel: Panel?
    @Published var showStats = false
    @Published var showTune = false
    /// UIKit views behind the panel buttons (iOS 17/18 pill); popovers are presented from them.
    var anchors: [Panel: UIView] = [:]
    /// iOS 26: the panel buttons as bar items in a toolbar (popover sources).
    var barItems: [Panel: UIBarButtonItem] = [:]
    weak var panelBar: UIView?
    var menuOpen = false

    func toggle(_ p: Panel) {
        panel = panel == p ? nil : p
        dlog("ui", "panel \(panel?.rawValue ?? "closed")")
        if panel == nil { scheduleHide() } else { showControls(autoHide: false) }
    }

    func closePanel() {
        guard panel != nil else { return }
        panel = nil
        scheduleHide()
    }
    @Published var scrubbing = false
    @Published var scrubTime: Double?
    @Published var gestureHUD: GestureHUD?
    @Published var rotationLocked = false
    @Published var showRemaining = false
    @Published var showConsole = false

    struct GestureHUD: Equatable {
        enum Kind { case seek, brightness, volume, generic }
        var icon: String
        var text: String
        var progress: Double?
        var kind: Kind = .generic
    }

    private var hideWork: DispatchWorkItem?

    func showControls(autoHide: Bool = true) {
        controlsVisible = true
        if autoHide { scheduleHide() } else { hideWork?.cancel() }
    }

    func toggleControls() {
        if controlsVisible { controlsVisible = false; hideWork?.cancel() } else { showControls() }
    }

    func scheduleHide(after seconds: Double = 4) {
        hideWork?.cancel()
        if UILab.uiTest { return }   // keep controls up while the UI test taps
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.showInfo, !self.showStats, !self.showTune, !self.scrubbing, !self.showConsole, !self.menuOpen, self.panel == nil else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.controlsVisible = false }
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }
}

final class PlayerViewController: UIHostingController<PlayerScreen> {
    let model: PlayerModel
    let ui: PlayerUIState
    private var orientationMask: UIInterfaceOrientationMask = .allButUpsideDown

    init(model: PlayerModel) {
        let ui = PlayerUIState()
        self.model = model
        self.ui = ui
        super.init(rootView: PlayerScreen(model: model, ui: ui))
        modalPresentationStyle = .fullScreen
        modalPresentationCapturesStatusBarAppearance = true
        overrideUserInterfaceStyle = .dark
    }

    required init?(coder aDecoder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        rootView.onRotationLock = { [weak self] locked in self?.setRotationLocked(locked) }
        rootView.onClose = { [weak self] in self?.closePlayer() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        // Start once the video surface has its real size (the Metal
        // swapchain is created from it).
        model.start()
        if UserDefaults.standard.bool(forKey: SettingsKey.landscapeOnOpen), UIDevice.current.userInterfaceIdiom == .phone,
           model.videoSize == .zero || model.videoSize.width >= model.videoSize.height {
            requestOrientation(.landscape)
        }
    }

    override var canBecomeFirstResponder: Bool { true }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { orientationMask }

    func closePlayer(animated: Bool = true) {
        model.close()
        PlayerPresenter.dismiss(animated: animated)
    }

    private func setRotationLocked(_ locked: Bool) {
        if locked, let o = view.window?.windowScene?.interfaceOrientation {
            switch o {
            case .landscapeLeft: orientationMask = .landscapeLeft
            case .landscapeRight: orientationMask = .landscapeRight
            case .portraitUpsideDown: orientationMask = .portraitUpsideDown
            default: orientationMask = .portrait
            }
        } else {
            orientationMask = .allButUpsideDown
        }
        setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private func requestOrientation(_ mask: UIInterfaceOrientationMask) {
        guard let scene = view.window?.windowScene ?? UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    // MARK: Hardware keyboard -> mpv

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key, let name = Self.mpvKeyName(key) {
                if name == "ESC", model.client == nil { continue }
                model.keyDown(name)
                handled = true
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key, let name = Self.mpvKeyName(key) {
                model.keyUp(name)
                handled = true
            }
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }

    static func mpvKeyName(_ key: UIKey) -> String? {
        var base: String?
        switch key.keyCode {
        case .keyboardLeftArrow: base = "LEFT"
        case .keyboardRightArrow: base = "RIGHT"
        case .keyboardUpArrow: base = "UP"
        case .keyboardDownArrow: base = "DOWN"
        case .keyboardReturnOrEnter, .keypadEnter: base = "ENTER"
        case .keyboardEscape: base = "ESC"
        case .keyboardSpacebar: base = "SPACE"
        case .keyboardTab: base = "TAB"
        case .keyboardDeleteOrBackspace: base = "BS"
        case .keyboardDeleteForward: base = "DEL"
        case .keyboardPageUp: base = "PGUP"
        case .keyboardPageDown: base = "PGDWN"
        case .keyboardHome: base = "HOME"
        case .keyboardEnd: base = "END"
        case .keyboardInsert: base = "INS"
        case .keyboardF1: base = "F1"
        case .keyboardF2: base = "F2"
        case .keyboardF3: base = "F3"
        case .keyboardF4: base = "F4"
        case .keyboardF5: base = "F5"
        case .keyboardF6: base = "F6"
        case .keyboardF7: base = "F7"
        case .keyboardF8: base = "F8"
        case .keyboardF9: base = "F9"
        case .keyboardF10: base = "F10"
        case .keyboardF11: base = "F11"
        case .keyboardF12: base = "F12"
        case .keyboardLeftShift, .keyboardRightShift, .keyboardLeftControl, .keyboardRightControl,
             .keyboardLeftAlt, .keyboardRightAlt, .keyboardLeftGUI, .keyboardRightGUI, .keyboardCapsLock:
            return nil
        default: break
        }

        var mods = key.modifierFlags
        if base == nil {
            let chars = key.characters.isEmpty ? key.charactersIgnoringModifiers : key.characters
            // With Ctrl/Alt/Cmd, use the unmodified key so "Ctrl+t" stays "t".
            let raw = mods.contains(.control) || mods.contains(.alternate) || mods.contains(.command)
                ? key.charactersIgnoringModifiers : chars
            guard let ch = raw.first else { return nil }
            switch ch {
            case "#": base = "SHARP"
            case " ": base = "SPACE"
            default: base = String(ch)
            }
            // Shift is already reflected in the character for printable keys.
            if !(mods.contains(.control) || mods.contains(.alternate) || mods.contains(.command)) {
                mods.remove(.shift)
            } else if ch.isLetter {
                base = mods.contains(.shift) ? String(ch).uppercased() : String(ch).lowercased()
                mods.remove(.shift)
            }
        }
        guard let base else { return nil }
        var prefix = ""
        if mods.contains(.control) { prefix += "Ctrl+" }
        if mods.contains(.alternate) { prefix += "Alt+" }
        if mods.contains(.command) { prefix += "Meta+" }
        if mods.contains(.shift) { prefix += "Shift+" }
        return prefix + base
    }
}

/// Shows the player in its own window above the app. A separate window
/// never depends on whatever view controller happens to be mid-transition
/// (document picker closing, sheet dismissing), which is what used to make
/// "Open file" silently do nothing.
@MainActor
enum PlayerPresenter {
    private static var window: UIWindow?
    private(set) static var current: PlayerViewController?

    static func play(_ item: MediaItem) { play(queue: [item], index: 0) }

    static func play(queue: [MediaItem], index: Int) {
        dlog("player", "play requested: \(queue.count) item(s), index \(index), first=\(queue.first?.mpvPath ?? "")")
        if let existing = current {
            dlog("player", "closing previous player first")
            existing.closePlayer(animated: false)
        }
        guard let model = PlayerModel(queue: queue.map { $0.preparedForPlayback() }, startIndex: index) else {
            dlog("player/error", "could not create PlayerModel")
            return
        }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            dlog("player/error", "no window scene")
            return
        }
        let vc = PlayerViewController(model: model)
        let w = PlayerWindowMarker(windowScene: scene)
        w.windowLevel = .normal + 1
        w.backgroundColor = .black
        w.rootViewController = vc
        w.alpha = 0
        w.makeKeyAndVisible()
        window = w
        current = vc
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) { w.alpha = 1 }
    }

    static func dismiss(animated: Bool) {
        guard let w = window else { return }
        let done = {
            w.isHidden = true
            w.rootViewController = nil
            if window === w { window = nil }
            current = nil
            // Give focus back to the app window.
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first { !($0 is PlayerWindowMarker) }?.makeKey()
        }
        if animated { UIView.animate(withDuration: 0.2, animations: { w.alpha = 0 }, completion: { _ in done() }) } else { done() }
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let playerWindow = window
        let windows = scenes.flatMap(\.windows).filter { $0 !== playerWindow }
        let target = windows.first { $0.isKeyWindow } ?? windows.first
        var vc = target?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }
}

private class PlayerWindowMarker: UIWindow {}
