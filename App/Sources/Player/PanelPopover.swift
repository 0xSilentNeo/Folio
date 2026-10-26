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

    /// `passthrough`: the player's view. Touches outside the panel go to the
    /// player, whose tap-catcher closes the panel (UIKit never dismisses it).
    private(set) var passthrough: [UIView] = []
    func configure(source: PanelSource, anchor: UIView?, passthrough: [UIView], bottomInset: CGFloat) {
        self.anchor = anchor
        self.passthrough = passthrough
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
        pc.passthroughViews = passthrough
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

    /// The popover's own view (glass background + this controller's view),
    /// faded out when panels are switched programmatically.
    var popoverView: UIView? {
        guard let container = presentationController?.containerView else { return nil }
        var v: UIView? = view
        while let cur = v, cur.superview !== container { v = cur.superview }
        return v
    }

    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }
    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }
    /// A question, not a request: iOS accessibility (VoiceOver, Switch Control,
    /// UI-test snapshots) asks it whenever it reads the screen. Answering with
    /// a close shut panels by themselves ~1 s after opening in CI. The answer
    /// is always "no"; a real tap outside then arrives as an *attempt* below.
    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool { false }

    /// Not sent for popovers in practice (CI: never called); kept in case a
    /// future iOS routes outside taps here instead of through the passthrough.
    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        onOutsideTap?()
    }

    /// VoiceOver's escape gesture (two-finger Z) closes the panel the same way.
    override func accessibilityPerformEscape() -> Bool {
        onOutsideTap?()
        return true
    }
}

/// Owns the one open panel popover and moves the screen toward the panel the
/// user wants, one UIKit transition at a time.
///
/// A tap only records which panel is wanted; `reconcile()` moves the screen
/// toward it (close what's shown, then open the wanted one). Every transition
/// carries a generation number: a completion from an older transition does
/// nothing. (1.12.0: the delayed "open finished" step of one panel ran after
/// an outside tap had begun closing it and re-presented the same panel
/// mid-close → full-screen black panel.)
///
/// Open and close are the system's Liquid Glass morph from the bar item
/// (≈1–1.25 s each on an iPhone 17 Pro, from the device log). UIKit holds
/// touches while it runs and can't be hurried: in the 25 Oct simulator lab a
/// tap 0.15–0.45 s into the morph reached the app only after it ended, and
/// speeding the popover container's layer (or removing its animations) left
/// the morph's length unchanged — iOS 26 doesn't drive it from that clock.
/// A tap that arrives meanwhile is kept and acted on the moment it ends.
///
/// iOS 27 (1.16.0): Outplayer 2026.10's rules, read from its binary, replace the
/// one-transition-at-a-time queue. There, nothing waits for a morph:
/// - another panel: what is on screen is dismissed — instantly, or animated if it
///   is still opening — and the new panel is presented in the same call
///   (`presented.dismiss(animated: presented.isBeingPresented)`, then `present`);
/// - close: the panel morphs back into its button even while it is opening;
/// - a tap on another button while a panel is open opens that panel (PlayerScreen).
/// Outplayer keeps the old waiting behaviour before iOS 27; so does Folio.
@MainActor
final class PanelPresenter {
    static let shared = PanelPresenter()

