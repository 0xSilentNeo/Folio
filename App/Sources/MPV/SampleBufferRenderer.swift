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
/// This is how Outplayer does it (its 2026.10 binary: RenderingView's layer
/// class is AVSampleBufferDisplayLayer, used as the PiP content source;
/// vo=libmpv on OpenGL ES 3; each frame rendered into an IOSurface pixel
/// buffer through a texture-backed framebuffer, glFinish, then enqueued with
/// "display immediately"; PiP only changes the size frames are rendered at,
/// 0.5 s after the PiP window settles). Folio's Metal renderer instead swaps
/// mpv's video output at each PiP start and stop, and the 30 Oct log has
/// the picture stalling 177–236 ms and the sound stopping ~0.3 s right at
/// each swap.
///
/// GPU work: allowed while the app is active or PiP is up (Outplayer keeps
/// rendering in the background with PiP up); stopped, synchronously, when
/// the app goes to the background without PiP.
final class SampleBufferRenderer {
    private let queue = DispatchQueue(label: "glassplayer.gl", qos: .userInteractive)
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
    private var pipSize: (Int, Int)?
    private var lastLoggedSize = (0, 0)

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

    var isAttached: Bool { queue.sync { ctx != nil } }

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
            self.render()
        }
    }

    /// PiP's size for the frames (nil: PiP ended, back to the view's size).
    func setPiPSize(_ size: (Int, Int)?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pipSize = size
            self.render()
        }
    }

    func setFlip(_ flipped: Bool) {
        queue.async { [weak self] in
            self?.flipY = flipped ? 1 : 0
            self?.render()
        }
    }

    fileprivate func schedule() {
        queue.async { [weak self] in self?.render() }
    }

    private func render() {
        guard let c = ctx, allowed, let cache else { return }
        let (w, h) = pipSize ?? viewSize
        guard w > 0, h > 0 else { return }
        EAGLContext.setCurrent(eagl)
        guard let pool = ensurePool(w, h) else { return }
        var pbOut: CVPixelBuffer?
        // From a pool: a buffer the layer may still be showing is never drawn into.
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pbOut) == kCVReturnSuccess, let pb = pbOut else { return }
        var texOut: CVOpenGLESTexture?
        guard CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, GLenum(GL_TEXTURE_2D), GL_RGBA,
                                                           GLsizei(w), GLsizei(h), GLenum(GL_BGRA), GLenum(GL_UNSIGNED_BYTE), 0, &texOut) == kCVReturnSuccess,
              let tex = texOut else { return }
        glBindTexture(CVOpenGLESTextureGetTarget(tex), CVOpenGLESTextureGetName(tex))
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
        glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), CVOpenGLESTextureGetTarget(tex), CVOpenGLESTextureGetName(tex), 0)
        guard glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE) else { return }
        glViewport(0, 0, GLsizei(w), GLsizei(h))

        var target = mpv_opengl_fbo(fbo: Int32(fbo), w: Int32(w), h: Int32(h), internal_format: 0)
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
        guard r >= 0 else { return }
        // The GPU has finished the frame before the layer reads the surface.
        glFinish()
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)
        CVOpenGLESTextureCacheFlush(cache, 0)
        output(pb)
        if (w, h) != lastLoggedSize {
            lastLoggedSize = (w, h)
            let line = "frames now \(w)×\(h)\(pipSize != nil ? " (PiP's size)" : " (the player view's size)")"
            Task { @MainActor in PiPTrace.event(line) }
        }
    }

    private func ensurePool(_ w: Int, _ h: Int) -> CVPixelBufferPool? {
        if let pool, poolSize == (w, h) { return pool }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferOpenGLESCompatibilityKey as String: true,
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary, attrs as CFDictionary, &p)
        pool = p
        poolSize = (w, h)
        return p
    }

    private final class Box {
        weak var owner: SampleBufferRenderer?
        init(owner: SampleBufferRenderer) { self.owner = owner }
    }
}
