import SwiftUI
import UIKit

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

/// Animates the panel morphing in and out from the anchor source (e.g., the pill button)
/// with a fully customizable, snappy duration, bypassing UIKit's hardcoded 1s popover delay.
final class PillMorphAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    let presenting: Bool
    let sourceView: UIView?

    init(presenting: Bool, sourceView: UIView?) {
        self.presenting = presenting
        self.sourceView = sourceView
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return 0.35 // Snappy, iOS-like custom duration
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        if presenting {
            guard let toVC = transitionContext.viewController(forKey: .to) else {
                transitionContext.completeTransition(false)
                return
            }
            let containerView = transitionContext.containerView
            containerView.addSubview(toVC.view)
            
            toVC.view.frame = containerView.bounds
            toVC.view.layoutIfNeeded()

            // Calculate starting transform from the anchor view if available
            let finalFrame = toVC.view.frame
            if let sourceView = sourceView, let window = sourceView.window {
                let sourceRect = sourceView.convert(sourceView.bounds, to: window)
                let targetCenter = CGPoint(x: finalFrame.midX, y: finalFrame.midY)
                let sourceCenter = CGPoint(x: sourceRect.midX, y: sourceRect.midY)
                
                // Position initial center at the button and scale down
                toVC.view.center = sourceCenter
                let scaleX = sourceRect.width / max(finalFrame.width, 1)
                let scaleY = sourceRect.height / max(finalFrame.height, 1)
                toVC.view.transform = CGAffineTransform(scaleX: max(scaleX, 0.1), y: max(scaleY, 0.1))
            } else {
                toVC.view.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
            }
            
            toVC.view.alpha = 0
            
            UIView.animate(withDuration: transitionDuration(using: transitionContext),
                           delay: 0,
                           usingSpringWithDamping: 0.82,
                           initialSpringVelocity: 0.4,
                           options: [.curveEaseInOut, .allowUserInteraction]) {
                toVC.view.transform = .identity
                toVC.view.center = CGPoint(x: finalFrame.midX, y: finalFrame.midY)
                toVC.view.alpha = 1
            } completion: { finished in
                transitionContext.completeTransition(finished)
            }

        } else {
            guard let fromVC = transitionContext.viewController(forKey: .from) else {
                transitionContext.completeTransition(false)
                return
            }

            UIView.animate(withDuration: transitionDuration(using: transitionContext),
                           delay: 0,
                           options: [.curveEaseIn]) {
                fromVC.view.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
                fromVC.view.alpha = 0
            } completion: { finished in
                fromVC.view.removeFromSuperview()
                transitionContext.completeTransition(finished)
            }
        }
    }
}

enum PanelSource {
    case item(UIBarButtonItem)
    case view(UIView)
}

final class PanelPopoverController: UIViewController, UIViewControllerTransitioningDelegate {
    private let host: UIHostingController<AnyView>
    var onOutsideTap: (() -> Void)?
    weak var anchor: UIView?
    private var sourceViewForAnimation: UIView?

