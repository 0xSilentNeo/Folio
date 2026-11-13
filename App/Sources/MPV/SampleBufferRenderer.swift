import UIKit
import OpenGLES
import CoreVideo
import CoreMedia

/// mpv's OpenGL renderer (vo=libmpv) drawing every frame into an
/// IOSurface-backed pixel buffer that goes to Picture in Picture's
/// AVSampleBufferDisplayLayer — which is also the player's own picture. So
/// there is nothing to hand over when PiP starts or stops: the same frames,
/// from the same output, keep going into the same layer.
///
/// How: the view's layer is an AVSampleBufferDisplayLayer, used as the PiP
/// content source; vo=libmpv on OpenGL ES 3; each frame rendered into an
/// IOSurface pixel buffer through a texture-backed framebuffer, glFinish,
/// then enqueued with "display immediately"; PiP only changes the size
/// frames are rendered at, 0.5 s after the PiP window settles. Folio's Metal renderer instead swaps
/// mpv's video output at each PiP start and stop, and the 30 Oct log has
/// the picture stalling 177–236 ms and the sound stopping ~0.3 s right at
/// each swap.
///
/// GPU work: allowed while the app is active or PiP is up (rendering goes
/// on in the background while PiP is up); stopped, synchronously, when the
/// app goes to the background without PiP.
final class SampleBufferRenderer {
    private let queue = DispatchQueue(label: "folio.gl", qos: .userInteractive)
    private let eagl: EAGLContext
    private let output: (CVPixelBuffer) -> Void

    // Render-queue state
    private var ctx: OpaquePointer?
    private var box: Unmanaged<Box>?
    private var cache: CVOpenGLESTextureCache?
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private var fbo: GLuint = 0
    private var allowed = true
    private var flipY: Int32 = 0
    /// The view's size in pixels, and PiP's (when PiP is up and has said).
    private var viewSize = (0, 0)
    /// The video's display size (mpv's dwidth × dheight), once known.
    private var videoSize: (Int, Int)?
    private var pipSize: (Int, Int)?
    private var lastLoggedSize = (0, 0)
    /// The last reason a frame wasn't drawn (logged once each time it changes).
    private var lastSkip: String?
    /// A render is already waiting on the queue: mpv's updates that come
    /// meanwhile are served by it. Each update used to queue a render of its
    /// own, and the extra ones drew the same frame again (review, 2 Nov).
    private let queuedLock = NSLock()
    private var queued = false
    /// Pool buffers whose framebuffer was checked complete (the pool hands
    /// the same few buffers back): the check stalls the GPU, once is enough.
    private var checked = Set<ObjectIdentifier>()

    /// HDR output (1.22.1). An HDR video is drawn by mpv in BT.2020 with the
    /// PQ (or HLG) curve into half-float pixel buffers, and each buffer is
    /// tagged with that colour and the video's light levels, so the layer,
    /// in the app and in Picture in Picture, shows it as HDR. Nil: SDR,
    /// 8-bit buffers, untagged, as before.
    struct HDROutput: Equatable {
        var hlg: Bool
        var maxCLL: Int?
        var maxFALL: Int?
        var maxLuma: Double?
        var minLuma: Double?
    }
    private var hdr: HDROutput?
    /// Told when half-float frames can't be made: the player goes back to SDR.
    var onHDRFailed: (() -> Void)?

    func setHDR(_ h: HDROutput?) {
        queue.async { [weak self] in
            guard let self, h != self.hdr else { return }
            self.hdr = h
            self.pool = nil                 // a new pixel format
            self.checked = []
            self.trace(h.map { "HDR output on: \($0.hlg ? "HLG" : "PQ") BT.2020, half-float frames, MaxCLL \($0.maxCLL.map(String.init) ?? "?") nits" } ?? "HDR output off: 8-bit frames")
            self.render()
        }
    }

    static func make(output: @escaping (CVPixelBuffer) -> Void) -> SampleBufferRenderer? {
        guard let ctx = EAGLContext(api: .openGLES3) else { return nil }
        return SampleBufferRenderer(context: ctx, output: output)
    }

