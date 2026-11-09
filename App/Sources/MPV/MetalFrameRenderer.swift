import CoreVideo
import Metal
import QuartzCore

/// The Metal renderer drawing into the player's video layer (1.28.0, engine
/// 3). mpv's gpu-next output (libplacebo on Vulkan, through MoltenVK) draws
/// each frame into an IOSurface pixel buffer Folio hands it, as a Metal
/// texture, instead of into a CAMetalLayer of its own; the buffer then goes
/// to the same AVSampleBufferDisplayLayer as OpenGL's frames, which is also
/// Picture in Picture's. So, as on OpenGL:
/// - PiP starts and stops with nothing swapped. Until now Metal swapped
///   mpv's video output to the CPU at each PiP start and back at the stop:
///   mpv rebuilt its video chain and seeked in place, a stall and a spinner.
/// - Leaving the app (Notification Centre, the Home Screen) stops the GPU
///   work by refusing frames, and coming back goes on drawing. Until now
///   Metal took its video output down (iOS refuses GPU work in the
///   background, and mpv's output draws on its own thread) and built it again
///   on return: a new decoder, a seek, a spinner.
/// And Metal keeps what OpenGL lacks: Dolby Vision applied, 10-bit HDR
/// straight from the hardware decoder (no copy), libplacebo's scaling.
///
/// The engine (engine/patches/0200) asks before each frame whether it may
/// use the GPU (`allowed`), then for a buffer (`acquire`), and hands it back
/// once the GPU has finished (`present`), all on mpv's video output thread.
/// mpv's Vulkan context still needs a layer for its swapchain: `layer`, never
/// on screen and never drawn to; its drawable size is the frames' size, which
/// the engine reads as its window size (engine/patches/0100).
final class MetalFrameRenderer: FrameRenderer {
    /// The engine has the hook (`--folio-target`): asked once, of a
    /// throwaway mpv handle (setting an unknown option fails before init).
    static let available: Bool = {
        guard let h = mpv_create() else { return false }
        defer { mpv_terminate_destroy(h) }
        return mpv_set_option_string(h, "folio-target", "0") >= 0
    }()