    /// iOS 27: taps act at once (see above). Before iOS 27: one transition at a time.
    static var interruptible: Bool {
        if #available(iOS 27, *) { return true }
        return false
    }
    /// Panels leaving the screen on the iOS 27 path (their close is still animating).
    private var closing = 0
    /// A switch is waiting for the previous panel's close animation to end (logged once).
    private var waitingForLeave = false

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
        closing = 0
        for vc in [inFlight, shown].compactMap({ $0 }) where vc.presentingViewController != nil {
            vc.dismiss(animated: false)
        }
        shown = nil; shownKind = nil; shownRequest = nil
        generation += 1
        endTransition()
        cache = [:]
        cacheOwner = nil
    }

    private enum Phase: String { case idle, opening, closing }
    /// The UIKit transition running now (none when idle).
    private var phase = Phase.idle
    private var inFlight: PanelPopoverController?

    private var wanted: Request?
    /// Serial number of the last tap; a request is only "already asked" when it
    /// came from this same tap (SwiftUI's onChange re-asks after the button did).
    private var tapSerial = 0
    private var wantedSerial = -1
    private var shown: PanelPopoverController?
    private var shownKind: String?
    private var shownRequest: Request?
    private var generation = 0
    private let frames = FrameMonitor()
    private var tapTime: CFTimeInterval = 0
    /// A close is running / finished (the player keeps its tap-catcher up meanwhile).
    var onClosing: ((Bool) -> Void)?

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
        dlog("ui", "panel: want \(kind) (shown=\(shownKind ?? "none") \(phase.rawValue))")
        wanted = Request(kind: kind, presenter: presenter, make: { [weak self] in
            guard let self else { return PanelPopoverController(content: content()) }
            let vc = self.controller(kind: kind, sizeKey: sizeKey, owner: owner, content: content)
            vc.configure(source: source, anchor: anchor, passthrough: [presenter.topMostPresented.view], bottomInset: bottomInset)
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
        tapTime = CACurrentMediaTime()
        reconcile(animated: animated)
    }

    private func reconcile(animated: Bool = true) {
        if Self.interruptible { reconcileInterruptible(animated: animated); return }
        guard phase == .idle else { return }          // a transition is running; it calls back here when done
        if let vc = shown, vc.presentingViewController == nil, !vc.isBeingPresented {
            shown = nil; shownKind = nil; shownRequest = nil   // went away on its own
        }
        if let vc = shown {
            guard wanted?.kind != shownKind else { return }
            let switching = wanted != nil
            let kind = shownKind ?? "?"
            dlog("ui", "panel: close \(kind)\(switching ? " → \(wanted!.kind)" : "")")
            frames.begin("panel close \(kind)")
            let g = begin(.closing, vc)
            onClosing?(true)
            close(vc, animated: animated, switching: switching) { [weak self] in
                guard let self, self.generation == g else { return }
                if self.shown === vc { self.shown = nil; self.shownKind = nil; self.shownRequest = nil }
                dlog("ui", "panel: closed \(kind)")
                self.frames.end()
                // A non-animated dismiss leaves VoiceOver (and UI tests) seeing the
                // panel for seconds unless told the screen changed.
                UIAccessibility.post(notification: .screenChanged, argument: nil)
                self.finish()
            }
            return
        }
        guard let req = wanted else { return }
        let buildStart = CACurrentMediaTime()
        let vc = req.make()
        guard !vc.isInUse else {
            // Still leaving the screen from an earlier close: look again next frame.
            NextFrame.run { [weak self] in self?.reconcile() }
            return
        }
        vc.loadViewIfNeeded()                         // size known before the transition starts
        let buildMs = (CACurrentMediaTime() - buildStart) * 1000
        let host = req.presenter.topMostPresented
        guard host.view.window != nil, !host.isBeingDismissed, !host.isBeingPresented, host !== vc else {
            NextFrame.run { [weak self] in self?.reconcile() }
            return
        }
        shown = vc
        shownKind = req.kind
        shownRequest = req
        dlog("ui", "panel: open \(req.kind)")
        frames.begin("panel open \(req.kind)")
        frames.note(String(format: "built in %.0f ms, %.0f ms after the tap", buildMs, (CACurrentMediaTime() - tapTime) * 1000))
        let g = begin(.opening, vc)
        open(vc, from: host, animated: animated) { [weak self] in
            guard let self, self.generation == g else { return }
            dlog("ui", "panel: opened \(req.kind)")
            self.frames.end()
            UIAccessibility.post(notification: .screenChanged, argument: vc.view)
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

    // MARK: iOS 27: nothing waits

    private func reconcileInterruptible(animated: Bool) {
        if let vc = shown, vc.presentingViewController == nil, !vc.isBeingPresented {
            shown = nil; shownKind = nil; shownRequest = nil   // went away on its own
        }

        // Close: the panel morphs back into its button, even if it is still opening.
        guard let req = wanted else {
            guard let vc = shown else { return }
            let kind = shownKind ?? "?"
            shown = nil; shownKind = nil; shownRequest = nil
            guard !vc.isBeingDismissed else { return }
            dlog("ui", "panel: close \(kind)\(vc.isBeingPresented ? " (still opening)" : "")")
            frames.begin("panel close \(kind)")
            closing += 1
            onClosing?(true)
            vc.dismiss(animated: animated) { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.closing = max(0, self.closing - 1)
                    dlog("ui", "panel: closed \(kind)")
                    self.frames.end()
                    if self.closing == 0 { self.onClosing?(false) }
                    UIAccessibility.post(notification: .screenChanged, argument: nil)
                }
            }
            return
        }
        guard req.kind != shownKind else { return }

        // The player's controller: the one under any panel that is up or leaving.
        var host = req.presenter.topMostPresented
        if host is PanelPopoverController, let below = host.presentingViewController { host = below }
        guard host.view.window != nil, !host.isBeingPresented, !host.isBeingDismissed else {
            NextFrame.run { [weak self] in self?.reconcile() }
            return
        }

        // Another panel is up: out at once — animated only while it is still opening — and the
        // new one goes up in this same call. UIKit presents nothing while a panel is still
        // leaving with its close animation (iOS 27.0 simulator: up to ~1.2 s when the old one
        // was still opening), so then the new one goes up the moment that ends.
        if let presented = host.presentedViewController {
            if presented.isBeingDismissed {
                if !waitingForLeave {
                    waitingForLeave = true
                    dlog("ui", "panel: \(req.kind) waits for the leaving panel")
                }
                shown = nil; shownKind = nil; shownRequest = nil
                NextFrame.run { [weak self] in self?.reconcile() }
                return
            }
            let animatedOut = animated && presented.isBeingPresented
            dlog("ui", "panel: \(shownKind ?? "panel") out \(animatedOut ? "(animated, still opening)" : "(instant)") → \(req.kind)")
            presented.dismiss(animated: animatedOut)
            shown = nil; shownKind = nil; shownRequest = nil
            if animatedOut {
                // Its close animation runs; the new panel goes up when it ends.
                NextFrame.run { [weak self] in self?.reconcile() }
                return
            }
            // Instant: present in this same call, as Outplayer does (the retry below covers a refusal).
        }
        waitingForLeave = false
        shown = nil; shownKind = nil; shownRequest = nil

        let buildStart = CACurrentMediaTime()
        let vc = req.make()
        guard !vc.isInUse else {
            NextFrame.run { [weak self] in self?.reconcile() }
            return
        }
        vc.loadViewIfNeeded()
        let buildMs = (CACurrentMediaTime() - buildStart) * 1000
        shown = vc
        shownKind = req.kind
        shownRequest = req
        dlog("ui", "panel: open \(req.kind)")
        frames.begin("panel open \(req.kind)")
        frames.note(String(format: "built in %.0f ms, %.0f ms after the tap", buildMs, (CACurrentMediaTime() - tapTime) * 1000))
        host.present(vc, animated: animated) { [weak self, weak vc] in
            guard let vc else { return }
            // UIKit makes the bar passthrough for bar-item popovers; set ours back.
            vc.popoverPresentationController?.passthroughViews = vc.passthrough
            DispatchQueue.main.async {
                guard let self, self.shown === vc else { return }
                dlog("ui", "panel: opened \(req.kind)")
                self.frames.end()
                UIAccessibility.post(notification: .screenChanged, argument: vc.view)
                if !(vc.presentationController is UIPopoverPresentationController)
                    || vc.popoverView?.bounds.width ?? 0 >= (host.view.window?.bounds.width ?? .infinity) - 1 {
                    dlog("ui/error", "panel \(req.kind) came up full screen; closing it")
                    vc.dismiss(animated: false)
                    self.shown = nil; self.shownKind = nil; self.shownRequest = nil
                    self.wanted = nil
                    req.onClosedByTap()
                }
            }
        }
        // Should UIKit still refuse the presentation, try again next frame.
        NextFrame.run { [weak self, weak vc] in
            guard let self, let vc, self.shown === vc,
                  vc.presentingViewController == nil, !vc.isBeingPresented else { return }
            dlog("ui", "panel: \(req.kind) was not presented; retrying")
            self.shown = nil; self.shownKind = nil; self.shownRequest = nil
            self.reconcile()
        }
    }

    // MARK: Transitions

    /// The system's own presentation: on iOS 26 the popover "animates from
    /// and replaces" its bar item (UIPopoverPresentationController.sourceItem
    /// docs) — the button's glass grows into the panel. Nothing else runs on
    /// the main thread at the tap (1.15.0 took a snapshot of the video here).
    private func open(_ vc: PanelPopoverController, from host: UIViewController, animated: Bool, done: @escaping () -> Void) {
        host.present(vc, animated: animated) {
            // UIKit makes the bar passthrough for bar-item popovers on presentation;
            // set ours back (the player's view: its tap-catcher closes the panel).
            vc.popoverPresentationController?.passthroughViews = vc.passthrough
            Self.afterTransition(of: vc, then: done)
        }
    }

    /// The system's own dismissal: the panel goes back into its button. Only
    /// a programmatic switch (no tap can do that now; the replay test does)
    /// fades the old panel out first so two morphs never overlap.
    private func close(_ vc: PanelPopoverController, animated: Bool, switching: Bool, done: @escaping () -> Void) {
        let next = { Self.afterTransition(of: vc, then: done) }
        guard animated else { vc.dismiss(animated: false, completion: next); return }
        if switching, let pv = vc.popoverView {
            UIView.animate(withDuration: 0.10, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
                pv.alpha = 0
            } completion: { _ in
                vc.dismiss(animated: false) { pv.alpha = 1; next() }
            }
        } else {
            vc.dismiss(animated: true, completion: next)
        }
    }

    /// Runs `done` once UIKit has let go of `vc`'s transition: never inside
    /// UIKit's completion (1.10.0 freeze replay: a dismiss started from inside
    /// a present's completion never finished), but on the next run-loop turn,
    /// or the first frame after that on which UIKit's transition state is clear.
    /// Replaces 1.15.0's fixed 0.12 s pause after every open.
    private static func afterTransition(of vc: UIViewController, then done: @escaping () -> Void, frames: Int = 0) {
        DispatchQueue.main.async {
            let busy = vc.isBeingPresented || vc.isBeingDismissed || vc.transitionCoordinator != nil
            if busy && frames < 30 {
                NextFrame.run { afterTransition(of: vc, then: done, frames: frames + 1) }
            } else {
                if busy { dlog("ui/error", "panel: UIKit still mid-transition after 30 frames; going on") }
                done()
            }
        }
    }

    // MARK: Phase / watchdog

    /// Starts a transition: it runs until its completion (matching generation)
    /// calls `finish()`. A watchdog recovers if UIKit never reports back.
    private func begin(_ p: Phase, _ vc: PanelPopoverController) -> Int {
        phase = p
        inFlight = vc
        generation += 1
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self, weak vc] in
            guard let self, self.phase != .idle, self.generation == g else { return }
            if let vc, vc.isBeingPresented || vc.isBeingDismissed {
                // Still animating: give it one more chance.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self, self.phase != .idle, self.generation == g else { return }
                    self.recover()
                }
                return
            }
            self.recover()
        }
        return g
    }

    private func recover() {
        dlog("ui/error", "panel \(phase.rawValue) did not finish; recovering (shown=\(shownKind ?? "nil") presented=\(shown?.presentingViewController != nil))")
        generation += 1
        for vc in [inFlight, shown].compactMap({ $0 }) {
            if let pv = vc.popoverView { pv.alpha = 1; pv.transform = .identity }
        }
        if let vc = shown, vc.presentingViewController == nil { shown = nil; shownKind = nil; shownRequest = nil }
        endTransition()
        reconcile()
    }

    private func finish() {
        endTransition()
        reconcile()
    }

    private func endTransition() {
        phase = .idle
        inFlight = nil
        onClosing?(false)                              // whatever finished, no close is running now
    }
}

/// Runs a closure on the next display frame — for "look again once UIKit has
/// moved on", instead of a guessed delay.
@MainActor
private final class NextFrame: NSObject {
    private var link: CADisplayLink?
    private var action: (() -> Void)?

    static func run(_ action: @escaping () -> Void) {
        let f = NextFrame()
        f.action = action
        let l = CADisplayLink(target: f, selector: #selector(tick))   // the link keeps `f` alive until it fires
        l.add(to: .main, forMode: .common)
        f.link = l
    }

    @objc private func tick() {
        link?.invalidate()
        link = nil
        let a = action
        action = nil
        a?()
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
