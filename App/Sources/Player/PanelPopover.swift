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
    private let onDismiss: () -> Void
    var onWillDismiss: (() -> Void)?
    let passthrough: [UIView]

    init(content: AnyView, source: PanelSource, passthrough: [UIView], bottomInset: CGFloat = 8, onDismiss: @escaping () -> Void) {
        host = UIHostingController(rootView: content)
        self.onDismiss = onDismiss
        self.passthrough = passthrough
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .popover
        overrideUserInterfaceStyle = .dark
        host.view.backgroundColor = .clear
        host.sizingOptions = [.preferredContentSize]
        if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
        if let pc = popoverPresentationController {
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
            // Keep the panel above the button bar so the other buttons stay tappable.
            pc.popoverLayoutMargins = UIEdgeInsets(top: 66, left: 16, bottom: bottomInset, right: 16)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        preferredContentSize = host.sizeThatFits(in: CGSize(width: 10_000, height: 10_000))
    }

    override func preferredContentSizeDidChange(forChildContentContainer container: UIContentContainer) {
        super.preferredContentSizeDidChange(forChildContentContainer: container)
        preferredContentSize = container.preferredContentSize
    }

    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }
    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }
    func presentationControllerWillDismiss(_ presentationController: UIPresentationController) { onWillDismiss?() }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { onDismiss() }
}

/// Owns the one open panel popover and runs ONE transition at a time.
///
/// 1.10.0 presented and dismissed as taps came in; quick taps started a new
/// popover while the previous one was still animating, which left a popover
/// orphaned on screen with UIKit's transition never finishing — the player
/// stopped responding. Now a tap only records which panel is wanted, and
/// `reconcile()` moves the screen towards it step by step: dismiss what's
/// shown, wait for that to finish, then present the wanted one.
@MainActor
final class PanelPresenter {
    static let shared = PanelPresenter()

    private struct Request {
        let kind: String
        let presenter: UIViewController
        let make: () -> PanelPopoverController
    }
    private var wanted: Request?
    private var shown: PanelPopoverController?
    private var shownKind: String?
    private var busy = false
    private var busyToken = 0

    /// `immediate`: called straight from the button's action (not from inside
    /// a SwiftUI update), so start in this run-loop turn — no extra frame.
    func show(kind: String, content: AnyView, source: PanelSource, from presenter: UIViewController, passthrough: [UIView], bottomInset: CGFloat,
              immediate: Bool = false, onDismiss: @escaping () -> Void) {
        if wanted?.kind == kind { return }            // the tap already asked; SwiftUI's onChange asks again
        wanted = Request(kind: kind, presenter: presenter) { [weak self] in
            let vc = PanelPopoverController(content: content, source: source, passthrough: passthrough, bottomInset: bottomInset,
                                            onDismiss: { [weak self] in self?.dismissedBySystem(kind: kind); onDismiss() })
            vc.onWillDismiss = { [weak self] in self?.setBusy(true) }
            return vc
        }
        if immediate { reconcile() } else { DispatchQueue.main.async { [weak self] in self?.reconcile() } }
    }

    func hide(animated: Bool = true) {
        wanted = nil
        reconcile(animated: animated)
    }

    private func reconcile(animated: Bool = true) {
        guard !busy else { return }                   // a transition is running; it calls back here when done
        if let vc = shown, vc.presentingViewController == nil { shown = nil; shownKind = nil }   // went away on its own
        if let vc = shown {
            guard wanted?.kind != shownKind else { return }
            let switching = wanted != nil
            dlog("ui", "panel: dismiss \(shownKind ?? "?")\(switching ? " → \(wanted!.kind)" : "")")
            setBusy(true)
            let finish = { [weak self] in
                guard let self else { return }
                if self.shown === vc { self.shown = nil; self.shownKind = nil }
                dlog("ui", "panel: dismissed")
                self.setBusy(false)
                self.reconcile()
            }
            if switching, animated, let container = vc.presentationController?.containerView {
                // Switching panels: fade the old one out quickly, then the new
                // one morphs out of the button that was tapped.
                UIView.animate(withDuration: 0.12, animations: { container.alpha = 0 }) { _ in vc.dismiss(animated: false, completion: finish) }
            } else {
                vc.dismiss(animated: animated, completion: finish)
            }
            return
        }
        guard let req = wanted else { return }
        let vc = req.make()
        vc.loadViewIfNeeded()                         // size known before the transition starts (no resize mid-morph)
        let host = req.presenter.topMostPresented
        guard host.view.window != nil, !host.isBeingDismissed, !host.isBeingPresented else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.reconcile() }
            return
        }
        shown = vc
        shownKind = req.kind
        dlog("ui", "panel: present \(req.kind)")
        setBusy(true)
        host.present(vc, animated: animated) { [weak self] in
            dlog("ui", "panel: presented \(req.kind)")
            // UIKit resets passthrough views for bar-item popovers on presentation.
            vc.popoverPresentationController?.passthroughViews = vc.passthrough
            self?.setBusy(false)
            self?.reconcile()
        }
    }

    /// Closed by a tap outside (UIKit dismissed it).
    private func dismissedBySystem(kind: String) {
        dlog("ui", "panel: closed by outside tap (\(kind))")
        shown = nil
        shownKind = nil
        if wanted?.kind == kind { wanted = nil }      // keep a panel tapped while this one was closing
        setBusy(false)
        reconcile()
    }

    /// While busy, taps only update `wanted`. A watchdog clears a transition
    /// UIKit never completed, so the player can't get stuck behind it.
    private var waits = 0

    private func setBusy(_ b: Bool, rearm: Bool = false) {
        busy = b
        busyToken += 1
        if !rearm { waits = 0 }
        guard b else { return }
        let token = busyToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.busy, self.busyToken == token else { return }
            // Still animating (slow device / simulator): keep waiting — starting
            // another transition on top of a running one is what breaks UIKit.
            if let vc = self.shown, vc.isBeingPresented || vc.isBeingDismissed || vc.transitionCoordinator != nil, self.waits < 3 {
                self.waits += 1
                self.busy = false; self.setBusy(true, rearm: true)
                return
            }
            dlog("ui/error", "panel transition did not finish; recovering")
            self.busy = false
            if let vc = self.shown, vc.presentingViewController == nil { self.shown = nil; self.shownKind = nil }
            self.reconcile()
        }
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
