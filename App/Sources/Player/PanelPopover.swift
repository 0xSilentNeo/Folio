import SwiftUI
import UIKit

/// Player panels are UIKit popovers with the SYSTEM popover background,
/// presented from bar button items in a UIToolbar — Outplayer's construction
/// on Liquid Glass (`videoMenuBarButtonItem` in `toolbar`). On iOS 26 the
/// bar item's own glass then morphs into the panel. Verified in the CI pop
/// lab: a custom (transparent) popover background, which 1.9.6–1.9.8 used,
/// switches that morph off and the panel just appears.

/// Legacy transparent background (kept for the pop lab comparison only).
final class ClearPopoverBackground: UIPopoverBackgroundView {
    private var _offset: CGFloat = 0
    private var _direction: UIPopoverArrowDirection = .down
    override var arrowOffset: CGFloat { get { _offset } set { _offset = newValue } }
    override var arrowDirection: UIPopoverArrowDirection { get { _direction } set { _direction = newValue } }
    override class func arrowBase() -> CGFloat { 0 }
    override class func arrowHeight() -> CGFloat { 0 }
    override class func contentViewInsets() -> UIEdgeInsets { .zero }
    override class var wantsDefaultContentAppearance: Bool { false }
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .clear; layer.shadowOpacity = 0 }
    required init?(coder: NSCoder) { fatalError() }
}

enum PanelSource {
    case item(UIBarButtonItem)
    case view(UIView)
}

final class PanelPopoverController: UIViewController, UIPopoverPresentationControllerDelegate {
    private let host: UIHostingController<AnyView>
    /// UIKit wants to close the panel (a tap outside it, including where the
    /// pill was). The presenter closes it itself, so a close never races with
    /// one UIKit started on its own.
    var onOutsideTap: (() -> Void)?
    /// The view the panel grows out of / shrinks into (the button bar).
    weak var anchor: UIView?

    /// Built once per panel and kept: building the SwiftUI content (Settings
    /// especially) took up to 0.6 s in the simulator, on the main thread,
    /// before the animation could start. Each presentation only re-points the
    /// popover at its button.
    init(content: AnyView) {
        host = UIHostingController(rootView: content)
        super.init(nibName: nil, bundle: nil)
        overrideUserInterfaceStyle = .dark
        host.view.backgroundColor = .clear
        host.sizingOptions = [.preferredContentSize]
        if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// True while UIKit still has this controller on screen or mid-transition:
    /// it must not be presented again until that is over (1.12.0 did, and the
    /// panel came back full screen and black).
    var isInUse: Bool { presentingViewController != nil || isBeingPresented || isBeingDismissed }

    func configure(source: PanelSource, anchor: UIView?, bottomInset: CGFloat) {
        self.anchor = anchor
        modalPresentationStyle = .popover
        guard let pc = popoverPresentationController else { return }
        pc.delegate = self
        switch source {
        case .item(let item):
            pc.sourceItem = item
        case .view(let v):
            pc.sourceView = v
            pc.sourceRect = v.bounds
            pc.permittedArrowDirections = [.down]
        }
        // Nothing passes through: any tap outside the panel closes it.
        pc.passthroughViews = []
        // Keep the panel clear of the top buttons and the button bar.
        pc.popoverLayoutMargins = UIEdgeInsets(top: 66, left: 16, bottom: bottomInset, right: 16)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.clipsToBounds = true
        addChild(host)
        // Fixed size, not pinned to the edges: while the glass morphs, the
        // popover's bounds change every frame, and pinned content was laid out
        // again on every one of them (the late frames during opening).
        host.view.translatesAutoresizingMaskIntoConstraints = true
        host.view.autoresizingMask = []
        view.addSubview(host.view)
        host.didMove(toParent: self)
        preferredContentSize = host.sizeThatFits(in: CGSize(width: 10_000, height: 10_000))
        host.view.frame = CGRect(origin: .zero, size: preferredContentSize)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = preferredContentSize
        guard size.width > 0 else { return }
        if host.view.bounds.size != size { host.view.bounds.size = size }
        host.view.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    }

    /// Lays the content out ahead of time (called while the player is idle).
    func prewarm() {
        loadViewIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
    }

    override func preferredContentSizeDidChange(forChildContentContainer container: UIContentContainer) {
        super.preferredContentSizeDidChange(forChildContentContainer: container)
        preferredContentSize = container.preferredContentSize
        view.setNeedsLayout()
    }

    /// The popover's own view (glass background + this controller's view):
    /// what the quick transition fades and scales.
    var popoverView: UIView? {
        guard let container = presentationController?.containerView else { return nil }
        var v: UIView? = view
        while let cur = v, cur.superview !== container { v = cur.superview }
        return v
    }

    /// A transform that moves the popover a little toward its button and
    /// shrinks it, so it appears to grow out of / go back into the bar.
    func towardAnchor(scale: CGFloat, pull: CGFloat) -> CGAffineTransform {
        guard let pv = popoverView, let a = anchor, let container = pv.superview else { return CGAffineTransform(scaleX: scale, y: scale) }
        let ac = a.convert(CGPoint(x: a.bounds.midX, y: a.bounds.midY), to: container)
        let dx = (ac.x - pv.center.x) * pull, dy = (ac.y - pv.center.y) * pull
        return CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
    }

    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }
    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }
    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        onOutsideTap?()
        return false
    }
}

