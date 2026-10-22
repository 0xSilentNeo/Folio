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

/// Samples the presentation layers of a view and its ancestors at display
/// rate right after a presentation starts, and writes the most-animated
/// level's trajectory to the diagnostics log — whether an animation really
/// ran (and how long it took) becomes a fact in the report.
@MainActor
final class AnimTracer {
    private static var active: [AnimTracer] = []
    private var link: CADisplayLink?
    private let start = CACurrentMediaTime()
    private let duration: CFTimeInterval
    private let name: String
    private weak var view: UIView?
    private struct Sample { let t: Double; let w: CGFloat; let h: CGFloat; let a: Float; let s: CGFloat }
    private var samples: [[Sample]] = []       // per ancestor level
    private var names: [String] = []

    static func trace(_ name: String, view: UIView, duration: CFTimeInterval = 0.8) {
        active.append(AnimTracer(name: name, view: view, duration: duration))
    }

    private init(name: String, view: UIView, duration: CFTimeInterval) {
        self.name = name; self.view = view; self.duration = duration
        link = CADisplayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }

    private var chain: [UIView] {
        var out: [UIView] = []
        var v = view
        while let cur = v, !(cur is UIWindow), out.count < 8 { out.append(cur); v = cur.superview }
        return out
    }

    @objc private func tick() {
        let t = CACurrentMediaTime() - start
        let c = chain
        if samples.isEmpty { samples = Array(repeating: [], count: c.count); names = c.map { String(describing: type(of: $0)) } }
        for (i, v) in c.enumerated() where i < samples.count {
            let p = v.layer.presentation() ?? v.layer
            let sx = sqrt(p.transform.m11 * p.transform.m11 + p.transform.m12 * p.transform.m12)
            samples[i].append(Sample(t: t, w: p.bounds.width, h: p.bounds.height, a: p.opacity, s: sx))
        }
        if t >= duration {
            link?.invalidate(); link = nil
            func distinct(_ arr: [Sample]) -> Int { Set(arr.map { "\(Int($0.w * $0.s))x\(Int($0.h * $0.s))a\(Int($0.a * 20))" }).count }
            let best = samples.indices.max { distinct(samples[$0]) < distinct(samples[$1]) } ?? 0
            let arr = samples.isEmpty ? [] : samples[best]
            let d = distinct(arr)
            let step = max(1, arr.count / 10)
            let path = stride(from: 0, to: arr.count, by: step).map { i -> String in
                let s = arr[i]; return String(format: "%.0fms %.0f×%.0f s%.2f a%.2f", s.t * 1000, s.w, s.h, s.s, s.a)
            }
            let levels = samples.indices.map { "\(names[$0]):\(distinct(samples[$0]))" }.joined(separator: " ")
            dlog("anim", "\(name): \(d > 3 ? "ANIMATED" : "SNAP") (\(arr.count) samples, \(d) distinct states at \(names.indices.contains(best) ? names[best] : "?")) | \(path.joined(separator: " · ")) | levels: \(levels)")
            AnimTracer.active.removeAll { $0 === self }
        }
    }
}
