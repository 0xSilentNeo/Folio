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

/// Samples a view's presentation layer at display rate right after a
/// presentation starts and writes the trajectory to the diagnostics log, so
/// whether an animation really ran (and how long it took) is a fact in the
/// report rather than a guess from a recording.
@MainActor
final class AnimTracer {
    private static var active: [AnimTracer] = []
    private var link: CADisplayLink?
    private let start = CACurrentMediaTime()
    private let duration: CFTimeInterval
    private let name: String
    private weak var view: UIView?
    private var samples: [(Double, CGFloat, CGFloat, Float)] = []   // t, width, height, opacity

    static func trace(_ name: String, view: UIView, duration: CFTimeInterval = 0.8) {
        let t = AnimTracer(name: name, view: view, duration: duration)
        active.append(t)
    }

    private init(name: String, view: UIView, duration: CFTimeInterval) {
        self.name = name; self.view = view; self.duration = duration
        link = CADisplayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }

    /// The popover's outermost container (what UIKit actually animates).
    private var target: CALayer? {
        var v = view
        var top = v
        while let s = v?.superview, !(s is UIWindow) { top = s; v = s }
        return top?.layer
    }

    @objc private func tick() {
        let t = CACurrentMediaTime() - start
        if let l = target, let p = l.presentation() {
            let sx = sqrt(p.transform.m11 * p.transform.m11 + p.transform.m12 * p.transform.m12)
            samples.append((t, p.bounds.width * sx, p.bounds.height * sx, p.opacity))
        }
        if t >= duration {
            link?.invalidate(); link = nil
            let step = max(1, samples.count / 12)
            let path = stride(from: 0, to: samples.count, by: step).map { i -> String in
                let s = samples[i]; return String(format: "%.0fms %.0f×%.0f a%.2f", s.0 * 1000, s.1, s.2, s.3)
            }
            let widths = samples.map(\.1)
            let distinct = Set(widths.map { Int($0) }).count
            dlog("anim", "\(name): \(samples.count) samples, \(distinct) distinct sizes → \(distinct > 3 ? "ANIMATED" : "SNAP") | " + path.joined(separator: " · "))
            AnimTracer.active.removeAll { $0 === self }
        }
    }
}
