import UIKit
import QuartzCore

/// CAMetalLayer handed to mpv (vo=gpu-next, gpu-context=moltenvk) via `wid`.
final class GPMetalLayer: CAMetalLayer {
    // MoltenVK can set the drawable to 1x1 to force-complete a presentation,
    // which causes flicker / stuck tiny drawables (mpv PR #13651).
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }

    // EDR (HDR output) only activates when toggled on the main thread.
    // Async on purpose: a sync hop could deadlock against mpv calls made
    // from the main thread while the VO is (re)initialising.
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                DispatchQueue.main.async { [weak self] in self?.setEDR(newValue) }
            }
        }
    }

    private func setEDR(_ v: Bool) { super.wantsExtendedDynamicRangeContent = v }
}

/// Video surface for the Metal (gpu-next / libplacebo) renderer. mpv owns
/// all rendering; this view only keeps the drawable sized to its bounds.
final class MetalVideoView: UIView {
    override class var layerClass: AnyClass { GPMetalLayer.self }
    var metalLayer: GPMetalLayer { layer as! GPMetalLayer }

    /// Called after the drawable size changed (rotation, PiP restore, app switch).
    var onResize: (() -> Void)?
    private var lastSize: CGSize = .zero

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
        isOpaque = true
        contentScaleFactor = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        // While the swapchain catches up after a size change, letterbox the
        // old frame instead of stretching it.
        metalLayer.contentsGravity = .resizeAspect
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        if contentScaleFactor != scale { contentScaleFactor = scale }
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.drawableSize = size
        CATransaction.commit()
        if size != lastSize {
            lastSize = size
            onResize?()
        }
    }

    /// Value for mpv's `wid` option.
    var wid: Int64 {
        Int64(Int(bitPattern: Unmanaged.passUnretained(metalLayer).toOpaque()))
    }
}
