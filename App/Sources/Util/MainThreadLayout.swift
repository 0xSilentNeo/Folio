import UIKit
import ObjectiveC

/// Safety net: UIKit layout never runs off the main thread.
///
/// Core Animation commits a thread's layer changes on that thread — for a
/// thread without a run loop, when the thread ends — and a commit lays out
/// the layer tree the changes were made in, UIKit's views included, whose
/// layout (Auto Layout) throws off the main thread. mpv's Metal video thread
/// (MoltenVK) changes the video layer and ends when PiP starts, when video
/// goes off in the background, when the player closes. The app was killed
/// that way: SIGTRAP on 24 Oct (1.12.0, PiP starting) and 27 Oct (1.17.0,
/// going to the Home Screen while playing). Both stacks: thread exit → Core
/// Animation commit → view layout → Auto Layout exception.
///
/// A view's layout starts in `CALayer.layoutSublayers`, whose default
/// implementation calls the delegate's `layoutSublayers(of:)` (CALayer docs);
/// UIView is that delegate. Both are guarded: off the main thread the layout
/// is skipped and asked for again on the main thread, where UIKit does it as
/// usual. (Checked in the simulator: `-layoutGuardLab` has a thread change a
/// view's layer and end.)
enum MainThreadLayout {
    private nonisolated(unsafe) static var installed = false
    private nonisolated(unsafe) static var lastLog: CFTimeInterval = 0

    static func install() {
        guard !installed, !CommandLine.arguments.contains("-noLayoutGuard") else { return }
        installed = true

        let lsel = #selector(CALayer.layoutSublayers)
        if let m = class_getInstanceMethod(CALayer.self, lsel) {
            typealias Original = @convention(c) (CALayer, Selector) -> Void
            let original = unsafeBitCast(method_getImplementation(m), to: Original.self)
            let guarded: @convention(block) (CALayer) -> Void = { layer in
                if !Thread.isMainThread, let view = layer.delegate as? UIView {
                    moveToMain(layer, String(describing: type(of: view)))
                    return
                }
                original(layer, lsel)
            }
            method_setImplementation(m, imp_implementationWithBlock(guarded))
        }

        let vsel = NSSelectorFromString("layoutSublayersOfLayer:")
        if let m = class_getInstanceMethod(UIView.self, vsel) {
            typealias Original = @convention(c) (UIView, Selector, CALayer) -> Void
            let original = unsafeBitCast(method_getImplementation(m), to: Original.self)
            let guarded: @convention(block) (UIView, CALayer) -> Void = { view, layer in
                if !Thread.isMainThread {
                    moveToMain(layer, String(describing: type(of: view)))
                    return
                }
                original(view, vsel, layer)
            }
            method_setImplementation(m, imp_implementationWithBlock(guarded))
        }
    }

    private static func moveToMain(_ layer: CALayer, _ name: String) {
        let now = CACurrentMediaTime()
        if now - lastLog > 1 {
            lastLog = now
            dlog("ui/error", "layout of \(name) asked for on a background thread (a Core Animation commit there): moved to the main thread")
        }
        DispatchQueue.main.async { layer.setNeedsLayout() }
    }

    /// Lab (`-layoutGuardLab`): a view laid out with Auto Layout, then a
    /// thread that changes its layer and ends, as mpv's Metal thread does.
    /// Without the guard (`-noLayoutGuard`) this is expected to crash the
    /// way the 24 and 27 Oct reports did.
    static func lab() {
        guard CommandLine.arguments.contains("-layoutGuardLab") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            guard let w = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else {
                dlog("lab", "layout guard lab: no window"); return
            }
            let probe = UIView()
            probe.translatesAutoresizingMaskIntoConstraints = false
            probe.isUserInteractionEnabled = false
            let inner = UILabel()
            inner.text = " "
            inner.translatesAutoresizingMaskIntoConstraints = false
            probe.addSubview(inner)
            w.addSubview(probe)
            NSLayoutConstraint.activate([
                probe.leadingAnchor.constraint(equalTo: w.leadingAnchor), probe.topAnchor.constraint(equalTo: w.topAnchor),
                probe.widthAnchor.constraint(equalToConstant: 40), probe.heightAnchor.constraint(equalToConstant: 40),
                inner.centerXAnchor.constraint(equalTo: probe.centerXAnchor), inner.centerYAnchor.constraint(equalTo: probe.centerYAnchor),
            ])
            w.layoutIfNeeded()
            let layer = probe.layer, windowLayer = w.layer
            dlog("lab", "layout guard lab: a thread changes a view's layer and ends (guard \(installed ? "on" : "off"))")
            let t = Thread {
                layer.setNeedsLayout()
                windowLayer.setNeedsLayout()
                layer.opacity = 0.99
            }
            t.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                dlog("lab", "layout guard lab: app still running 3 s later")
                probe.removeFromSuperview()
            }
        }
    }
}
