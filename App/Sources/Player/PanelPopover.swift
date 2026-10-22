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

    init(content: AnyView, source: PanelSource, passthrough: [UIView], bottomInset: CGFloat = 8, onDismiss: @escaping () -> Void) {
        host = UIHostingController(rootView: content)
        self.onDismiss = onDismiss
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
            pc.popoverLayoutMargins = UIEdgeInsets(top: 52, left: 16, bottom: bottomInset, right: 16)
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
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { onDismiss() }
}

/// Owns the one open panel popover: switching dismisses the old one first.
@MainActor
final class PanelPresenter {
    static let shared = PanelPresenter()
    private weak var current: PanelPopoverController?

    func show(content: AnyView, source: PanelSource, from presenter: UIViewController, passthrough: [UIView], bottomInset: CGFloat, onDismiss: @escaping () -> Void) {
        let present = { [weak self] in
            let vc = PanelPopoverController(content: content, source: source, passthrough: passthrough, bottomInset: bottomInset, onDismiss: onDismiss)
            self?.current = vc
            presenter.topMostPresented.present(vc, animated: true) {
                // UIKit resets passthrough views for bar-item popovers on presentation.
                vc.popoverPresentationController?.passthroughViews = passthrough
            }
        }
        if let c = current, c.presentingViewController != nil {
            current = nil
            c.dismiss(animated: true) { present() }
        } else {
            // Outside the SwiftUI update pass that triggered it.
            DispatchQueue.main.async(execute: present)
        }
    }

    func hide(animated: Bool = true) {
        guard let c = current else { return }
        current = nil
        c.dismiss(animated: animated)
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
