import SwiftUI
import UIKit

/// Player panels as our own UIKit Liquid Glass overlay, animated with plain
/// UIView spring animations — the one kind of animation the device traces
/// prove runs in this app. The glass starts as the tapped button's circle
/// and grows into the panel (the glass lenses while it moves, which is the
/// Outplayer look); the content fades in inside it. Closing reverses it.
@MainActor
final class PanelOverlay {
    static let shared = PanelOverlay()

    private var container: UIView?          // full-window tap catcher
    private var glass: UIVisualEffectView?
    private var host: UIHostingController<AnyView>?
    private(set) var kind: PlayerUIState.Panel?
    private weak var ui: PlayerUIState?
    private weak var window: UIWindow?
    private weak var pill: UIView?
    private var closing = false

    /// Opens `kind` from `button` (already open → switches).
    func show(_ kind: PlayerUIState.Panel, from button: UIView, pill: UIView?, ui: PlayerUIState, content: AnyView, width: CGFloat, maxHeight: CGFloat) {
        guard let window = button.window else { dlog("ui/error", "panel: button has no window"); return }
        if self.kind != nil {
            // Switch: shrink into the old button, then grow from the new one.
            hide(animated: true) { [weak self] in self?.show(kind, from: button, pill: pill, ui: ui, content: content, width: width, maxHeight: maxHeight) }
            return
        }
        self.kind = kind; self.ui = ui; self.window = window; self.pill = pill

        let container = PassthroughView(frame: window.bounds)
        container.passthrough = pill
        container.onTapOutside = { [weak self] in self?.ui?.closePanel() }
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(container)
        self.container = container

        // Glass sheet
        let g: UIVisualEffectView
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            g = UIVisualEffectView(effect: UIGlassEffect())
            g.cornerConfiguration = .corners(radius: .fixed(24))
        } else {
            g = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
            g.layer.cornerRadius = 24; g.layer.cornerCurve = .continuous; g.clipsToBounds = true
        }
        #else
        g = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        g.layer.cornerRadius = 24; g.layer.cornerCurve = .continuous; g.clipsToBounds = true
        #endif
        container.addSubview(g)
        glass = g

        // Content, measured at the final width
        let hc = UIHostingController(rootView: content)
        hc.view.backgroundColor = .clear
        let fit = hc.sizeThatFits(in: CGSize(width: width, height: maxHeight))
        let height = min(max(fit.height, 120), maxHeight)
        host = hc
        hc.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        g.contentView.addSubview(hc.view)
        hc.view.alpha = 0
        hc.view.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)

        // Frames: start as the button's circle, end above the pill, right-aligned.
        let start = button.convert(button.bounds, to: container)
        let safe = window.safeAreaInsets
        let right = min(start.maxX + 8, container.bounds.width - 20)
        let bottom = (pill?.convert(pill!.bounds, to: container).minY ?? start.minY) - 10
        let x = max(20, right - width)
        let y = max(safe.top + 48, bottom - height)
        let end = CGRect(x: x, y: y, width: width, height: height)
        g.frame = start
        g.alpha = 0.9
        AnimTracer.trace("panel \(kind.rawValue) (glass)", view: g, duration: 0.8)
        dlog("ui", "panel \(kind.rawValue) grows \(Int(start.width))×\(Int(start.height)) → \(Int(end.width))×\(Int(end.height))")
        UIView.animate(withDuration: 0.55, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0.4, options: [.allowUserInteraction]) {
            g.frame = end
            g.alpha = 1
        }
        UIView.animate(withDuration: 0.3, delay: 0.12, options: [.curveEaseOut, .allowUserInteraction]) {
            hc.view.alpha = 1
            hc.view.transform = .identity
        }
    }

    func hide(animated: Bool, completion: (() -> Void)? = nil) {
        guard let g = glass, let container = container, !closing else { completion?(); return }
        closing = true
        let kind = self.kind
        let target: CGRect = {
            if let kind, let b = ui?.anchors[kind] { return b.convert(b.bounds, to: container) }
            return g.frame.insetBy(dx: g.frame.width * 0.4, dy: g.frame.height * 0.4)
        }()
        let finish = { [weak self] in
            container.removeFromSuperview()
            self?.host?.view.removeFromSuperview()
            self?.host = nil; self?.glass = nil; self?.container = nil; self?.kind = nil; self?.closing = false
            completion?()
        }
        guard animated else { finish(); return }
        UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseIn]) { self.host?.view.alpha = 0; self.host?.view.transform = CGAffineTransform(scaleX: 0.94, y: 0.94) }
        UIView.animate(withDuration: 0.4, delay: 0.02, usingSpringWithDamping: 0.9, initialSpringVelocity: 0, options: []) {
            g.frame = target
            g.alpha = 0.6
        } completion: { _ in finish() }
    }

    /// Re-measure after content changes (tab switch, list growth).
    func relayout(maxHeight: CGFloat) {
        guard let g = glass, let hc = host, let container, kind != nil else { return }
        let fit = hc.sizeThatFits(in: CGSize(width: g.frame.width, height: maxHeight))
        let height = min(max(fit.height, 120), maxHeight)
        guard abs(height - g.frame.height) > 1 else { return }
        var f = g.frame
        f.origin.y = f.maxY - height; f.size.height = height
        if f.minY < (window?.safeAreaInsets.top ?? 0) + 48 { f.origin.y = (window?.safeAreaInsets.top ?? 0) + 48 }
        _ = container
        UIView.animate(withDuration: 0.36, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
            g.frame = f
            hc.view.frame = CGRect(x: 0, y: 0, width: f.width, height: height)
        }
    }
}

/// Catches taps outside the panel (closes it) but lets the pill through.
final class PassthroughView: UIView {
    weak var passthrough: UIView?
    var onTapOutside: (() -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let p = passthrough, p.bounds.contains(p.convert(point, from: self)) { return nil }
        return super.hitTest(point, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Only taps that landed on the catcher itself (not inside the glass).
        if let t = touches.first, hitTest(t.location(in: self), with: event) === self { onTapOutside?() }
    }
}