/// Owns the one open panel popover and runs ONE transition at a time.
///
/// A tap only records which panel is wanted; `reconcile()` moves the screen
/// toward it step by step (close what's shown, then open the wanted one).
/// Every transition carries a generation number: a completion from an older
/// transition does nothing. (1.12.0: the delayed "open finished" step of one
/// panel ran after an outside tap had begun closing it, cleared the busy flag
/// and re-presented the same panel mid-close → full-screen black panel.)
///
/// Styles (Settings → Player → Menu animation):
/// - quick (default): present/dismiss without UIKit animation; the panel
///   grows out of the bar in 0.24 s and shrinks back in 0.16 s. No glass
///   blob, and a tap is never kept waiting behind a 1 s system animation.
/// - morph / morphFrozen: the system Liquid Glass morph (≈1–1.25 s per
///   open or close on an iPhone 17 Pro, measured from the device log).
@MainActor
final class PanelPresenter {
    static let shared = PanelPresenter()

    private struct Request {
        let kind: String
        let presenter: UIViewController
        let make: () -> PanelPopoverController
        let onClosedByTap: () -> Void
    }
    /// Built panels, per player and size (rebuilt after rotation or a new player).
    private var cache: [String: PanelPopoverController] = [:]
    private var cacheOwner: ObjectIdentifier?

    private func controller(kind: String, sizeKey: String, owner: ObjectIdentifier, content: () -> AnyView) -> PanelPopoverController {
        if cacheOwner != owner { cache = [:]; cacheOwner = owner }
        let key = kind + "|" + sizeKey
        if let c = cache[key], !c.isInUse || c === shown { return c }
        if cache[key] != nil { dlog("ui", "panel: \(kind) still in use; building a fresh one") }
        let c = PanelPopoverController(content: content())
        cache[key] = c
        return c
    }

    /// Builds and lays out a panel while nothing is happening, so the first
    /// tap doesn't pay for it.
    func prewarm(kind: String, sizeKey: String, owner: ObjectIdentifier, content: () -> AnyView) {
        let t = CACurrentMediaTime()
        controller(kind: kind, sizeKey: sizeKey, owner: owner, content: content).prewarm()
        dlog("perf", String(format: "panel %@ prebuilt in %.0f ms", kind, (CACurrentMediaTime() - t) * 1000))
    }

    /// Player closed: drop the built panels.
    func reset() {
        wanted = nil
        if let vc = shown, vc.presentingViewController != nil { vc.dismiss(animated: false) }
        shown = nil; shownKind = nil; busy = false; generation += 1
        cache = [:]
        cacheOwner = nil
    }

    private var wanted: Request?
    /// Serial number of the last tap; a request is only "already asked" when it
    /// came from this same tap (SwiftUI's onChange re-asks after the button did).
    private var tapSerial = 0
    private var wantedSerial = -1
    private var shown: PanelPopoverController?
    private var shownKind: String?
    private var shownRequest: Request?
    private var busy = false
    private var generation = 0
    private let frames = FrameMonitor()
    private var tapTime: CFTimeInterval = 0
    /// Called just before a morph starts (the player freezes the video picture).
    var onTransitionStart: ((Double) -> Void)?
    private var style: String {
        let s = UserDefaults.standard.string(forKey: SettingsKey.panelTransition) ?? "quick"
        return ["morph", "morphFrozen"].contains(s) ? s : "quick"
    }
    private var quick: Bool { style == "quick" }

