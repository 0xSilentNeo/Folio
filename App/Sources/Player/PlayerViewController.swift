import UIKit
import SwiftUI

/// UI-only state for the player screen.
@MainActor
final class PlayerUIState: ObservableObject {
    @Published var controlsVisible = true
    @Published var locked = false
    @Published var showInfo = false
    var menuOpen = false
    @Published var scrubbing = false
    @Published var scrubTime: Double?
    @Published var gestureHUD: GestureHUD?
    @Published var rotationLocked = false
    @Published var showRemaining = false
    @Published var showConsole = false

    struct GestureHUD: Equatable {
        var icon: String
        var text: String
        var progress: Double?
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
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.showInfo, !self.scrubbing, !self.showConsole, !self.menuOpen else { return }
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
        if UserDefaults.standard.bool(forKey: SettingsKey.landscapeOnOpen), UIDevice.current.userInterfaceIdiom == .phone {
            requestOrientation(.landscape)
        }
    }

    override var canBecomeFirstResponder: Bool { true }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { orientationMask }

    func closePlayer() {
        model.close()
        if UIDevice.current.userInterfaceIdiom == .phone { requestOrientation(.portrait) }
        dismiss(animated: true)
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

/// Presents the player full screen from anywhere.
@MainActor
enum PlayerPresenter {
    static func play(_ item: MediaItem) { play(queue: [item], index: 0) }

    static func play(queue: [MediaItem], index: Int) {
        guard let model = PlayerModel(queue: queue.map { $0.preparedForPlayback() }, startIndex: index) else { return }
        let vc = PlayerViewController(model: model)
        present(vc, attempt: 0)
    }

    /// Presents as soon as nothing else is mid-transition. Opening a file
    /// from the document picker, the share sheet or a cold launch from the
    /// Files app all call in while another presentation is still animating,
    /// which UIKit silently refuses.
    private static func present(_ vc: PlayerViewController, attempt: Int) {
        guard attempt < 40 else { return }
        func retry() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { present(vc, attempt: attempt + 1) }
        }
        guard let top = topViewController(), top.view.window != nil else { return retry() }
        if top.isBeingPresented || top.isBeingDismissed || top.transitionCoordinator != nil {
            return retry()
        }
        if let existing = top as? PlayerViewController {
            existing.closePlayer()
            return retry()
        }
        if top is UIDocumentPickerViewController || top is UIActivityViewController {
            top.dismiss(animated: true)
            return retry()
        }
        top.present(vc, animated: true)
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var vc = window?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }
}