    /// mpv's `wid`: the unseen layer for its swapchain.
    let layer = CAMetalLayer()
    var wid: Int64 { Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque())) }
    /// mpv's `folio-target`: the hook's address.
    var targetAddress: String { String(Int(bitPattern: target)) }
    /// The frame size changed: the player asks mpv for a new frame (paused,
    /// it wouldn't draw one).
    var onResize: (() -> Void)?
    var onHDRFailed: (() -> Void)?

    private let output: (CVPixelBuffer) -> Void
    private let target: UnsafeMutablePointer<folio_target>
    private var cache: CVMetalTextureCache?

    // Shared with mpv's thread, under `lock`.
    private let lock = NSLock()
    private var allowed = true
    /// A frame is being drawn (from `allowed` saying yes to its `present`).
    private var drawing = false
    private var detached = false
    private var hdr: SampleBufferRenderer.HDROutput?
    private var pool: CVPixelBufferPool?
    private var poolKey = (0, 0, false)
    private var lastSkip: String?
    /// Frames handed to the layer, and frames the engine didn't finish.
    private var shown = 0
    private var dropped = 0

    // Main thread.
    private var viewSize = (0, 0)
    private var videoSize: (Int, Int)?
    private var pipSize: (Int, Int)?
    private var frameSize = (0, 0)

    init?(output: @escaping (CVPixelBuffer) -> Void) {
        guard Self.available, let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.output = output
        var c: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &c) == kCVReturnSuccess, let c else { return nil }
        cache = c
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        Self.size(layer, 64, 36)
        target = .allocate(capacity: 1)
        // Retained until the engine has let go (engineDone): mpv's thread may
        // still call in while the player closes.
        let ctx = Unmanaged.passRetained(self).toOpaque()
        target.initialize(to: folio_target(
            ctx: ctx,
            allowed: { ctx in
                guard let ctx else { return false }
                return Unmanaged<MetalFrameRenderer>.fromOpaque(ctx).takeUnretainedValue().mayDraw()
            },
            acquire: { ctx, w, h, fmt, trc, token in
                guard let ctx else { return nil }
                return Unmanaged<MetalFrameRenderer>.fromOpaque(ctx).takeUnretainedValue()
                    .acquire(Int(w), Int(h), fmt, trc, token)
            },
            present: { ctx, token, pts, ok in
                guard let ctx else { return }
                Unmanaged<MetalFrameRenderer>.fromOpaque(ctx).takeUnretainedValue().present(token, ok)
            }))
    }

    /// mpv is gone (its shutdown has finished): the hook can go.
    func engineDone() {
        let ctx = target.pointee.ctx
        target.deinitialize(count: 1)
        target.deallocate()
        if let ctx { Unmanaged<MetalFrameRenderer>.fromOpaque(ctx).release() }
    }

    // MARK: FrameRenderer (main thread)

    func detach() {
        lock.lock(); detached = true; lock.unlock()
    }

    /// Stopping waits (briefly) for a frame being drawn to finish: once this
    /// returns, mpv touches the GPU no more until allowed again.
    func setRenderingAllowed(_ on: Bool, why: String) {
        lock.lock()
        let changed = allowed != on
        allowed = on
        lock.unlock()
        if !on {
            let until = CACurrentMediaTime() + 0.15
            while CACurrentMediaTime() < until {
                lock.lock(); let busy = drawing; lock.unlock()
                if !busy { break }
                usleep(2_000)
            }
        }
        if changed { Task { @MainActor in PiPTrace.event("Metal rendering \(on ? "on" : "off") (\(why))") } }
        if on { onResize?() }    // a frame now, even while paused
    }

    func setViewSize(_ size: CGSize) {
        let s = (Int(size.width.rounded()), Int(size.height.rounded()))
        guard s != viewSize else { return }
        viewSize = s
        updateFrameSize()
    }

    func setVideoSize(_ w: Int, _ h: Int) {
        guard w > 0, h > 0, videoSize.map({ $0 != (w, h) }) ?? true else { return }
        videoSize = (w, h)
        updateFrameSize()
    }

    func setPiPSize(_ size: (Int, Int)?) {
        pipSize = size
        updateFrameSize()
    }

    func setHDR(_ h: SampleBufferRenderer.HDROutput?) {
        lock.lock()
        let changed = h != hdr
        hdr = h
        if changed { pool = nil }
        lock.unlock()
        guard changed else { return }
        trace(h.map { "Metal HDR output on: \($0.hlg ? "HLG" : "PQ") BT.2020, half-float frames, MaxCLL \($0.maxCLL.map(String.init) ?? "?") nits" } ?? "Metal HDR output off: 8-bit frames")
        onResize?()
    }

    /// As OpenGL's: the video's shape fitted inside the view (at most twice
    /// its own size, even numbers), PiP's size while PiP says so, the view's
    /// while the video's isn't known.
    static func frameSize(view: (Int, Int), video: (Int, Int)?, pip: (Int, Int)?) -> (Int, Int) {
        if let pip, pip.0 > 0, pip.1 > 0 { return pip }
        guard let v = video, view.0 > 0, view.1 > 0 else { return view }
        let scale = min(Double(view.0) / Double(v.0), Double(view.1) / Double(v.1), 2)
        return (max(2, Int(Double(v.0) * scale) & ~1), max(2, Int(Double(v.1) * scale) & ~1))
    }

    private func updateFrameSize() {
        let s = Self.frameSize(view: viewSize, video: videoSize, pip: pipSize)
        guard s.0 > 0, s.1 > 0, s != frameSize else { return }
        frameSize = s
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        Self.size(layer, s.0, s.1)
        CATransaction.commit()
        trace("Metal frames now \(s.0)×\(s.1)\(pipSize != nil ? " (PiP's size)" : videoSize != nil ? " (the video's shape in the player view)" : " (the player view's size)")")
        onResize?()
    }

    /// The unseen layer's size: its bounds as well as its drawable size.
    /// MoltenVK reads a surface's largest size from the layer's bounds (times
    /// its scale); with none, it said 0×0, libplacebo took the window for
    /// hidden, and mpv's stayed 1×1 (CI lab, 9 Nov).
    private static func size(_ layer: CAMetalLayer, _ w: Int, _ h: Int) {
        layer.contentsScale = 1
        layer.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        layer.drawableSize = CGSize(width: w, height: h)
    }

    // MARK: The engine's hook (mpv's video output thread)

    private var askedToDraw = false
    private var askedForBuffer = false

    private func mayDraw() -> Bool {
        lock.lock()
        drawing = allowed && !detached
        let yes = drawing, first = !askedToDraw
        askedToDraw = true
        lock.unlock()
        if first { trace("Metal: the engine asks to draw (\(yes ? "yes" : "not now"))") }
        return yes
    }

    private final class Frame {
        let buffer: CVPixelBuffer
        let texture: CVMetalTexture
        let hdr: SampleBufferRenderer.HDROutput?
        init(_ b: CVPixelBuffer, _ t: CVMetalTexture, _ h: SampleBufferRenderer.HDROutput?) { buffer = b; texture = t; hdr = h }
    }

    private func acquire(_ w: Int, _ h: Int, _ fmt: UnsafeMutablePointer<Int32>?, _ trc: UnsafeMutablePointer<Int32>?,
                         _ token: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> UnsafeMutableRawPointer? {
        lock.lock()
        let hdr = self.hdr, go = allowed && !detached, first = !askedForBuffer
        askedForBuffer = true
        lock.unlock()
        if first { trace("Metal: the engine asks for a \(w)×\(h) buffer") }
        guard go, w > 0, h > 0, let cache else { return nil }
        let half = hdr != nil
        guard let pool = ensurePool(w, h, half) else { return skip("no pixel buffer pool for \(w)×\(h)") }
        var pbOut: CVPixelBuffer?
        let made = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pbOut)
        guard made == kCVReturnSuccess, let pb = pbOut else { return skip("no pixel buffer (\(made))") }
        var texOut: CVMetalTexture?
        let usage = MTLTextureUsage([.renderTarget, .shaderRead, .shaderWrite]).rawValue
        let wrapped = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb,
                                                                [kCVMetalTextureUsage as String: usage] as CFDictionary,
                                                                half ? .rgba16Float : .bgra8Unorm, w, h, 0, &texOut)
        guard wrapped == kCVReturnSuccess, let tex = texOut, let mtl = CVMetalTextureGetTexture(tex) else {
            if half {
                // No half-float frames here: SDR rather than nothing.
                lock.lock(); self.hdr = nil; self.pool = nil; lock.unlock()
                trace("Metal HDR output not possible: no half-float texture (\(wrapped)); back to SDR")
                if let failed = onHDRFailed { DispatchQueue.main.async(execute: failed) }
            }
            return skip("no Metal texture for the pixel buffer (\(wrapped))")
        }
        fmt?.pointee = half ? 1 : 0
        trc?.pointee = hdr.map { $0.hlg ? 2 : 1 } ?? 0
        token?.pointee = Unmanaged.passRetained(Frame(pb, tex, hdr)).toOpaque()
        lastSkip = nil
        return Unmanaged.passUnretained(mtl as AnyObject).toOpaque()
    }

    private func present(_ token: UnsafeMutableRawPointer?, _ ok: Bool) {
        lock.lock()
        drawing = false
        let gone = detached
        lock.unlock()
        guard let token else { return }
        let frame = Unmanaged<Frame>.fromOpaque(token).takeRetainedValue()
        guard ok, !gone else {
            dropped += 1
            if dropped == 1 { trace("Metal: the engine gave back a frame undrawn (\(gone ? "detached" : "not drawn"))") }
            return
        }
        shown += 1
        if shown == 1 {
            trace("Metal: first frame into the video layer, \(CVPixelBufferGetWidth(frame.buffer))×\(CVPixelBufferGetHeight(frame.buffer))\(frame.hdr != nil ? ", HDR" : "")")
        }
        if let hdr = frame.hdr { SampleBufferRenderer.tag(frame.buffer, hdr) }
        output(frame.buffer)
    }

    private func ensurePool(_ w: Int, _ h: Int, _ half: Bool) -> CVPixelBufferPool? {
        lock.lock(); defer { lock.unlock() }
        if let pool, poolKey == (w, h, half) { return pool }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: half ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary, attrs as CFDictionary, &p)
        pool = p
        poolKey = (w, h, half)
        return p
    }

    /// Why no frame was handed over, once per reason in a row.
    private func skip(_ why: String) -> UnsafeMutableRawPointer? {
        if why != lastSkip { lastSkip = why; trace("Metal: no frame: \(why)") }
        return nil
    }

    /// In the app log always (a new path), and in the PiP trace.
    private func trace(_ line: String) {
        dlog("metal", line)
        Task { @MainActor in PiPTrace.event(line) }
    }
}