    private init(context: EAGLContext, output: @escaping (CVPixelBuffer) -> Void) {
        eagl = context
        self.output = output
        // Settings → Player → Flip video, for a device that shows it upside
        // down: pixel buffers are top row first, so normally no flip.
        flipY = UserDefaults.standard.bool(forKey: SettingsKey.flipVideo) ? 1 : 0
    }

    func attach(to client: MPVClient) throws {
        var err: Int32 = 0
        queue.sync {
            guard ctx == nil else { return }
            EAGLContext.setCurrent(eagl)
            var initParams = mpv_opengl_init_params(
                get_proc_address: { ctx, name in gp_gl_get_proc_address(ctx, name) },
                get_proc_address_ctx: nil
            )
            var c: OpaquePointer?
            withUnsafeMutablePointer(to: &initParams) { ip in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: gp_render_api_opengl())),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(ip)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                err = mpv_render_context_create(&c, client.handle, &params)
            }
            guard err >= 0, let c else { return }
            ctx = c
            var tc: CVOpenGLESTextureCache?
            CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nil, eagl, nil, &tc)
            cache = tc
            glGenFramebuffers(1, &fbo)
            let b = Unmanaged.passRetained(Box(owner: self))
            box = b
            // One render per update, in order, on this queue. Without advanced
            // control mpv paces the frames itself: a render returns when its
            // frame is due (mpv_render_context_render, BLOCK_FOR_TARGET_TIME).
            mpv_render_context_set_update_callback(c, { raw in
                guard let raw else { return }
                Unmanaged<Box>.fromOpaque(raw).takeUnretainedValue().owner?.schedule()
            }, b.toOpaque())
        }
        if err < 0 { throw MPVClientError(code: err) }
    }

    /// Frees the render context. Blocks until mpv has let go of it.
    func detach() {
        queue.sync {
            guard ctx != nil || fbo != 0 else { return }
            EAGLContext.setCurrent(eagl)
            if let c = ctx {
                mpv_render_context_set_update_callback(c, nil, nil)
                mpv_render_context_free(c)
                ctx = nil
            }
            box?.release()
            box = nil
            if fbo != 0 { glDeleteFramebuffers(1, &fbo); fbo = 0 }
            if let cache { CVOpenGLESTextureCacheFlush(cache, 0) }
            cache = nil
            pool = nil
            glFinish()
            EAGLContext.setCurrent(nil)
        }
    }

    /// Synchronously allows or stops all GPU work (stopped: the app is going
    /// to the background without PiP).
    func setRenderingAllowed(_ on: Bool, why: String) {
        let changed: Bool = queue.sync {
            let was = allowed
            allowed = on
            if !on, ctx != nil {
                EAGLContext.setCurrent(eagl)
                glFinish()
                EAGLContext.setCurrent(nil)
            }
            return was != on
        }
        if changed { Task { @MainActor in PiPTrace.event("rendering \(on ? "on" : "off") (\(why))") } }
        if on { schedule() }
    }

    /// The player view's size, in pixels.
    func setViewSize(_ size: CGSize) {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        queue.async { [weak self] in
            guard let self, (w, h) != self.viewSize else { return }
            self.viewSize = (w, h)
            self.trace("view size now \(w)×\(h) px")
            self.render()
        }
    }

    /// The video's display size. Frames take its shape, fitted inside the
    /// view, not the view's: PiP's window takes the shape of the frames it's
    /// given, and a frame with mpv's black bars drawn in (a portrait view, a
    /// 2.17:1 landscape view around a 16:9 video) made the window the
    /// screen's shape (independent review, 1.20.0). The layer letterboxes
    /// them in the app (resizeAspect, its default).
    func setVideoSize(_ w: Int, _ h: Int) {
        queue.async { [weak self] in
            guard let self, w > 0, h > 0, self.videoSize.map({ $0 != (w, h) }) ?? true else { return }
            self.videoSize = (w, h)
            self.render()
        }
    }

    /// The frame size outside PiP: the video's shape fitted inside the view
    /// (even numbers), or the view's size while the video's isn't known.
    private func mainSize() -> (Int, Int) {
        guard let v = videoSize, viewSize.0 > 0, viewSize.1 > 0 else { return viewSize }
        // At most twice the video's own size: a small video on a big iPad
        // screen was drawn at 2732×1536, for no sharper picture.
        let scale = min(Double(viewSize.0) / Double(v.0), Double(viewSize.1) / Double(v.1), 2)
        return (max(2, Int(Double(v.0) * scale) & ~1), max(2, Int(Double(v.1) * scale) & ~1))
    }

    /// PiP's size for the frames (nil: PiP ended, back to the view's size).
    func setPiPSize(_ size: (Int, Int)?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pipSize = size
            self.render()
        }
    }

    fileprivate func schedule() {
        queuedLock.lock()
        if queued { queuedLock.unlock(); return }
        queued = true
        queuedLock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            // Cleared first: an update during this render queues the next one.
            self.queuedLock.lock(); self.queued = false; self.queuedLock.unlock()
            self.render()
        }
    }

    private func render() {
        guard let c = ctx, allowed, let cache else { return }
        let (w, h) = pipSize ?? mainSize()
        guard w > 0, h > 0 else { return skip("the player view has no size yet") }
        EAGLContext.setCurrent(eagl)
        guard let pool = ensurePool(w, h) else { return skip("no pixel buffer pool for \(w)×\(h)") }
        var pbOut: CVPixelBuffer?
        // From a pool: a buffer the layer may still be showing is never drawn into.
        let made = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pbOut)
        guard made == kCVReturnSuccess, let pb = pbOut else { return skip("no pixel buffer (\(made))") }
        var texOut: CVOpenGLESTexture?
        let half = hdr != nil
        let wrapped = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, GLenum(GL_TEXTURE_2D),
                                                                   half ? GLint(GL_RGBA16F) : GL_RGBA, GLsizei(w), GLsizei(h),
                                                                   GLenum(half ? GL_RGBA : GL_BGRA), GLenum(half ? GL_HALF_FLOAT : GL_UNSIGNED_BYTE), 0, &texOut)
        guard wrapped == kCVReturnSuccess, let tex = texOut else {
            if half {
                // No half-float frames on this device: SDR rather than nothing.
                trace("HDR output not possible: no half-float texture (\(wrapped)); back to SDR")
                hdr = nil; self.pool = nil; checked = []
                if let failed = onHDRFailed { DispatchQueue.main.async(execute: failed) }
                return render()
            }
            return skip("no texture for the pixel buffer (\(wrapped))")
        }
        glBindTexture(CVOpenGLESTextureGetTarget(tex), CVOpenGLESTextureGetName(tex))
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
        glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), CVOpenGLESTextureGetTarget(tex), CVOpenGLESTextureGetName(tex), 0)
        if !checked.contains(ObjectIdentifier(pb)) {
            let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
            guard status == GLenum(GL_FRAMEBUFFER_COMPLETE) else { return skip("framebuffer incomplete (0x\(String(status, radix: 16)))") }
            checked.insert(ObjectIdentifier(pb))
        }
        glViewport(0, 0, GLsizei(w), GLsizei(h))

        // The framebuffer's real format, so mpv draws (and dithers) for its depth.
        var target = mpv_opengl_fbo(fbo: Int32(fbo), w: Int32(w), h: Int32(h), internal_format: half ? Int32(GL_RGBA16F) : 0)
        var flip = flipY
        let r: Int32 = withUnsafeMutablePointer(to: &target) { tp in
            withUnsafeMutablePointer(to: &flip) { fp in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(tp)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(fp)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                return mpv_render_context_render(c, &params)
            }
        }
        guard r >= 0 else { return skip("mpv couldn't render (\(r))") }
        // The GPU has finished the frame before the layer reads the surface.
        glFinish()
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)
        CVOpenGLESTextureCacheFlush(cache, 0)
        if let hdr { Self.tag(pb, hdr) }
        output(pb)
        lastSkip = nil
        if (w, h) != lastLoggedSize {
            lastLoggedSize = (w, h)
            let line = "frames now \(w)×\(h)\(pipSize != nil ? " (PiP's size)" : videoSize != nil ? " (the video's shape in the player view)" : " (the player view's size)")"
            Task { @MainActor in PiPTrace.event(line) }
        }
    }

    /// Why no frame was drawn, once per reason in a row (render queue).
    private func skip(_ why: String) {
        guard why != lastSkip else { return }
        lastSkip = why
        trace("no frame: \(why)")
    }

    private func trace(_ line: String) { Task { @MainActor in PiPTrace.event(line) } }

    /// The colour and light levels iOS needs to show a frame as HDR.
    static func tag(_ pb: CVPixelBuffer, _ h: HDROutput) {
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey,
                              h.hlg ? kCVImageBufferTransferFunction_ITU_R_2100_HLG : kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        if let data = contentLightLevel(h) { CVBufferSetAttachment(pb, kCVImageBufferContentLightLevelInfoKey, data as CFData, .shouldPropagate) }
        if let data = masteringDisplay(h) { CVBufferSetAttachment(pb, kCVImageBufferMasteringDisplayColorVolumeKey, data as CFData, .shouldPropagate) }
    }

    /// MaxCLL and MaxFALL, two big-endian 16-bit numbers (HEVC's content
    /// light level SEI), from mpv's video-params; nil when the file has none.
    static func contentLightLevel(_ h: HDROutput) -> Data? {
        guard let cll = h.maxCLL, cll > 0 else { return nil }
        var d = Data()
        for v in [cll, h.maxFALL ?? 0] { withUnsafeBytes(of: UInt16(clamping: v).bigEndian) { d.append(contentsOf: $0) } }
        return d
    }

    /// The mastering display (HEVC's SEI layout, 24 bytes): BT.2020's
    /// primaries in green, blue, red order and D65 white in 0.00002 steps,
    /// then the max and min luminance from mpv in 0.0001 nit steps. Nil
    /// without a max luminance.
    static func masteringDisplay(_ h: HDROutput) -> Data? {
        guard let maxL = h.maxLuma, maxL > 0 else { return nil }
        var d = Data()
        let xy: [Double] = [0.170, 0.797, 0.131, 0.046, 0.708, 0.292, 0.3127, 0.3290]
        for v in xy { withUnsafeBytes(of: UInt16((v / 0.00002).rounded()).bigEndian) { d.append(contentsOf: $0) } }
        for v in [maxL, h.minLuma ?? 0] { withUnsafeBytes(of: UInt32(clamping: Int((v / 0.0001).rounded())).bigEndian) { d.append(contentsOf: $0) } }
        return d
    }

    private func ensurePool(_ w: Int, _ h: Int) -> CVPixelBufferPool? {
        if let pool, poolSize == (w, h) { return pool }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: hdr != nil ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            // IOSurface-backed, usable as an OpenGL ES texture and as the
            // framebuffer mpv draws into. Without the last three the texture
            // cache could refuse the buffer (-6683, kCVReturnPixelBufferNot-
            // OpenGLCompatible): every frame dropped, the simulator always.
            kCVPixelBufferIOSurfacePropertiesKey as String: [
                kCVPixelBufferIOSurfaceOpenGLESTextureCompatibilityKey as String: true,
                kCVPixelBufferIOSurfaceOpenGLESFBOCompatibilityKey as String: true,
            ],
            kCVPixelBufferOpenGLESCompatibilityKey as String: true,
            kCVPixelBufferOpenGLESTextureCacheCompatibilityKey as String: true,
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary, attrs as CFDictionary, &p)
        pool = p
        checked = []
        poolSize = (w, h)
        return p
    }

    private final class Box {
        weak var owner: SampleBufferRenderer?
        init(owner: SampleBufferRenderer) { self.owner = owner }
    }
}
