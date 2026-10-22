import SwiftUI
import UIKit

/// Player panels are real UIKit popovers anchored to their pill button —
/// the way Outplayer does it (UIPopoverPresentationController + a
/// transparent background view + a SwiftUI hosting controller sized to its
/// content). On iOS 26 the system presents a popover by morphing it out of
/// its source view, which is the circle-to-panel animation.

/// No arrow, no chrome: the SwiftUI content draws its own glass.
final class ClearPopoverBackground: UIPopoverBackgroundView {
    private var _offset: CGFloat = 0
    private var _direction: UIPopoverArrowDirection = .down
    override var arrowOffset: CGFloat { get { _offset } set { _offset = newValue } }
    override var arrowDirection: UIPopoverArrowDirection { get { _direction } set { _direction = newValue } }
    override class func arrowBase() -> CGFloat { 0 }
    override class func arrowHeight() -> CGFloat { 0 }
    override class func contentViewInsets() -> UIEdgeInsets { .zero }
    override class var wantsDefaultContentAppearance: Bool { false }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        layer.shadowOpacity = 0
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class PanelPopoverController: UIViewController, UIPopoverPresentationControllerDelegate {
    private let host: UIHostingController<AnyView>
    private let onDismiss: () -> Void

    init(content: AnyView, anchor: UIView, passthrough: [UIView], onDismiss: @escaping () -> Void) {
        host = UIHostingController(rootView: content)
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .popover
        host.view.backgroundColor = .clear
        host.sizingOptions = [.preferredContentSize]
        if let pc = popoverPresentationController {
            pc.delegate = self
            pc.sourceView = anchor
            pc.sourceRect = anchor.bounds
            pc.permittedArrowDirections = [.down]
            pc.popoverBackgroundViewClass = ClearPopoverBackground.self
            pc.passthroughViews = passthrough
            pc.popoverLayoutMargins = UIEdgeInsets(top: 56, left: 20, bottom: 0, right: 20)
            pc.backgroundColor = .clear
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
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { onDismiss() }
}

/// Zero-cost UIView behind a SwiftUI button, so the popover has a source view.
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