    /// `immediate`: called straight from the button's action (not from inside
    /// a SwiftUI update), so start in this run-loop turn — no extra frame.
    /// `onClosedByTap`: the panel was closed by a tap outside it.
    func show(kind: String, sizeKey: String, owner: ObjectIdentifier, content: @escaping () -> AnyView, source: PanelSource,
              anchor: UIView?, from presenter: UIViewController, bottomInset: CGFloat,
              immediate: Bool = false, onClosedByTap: @escaping () -> Void) {
        if immediate { tapSerial += 1 }
        if wanted?.kind == kind, wantedSerial == tapSerial { return }
        wantedSerial = tapSerial
        tapTime = CACurrentMediaTime()
        dlog("ui", "panel: want \(kind) (shown=\(shownKind ?? "none") busy=\(busy))")
        wanted = Request(kind: kind, presenter: presenter, make: { [weak self] in
            guard let self else { return PanelPopoverController(content: content()) }
            let vc = self.controller(kind: kind, sizeKey: sizeKey, owner: owner, content: content)
            vc.configure(source: source, anchor: anchor, bottomInset: bottomInset)
            vc.onOutsideTap = { [weak self, weak vc] in
                guard let self, let vc, vc === self.shown else { return }
                dlog("ui", "panel: outside tap closes \(kind)")
                if self.wanted?.kind == kind { self.wanted = nil }
                self.shownRequest?.onClosedByTap()
                self.reconcile()
            }
            return vc
        }, onClosedByTap: onClosedByTap)
        if immediate { reconcile() } else { DispatchQueue.main.async { [weak self] in self?.reconcile() } }
    }

    func hide(animated: Bool = true) {
        wanted = nil
        reconcile(animated: animated)
    }

