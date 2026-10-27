import UIKit
import ObjectiveC

/// Safety net: UIKit layout never runs off the main thread.
///
/// Core Animation commits a thread's layer changes on that thread, and a
/// commit lays out the layer tree they were made in — including UIKit's
/// views, whose layout (Auto Layout) throws off the main thread. mpv's Metal
/// video thread (MoltenVK) changes the video layer, and its changes are
/// committed when the thread ends (PiP starting, the player closing, a file
/// without video). If UIKit has a layout waiting in the player's window at
/// that moment, the app is killed: SIGTRAP on 24 Oct (1.12.0, PiP starting)
/// and 27 Oct (1.17.0, going to the Home Screen while playing). Both crash
/// stacks: thread exit → Core Animation commit → `-[CALayer layoutSublayers]`
/// → UIView layout → Auto Layout exception.
///
/// `CALayer.layoutSublayers` (whose default implementation calls the
/// delegate's `layoutSublayers(of:)` — CALayer docs) is where a view's layout
/// starts. Off the main thread, for a layer that belongs to a view, this
/// skips it and asks for the layout again on the main thread, where UIKit
/// does it as usual.
enum MainThreadLayout {
    private nonisolated(unsafe) static var installed = false
    private nonisolated(unsafe) static var lastLog: CFTimeInterval = 0

    static func install() {
        guard !installed, !CommandLine.arguments.contains("-noLayoutGuard") else { return }
        let sel = #selector(CALayer.layoutSublayers)
        guard let m = class_getInstanceMethod(CALayer.self, sel) else { return }
        installed = true
        typealias Original = @convention(c) (CALayer, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(m), to: Original.self)
        let guarded: @convention(block) (CALayer) -> Void = { layer in
            if !Thread.isMainThread, let view = layer.delegate as? UIView {
                let name = String(describing: type(of: view))
                let now = CACurrentMediaTime()
                if now - lastLog > 1 {
                    lastLog = now
                    dlog("ui/error", "layout of \(name) asked for on a background thread (Core Animation commit there): moved to the main thread")
                }
                DispatchQueue.main.async { layer.setNeedsLayout() }
                return
            }
            original(layer, sel)
        }
        method_setImplementation(m, imp_implementationWithBlock(guarded))
    }
}