    init(content: AnyView) {
        host = UIHostingController(rootView: content)
        super.init(nibName: nil, bundle: nil)
        overrideUserInterfaceStyle = .dark
        host.view.backgroundColor = .clear
        host.sizingOptions = [.preferredContentSize]
        if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
        
        // Use custom presentation style to unlock custom animation durations
        modalPresentationStyle = .custom
        transitioningDelegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    var isInUse: Bool { presentingViewController != nil || isBeingPresented || isBeingDismissed }

    private(set) var passthrough: [UIView] = []
    
    func configure(source: PanelSource, anchor: UIView?, passthrough: [UIView], bottomInset: CGFloat) {
        self.anchor = anchor
        self.passthrough = passthrough
        
        switch source {
        case .item(let item):
            self.sourceViewForAnimation = item.value(forKey: "view") as? UIView
        case .view(let v):
            self.sourceViewForAnimation = v
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.clipsToBounds = true
        addChild(host)
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

    // MARK: UIViewControllerTransitioningDelegate
    
    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return PillMorphAnimator(presenting: true, sourceView: sourceViewForAnimation ?? anchor)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return PillMorphAnimator(presenting: false, sourceView: sourceViewForAnimation ?? anchor)
    }

    override func accessibilityPerformEscape() -> Bool {
        onOutsideTap?()
        return true
    }
}

@MainActor
final class PanelPresenter {
    static let shared = PanelPresenter()

    private struct Request {
        let kind: String
        let presenter: UIViewController
        let make: () -> PanelPopoverController
        let onClosedByTap: () -> Void
    }
    
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

    func prewarm(kind: String, sizeKey: String, owner: ObjectIdentifier, content: () -> AnyView) {
        let t = CACurrentMediaTime()
        controller(kind: kind, sizeKey: sizeKey, owner: owner, content: content).prewarm()
        dlog("perf", String(format: "panel %@ prebuilt in %.0f ms", kind, (CACurrentMediaTime() - t) * 1000))
    }

    func reset() {
        wanted = nil
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
    private var phase = Phase.idle
    private var inFlight: PanelPopoverController?

    private var wanted: Request?
    private var tapSerial = 0
    private var wantedSerial = -1
    private var shown: PanelPopoverController?
    private var shownKind: String?
    private var shownRequest: Request?
    private var generation = 0
    private let frames = FrameMonitor()
    private var tapTime: CFTimeInterval = 0
    var onClosing: ((Bool) -> Void)?

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
        guard phase == .idle else { return }
        if let vc = shown, vc.presentingViewController == nil, !vc.isBeingPresented {
            shown = nil; shownKind = nil; shownRequest = nil
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
                UIAccessibility.post(notification: .screenChanged, argument: nil)
                self.finish()
            }
            return
        }
        guard let req = wanted else { return }
        let buildStart = CACurrentMediaTime()
        let vc = req.make()
        guard !vc.isInUse else {
            NextFrame.run { [weak self] in self?.reconcile() }
            return
        }
        vc.loadViewIfNeeded()
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
            self.finish()
        }
    }

    // MARK: Transitions

    private func open(_ vc: PanelPopoverController, from host: UIViewController, animated: Bool, done: @escaping () -> Void) {
        host.present(vc, animated: animated) {
            Self.afterTransition(then: done)
        }
    }

    private func close(_ vc: PanelPopoverController, animated: Bool, switching: Bool, done: @escaping () -> Void) {
        let next = { Self.afterTransition(then: done) }
        guard animated else { vc.dismiss(animated: false, completion: next); return }
        if switching, let view = vc.view {
            UIView.animate(withDuration: 0.10, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
                view.alpha = 0
            } completion: { _ in
                vc.dismiss(animated: false) { view.alpha = 1; next() }
            }
        } else {
            vc.dismiss(animated: true, completion: next)
        }
    }

    private static func afterTransition(then done: @escaping () -> Void) {
        DispatchQueue.main.async {
            done()
        }
    }

    // MARK: Phase / watchdog

    private func begin(_ p: Phase, _ vc: PanelPopoverController) -> Int {
        phase = p
        inFlight = vc
        generation += 1
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self, weak vc] in
            guard let self, self.phase != .idle, self.generation == g else { return }
            if let vc, vc.isBeingPresented || vc.isBeingDismissed {
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
        dlog("ui/error", "panel \(phase.rawValue) did not finish; recovering")
        generation += 1
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
        onClosing?(false)
    }
}

@MainActor
private final class NextFrame: NSObject {
    private var link: CADisplayLink?
    private var action: (() -> Void)?

    static func run(_ action: @escaping () -> Void) {
        let f = NextFrame()
        f.action = action
        let l = CADisplayLink(target: f, selector: #selector(tick))
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
