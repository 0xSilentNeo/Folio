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
    /// A panel's closing morph is running (the pill buttons aren't back yet).
    @Published var panelClosing = false
    /// Where each pill button is, in window coordinates (taken when a panel
    /// opens: while a popover is up iOS replaces its bar item).
    var pillFrames: [Panel: CGRect] = [:]

    /// Set by the player screen: presents a panel right away (from the tap).
    var presentNow: ((Panel) -> Void)?

    func toggle(_ p: Panel) {
        panel = panel == p ? nil : p
        dlog("ui", "panel \(panel?.rawValue ?? "closed")")
        if let panel { presentNow?(panel) }
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

    deinit { dlog("player", "player screen state freed") }

    func showControls(autoHide: Bool = true) {
        controlsVisible = true
        if autoHide { scheduleHide() } else { hideWork?.cancel() }
    }

    func toggleControls() {
        if controlsVisible { controlsVisible = false; hideWork?.cancel() } else { showControls() }
    }

    func scheduleHide(after seconds: Double = 4) {
        hideWork?.cancel()
        if UILab.keepControls { return }   // keep controls up while the UI test taps
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
        watchAway()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        // Start once the video surface has its real size (the Metal
        // swapchain is created from it).
        model.start()
        if Self.stayLandscape {
            // Settings → Playback → Stay in landscape: turn now and never go to
            // portrait while playing (the phone still flips between the two landscapes).
            orientationMask = .landscape
            requestOrientation(.landscape)
        } else if UserDefaults.standard.bool(forKey: SettingsKey.landscapeOnOpen), UIDevice.current.userInterfaceIdiom == .phone,
           model.videoSize == .zero || model.videoSize.width >= model.videoSize.height {
            requestOrientation(.landscape)
        }
    }

    override var canBecomeFirstResponder: Bool { true }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    // No edge deferral: deferring makes iOS hold back touches near the screen
    // edges, which delayed or swallowed taps on the bottom-right buttons.
    // The home indicator is only hidden. `-deferEdges` is for the CI comparison.
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        CommandLine.arguments.contains("-deferEdges") ? .all : []
    }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { orientationMask }

    func closePlayer(animated: Bool = true) {
        if !awayObservers.isEmpty { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
        awayObservers.forEach { NotificationCenter.default.removeObserver($0) }
        awayObservers = []
        model.close()
        PlayerPresenter.dismiss(animated: animated)
    }

    // MARK: Away: come back the way round the player was left

    /// iOS shows the app's last snapshot in the app switcher and while the
    /// app comes back, but only when the app comes back the way round the
    /// snapshot was taken. A player left in landscape and opened again with
    /// the phone upright came back upright, with no snapshot that way round:
    /// iOS showed the launch screen (the leaf) in the switcher and for an
    /// instant on the way in (simulator run 29 Oct: the snapshot files iOS
    /// kept, and the recording of the return). So while the app is away the
    /// player only turns the way it was left; it follows the phone again
    /// from the phone's next turn after coming back.
    private var heldWhileAway = false
    private var deviceAtReturn: UIDeviceOrientation = .unknown
    private var awayObservers: [NSObjectProtocol] = []

    private func watchAway() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()   // nested calls are counted
        let nc = NotificationCenter.default
        awayObservers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.holdWhileAway() }
        })
        awayObservers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.deviceAtReturn = UIDevice.current.orientation }
        })
        awayObservers.append(nc.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.phoneTurned() }
        })
    }

    private func holdWhileAway() {
        guard UIDevice.current.userInterfaceIdiom == .phone, let o = view.window?.windowScene?.interfaceOrientation else { return }
        let held: UIInterfaceOrientationMask = switch o {
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        case .portraitUpsideDown: .portraitUpsideDown
        default: .portrait
        }
        deviceAtReturn = .unknown
        guard orientationMask != held else { return }
        heldWhileAway = true
        orientationMask = held
        setNeedsUpdateOfSupportedInterfaceOrientations()
        dlog("player", "away: the player stays \(o.isLandscape ? "landscape" : "upright") until the phone is turned")
    }

    /// The phone turned after coming back: follow it again.
    private func phoneTurned() {
        guard heldWhileAway, UIApplication.shared.applicationState == .active else { return }
        let d = UIDevice.current.orientation
        guard d.isPortrait || d.isLandscape, deviceAtReturn != .unknown, d != deviceAtReturn else { return }
        heldWhileAway = false
        orientationMask = ui.rotationLocked ? orientationMask : Self.stayLandscape ? .landscape : .allButUpsideDown
        setNeedsUpdateOfSupportedInterfaceOrientations()
        dlog("player", "phone turned after coming back: the player follows it again")
    }

    private func setRotationLocked(_ locked: Bool) {
        heldWhileAway = false
        if locked, let o = view.window?.windowScene?.interfaceOrientation {
            switch o {
            case .landscapeLeft: orientationMask = .landscapeLeft
            case .landscapeRight: orientationMask = .landscapeRight
            case .portraitUpsideDown: orientationMask = .portraitUpsideDown
            default: orientationMask = .portrait
            }
        } else {
            orientationMask = Self.stayLandscape ? .landscape : .allButUpsideDown
        }
        setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    static var stayLandscape: Bool {
        UIDevice.current.userInterfaceIdiom == .phone && UserDefaults.standard.bool(forKey: SettingsKey.stayLandscape)
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
/// Window / orientation state, for the log.
@MainActor
func dumpWindows(_ why: String) {
    for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
        dlog("nav", "\(why): scene orientation=\(scene.interfaceOrientation.rawValue) device=\(UIDevice.current.orientation.rawValue) bounds=\(scene.coordinateSpace.bounds.size)")
        for w in scene.windows {
            dlog("nav", "  window \(type(of: w)) level=\(w.windowLevel.rawValue) hidden=\(w.isHidden) alpha=\(w.alpha) key=\(w.isKeyWindow) touch=\(w.isUserInteractionEnabled) frame=\(w.frame) root=\(w.rootViewController.map { String(describing: type(of: $0)) } ?? "nil") presented=\(w.rootViewController?.presentedViewController.map { String(describing: type(of: $0)) } ?? "nil")")
        }
    }
}

extension Notification.Name {
    static let playerWillShow = Notification.Name("GlassPlayer.playerWillShow")
    static let playerDidHide = Notification.Name("GlassPlayer.playerDidHide")
}

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
        NotificationCenter.default.post(name: .playerWillShow, object: nil)
        let vc = PlayerViewController(model: model)
        let w = PlayerWindowMarker(windowScene: scene)
        w.windowLevel = .normal + 1
        w.backgroundColor = .black
        w.overrideUserInterfaceStyle = .dark
        w.rootViewController = vc
        w.alpha = 0
        w.makeKeyAndVisible()
        window = w
        current = vc
        HistoryStore.shared.deferPublishing = true
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) { w.alpha = 1 } completion: { _ in
            // The library window underneath is fully covered: hide it so it
            // does no layout, animation or rendering work during playback.
            guard window === w, !CommandLine.arguments.contains("-keepAppWindow") else { return }
            for other in appWindows { other.isHidden = true }
        }
    }

    /// The app's own windows (everything but the player's).
    private static var appWindows: [UIWindow] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).filter { !($0 is PlayerWindowMarker) && $0.windowLevel == .normal }
    }

    static func dismiss(animated: Bool) {
        guard let w = window else { return }
        for other in appWindows { other.isHidden = false }
        HistoryStore.shared.deferPublishing = false
        let done = {
            w.isHidden = true
            w.rootViewController = nil
            if window === w { window = nil }
            current = nil
            NotificationCenter.default.post(name: .playerDidHide, object: nil)
            restoreOrientation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { dumpWindows("after player closed") }
            // Give focus back to the app window.
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first { !($0 is PlayerWindowMarker) }?.makeKey()
        }
        if animated { UIView.animate(withDuration: 0.2, animations: { w.alpha = 0 }, completion: { _ in done() }) } else { done() }
    }

    /// The player turns the screen to landscape. Back in the library, follow
    /// the phone again: if it's upright, return to portrait. Otherwise the
    /// library stayed in landscape on an upright phone, and taps landed in
    /// the wrong place (Back and the edge swipe stopped working).
    private static func restoreOrientation() {
        guard UIDevice.current.userInterfaceIdiom == .phone,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let d = UIDevice.current.orientation
        guard !d.isLandscape, scene.interfaceOrientation.isLandscape else { return }
        dlog("nav", "player closed: back to portrait (phone is upright)")
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { e in dlog("nav/error", "portrait request: \(e.localizedDescription)") }
        for w in scene.windows { w.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let playerWindow = window
        if let player = current, playerWindow != nil { return player.topMostPresented }
        let windows = scenes.flatMap(\.windows).filter { $0 !== playerWindow }
        let target = windows.first { $0.isKeyWindow } ?? windows.first
        var vc = target?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }
}

/// The player's own window: always dark, whatever the app's appearance.
final class PlayerWindowMarker: UIWindow {}