    private func reconcile(animated: Bool = true) {
        guard !busy else { return }                   // a transition is running; it calls back here when done
        if let vc = shown, vc.presentingViewController == nil, !vc.isBeingPresented {
            shown = nil; shownKind = nil; shownRequest = nil   // went away on its own
        }
        if let vc = shown {
            guard wanted?.kind != shownKind else { return }
            let switching = wanted != nil
            let kind = shownKind ?? "?"
            dlog("ui", "panel: close \(kind)\(switching ? " → \(wanted!.kind)" : "")")
            frames.begin("panel close \(kind) [\(style)]")
            let g = begin()
            close(vc, animated: animated, switching: switching) { [weak self] in
                guard let self, self.generation == g else { return }
                if self.shown === vc { self.shown = nil; self.shownKind = nil; self.shownRequest = nil }
                dlog("ui", "panel: closed \(kind)")
                self.frames.end()
                self.finish()
            }
            return
        }
        guard let req = wanted else { return }
        let buildStart = CACurrentMediaTime()
        let vc = req.make()
        guard !vc.isInUse else {
            // Still leaving the screen from an earlier close: try again next frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.reconcile() }
            return
        }
        vc.loadViewIfNeeded()                         // size known before the transition starts
        let buildMs = (CACurrentMediaTime() - buildStart) * 1000
        let host = req.presenter.topMostPresented
        guard host.view.window != nil, !host.isBeingDismissed, !host.isBeingPresented, host !== vc else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.reconcile() }
            return
        }
        shown = vc
        shownKind = req.kind
        shownRequest = req
        dlog("ui", "panel: open \(req.kind)")
        frames.begin("panel open \(req.kind) [\(style)]")
        frames.note(String(format: "built in %.0f ms, %.0f ms after the tap", buildMs, (CACurrentMediaTime() - tapTime) * 1000))
        let g = begin()
        open(vc, from: host, animated: animated) { [weak self] in
            guard let self, self.generation == g else { return }
            dlog("ui", "panel: opened \(req.kind)")
            self.frames.end()
            // Never leave a panel that came up as anything but a popover.
            if !(vc.presentationController is UIPopoverPresentationController) || vc.popoverView?.bounds.width ?? 0 >= (host.view.window?.bounds.width ?? .infinity) - 1 {
                dlog("ui/error", "panel \(req.kind) came up full screen; closing it")
                vc.dismiss(animated: false)
                self.shown = nil; self.shownKind = nil; self.shownRequest = nil
                self.wanted = nil
                req.onClosedByTap()
            }
            self.finish()
        }
    }

    // MARK: Transitions

    private func open(_ vc: PanelPopoverController, from host: UIViewController, animated: Bool, done: @escaping () -> Void) {
        if quick || !animated {
            host.present(vc, animated: false) {
                vc.popoverPresentationController?.passthroughViews = []
                guard animated, let pv = vc.popoverView else { done(); return }
                pv.alpha = 0
                pv.transform = vc.towardAnchor(scale: 0.86, pull: 0.35)
                UIView.animate(withDuration: 0.24, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
                               options: [.allowUserInteraction, .beginFromCurrentState]) {
                    pv.alpha = 1
                    pv.transform = .identity
                } completion: { _ in done() }
            }
        } else {
            if style == "morphFrozen" { onTransitionStart?(0.45) }
            host.present(vc, animated: true) {
                // UIKit makes the bar passthrough for bar-item popovers on presentation; undo that.
                vc.popoverPresentationController?.passthroughViews = []
                // A dismiss started from inside a present's completion never
                // finished in the replay of the 1.10.0 freeze log: pause first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { done() }
            }
        }
    }

    private func close(_ vc: PanelPopoverController, animated: Bool, switching: Bool, done: @escaping () -> Void) {
        let pv = vc.popoverView
        let finishDismiss = {
            vc.dismiss(animated: false) {
                pv?.alpha = 1; pv?.transform = .identity
                // Next step on the next run-loop turn, not inside UIKit's completion.
                DispatchQueue.main.async { done() }
            }
        }
        guard animated else { finishDismiss(); return }
        if quick || switching, let pv {
            // Quick: shrink back toward the bar and fade (0.16 s). Switching in
            // the morph style: fade in place so the pill never flashes between panels.
            UIView.animate(withDuration: switching && !quick ? 0.10 : 0.16, delay: 0,
                           options: [.curveEaseIn, .beginFromCurrentState, .allowUserInteraction]) {
                pv.alpha = 0
                if quick { pv.transform = vc.towardAnchor(scale: 0.9, pull: 0.3) }
            } completion: { _ in finishDismiss() }
        } else {
            if style == "morphFrozen" { onTransitionStart?(0.45) }
            vc.dismiss(animated: true, completion: done)
        }
    }

    // MARK: Busy / watchdog

    /// Starts a transition: busy until its completion (matching generation)
    /// calls `finish()`. A watchdog recovers if UIKit never reports back.
    private func begin() -> Int {
        busy = true
        generation += 1
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + (quick ? 1.0 : 2.5)) { [weak self] in
            guard let self, self.busy, self.generation == g else { return }
            if let vc = self.shown, vc.isBeingPresented || vc.isBeingDismissed {
                // Still animating: give it one more chance.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self, self.busy, self.generation == g else { return }
                    self.recover()
                }
                return
            }
            self.recover()
        }
        return g
    }

    private func recover() {
        dlog("ui/error", "panel transition did not finish; recovering (shown=\(shownKind ?? "nil") presented=\(shown?.presentingViewController != nil))")
        generation += 1
        if let vc = shown {
            if let pv = vc.popoverView { pv.alpha = 1; pv.transform = .identity }
            if vc.presentingViewController == nil { shown = nil; shownKind = nil; shownRequest = nil }
        }
        busy = false
        reconcile()
    }

    private func finish() {
        busy = false
        reconcile()
    }
}

/// Zero-cost UIView behind a SwiftUI view, so UIKit has a source view.
struct AnchorView: UIViewRepresentable {
    let onView: (UIView) -> Void
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        DispatchQueue.main.async { onView(v) }
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

extension UIViewController {
    var topMostPresented: UIViewController {
        var vc = self
        while let p = vc.presentedViewController, !p.isBeingDismissed { vc = p }
        return vc
    }
}
