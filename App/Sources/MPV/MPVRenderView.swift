import UIKit
import OpenGLES
import CoreVideo
import CoreMedia

/// OpenGL ES view mpv renders into via the render API (vo=libmpv).
///
/// All GL work happens on `renderQueue`. Rendering is hard-gated by
/// `renderingAllowed`, which the player flips off synchronously before the
/// app enters the background: iOS kills apps that submit GPU work while
/// backgrounded, even with Picture in Picture active.
final class MPVRenderView: UIView {
    override class var layerClass: AnyClass { CAEAGLLayer.self }
    private var eaglLayer: CAEAGLLayer { layer as! CAEAGLLayer }

    private let eagl: EAGLContext
    let renderQueue = DispatchQueue(label: "glassplayer.gl", qos: .userInteractive)

    private var renderContext: OpaquePointer?
    private var callbackBox: Unmanaged<CallbackBox>?

    private var fbo: GLuint = 0
    private var colorRB: GLuint = 0
    private var fbWidth: GLint = 0
    private var fbHeight: GLint = 0
    private var pendingSize: CGSize = .zero

    // Render-queue state
    private var renderingAllowed = true
    private var flipY: Int32 = 1

    // PiP preview feed (foreground only): GPU blit of each frame into an
    // IOSurface pixel buffer so the PiP layer always has current content.
    private var blitter: FrameBlitter?
    private var pipFeed: ((CVPixelBuffer) -> Void)?
    private var videoAspect: Double = 0

    private static var advancedControl: Int32 = 1

    static func make() -> MPVRenderView? {
        guard let ctx = EAGLContext(api: .openGLES3) else { return nil }
        return MPVRenderView(context: ctx)
    }

    private init(context ctx: EAGLContext) {
        eagl = ctx
        super.init(frame: .zero)
        backgroundColor = .black
        eaglLayer.isOpaque = true
        eaglLayer.drawableProperties = [
            kEAGLDrawablePropertyRetainedBacking: false,
            kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8,
        ]
        contentScaleFactor = UIScreen.main.nativeScale
        flipY = UserDefaults.standard.bool(forKey: SettingsKey.flipVideo) ? 0 : 1
    }

    required init?(coder: NSCoder) { fatalError() }

    var isAttached: Bool { renderQueue.sync { renderContext != nil } }

    // MARK: Attach / detach

    func attach(to client: MPVClient) throws {
        var err: Int32 = 0
        renderQueue.sync {
            guard renderContext == nil else { return }
            EAGLContext.setCurrent(eagl)
            var initParams = mpv_opengl_init_params(
                get_proc_address: { ctx, name in gp_gl_get_proc_address(ctx, name) },
                get_proc_address_ctx: nil
            )
            var ctx: OpaquePointer?
            withUnsafeMutablePointer(to: &initParams) { ip in
                withUnsafeMutablePointer(to: &Self.advancedControl) { adv in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: gp_render_api_opengl())),
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(ip)),
                        mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL, data: UnsafeMutableRawPointer(adv)),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    err = mpv_render_context_create(&ctx, client.handle, &params)
                }
            }
            guard err >= 0, let ctx else { return }
            renderContext = ctx
            let box = Unmanaged.passRetained(CallbackBox(view: self))
            callbackBox = box
            mpv_render_context_set_update_callback(ctx, { raw in
                guard let raw else { return }
                let box = Unmanaged<CallbackBox>.fromOpaque(raw).takeUnretainedValue()
                box.view?.scheduleRender()
            }, box.toOpaque())
        }
        if err < 0 { throw MPVClientError(code: err) }
        setNeedsLayout()
    }

    /// Frees the render context. Blocks until mpv has released the VO.
    func detach() {
        renderQueue.sync {
            // Nothing to free: avoid touching GL at all (may be backgrounded).
            guard renderContext != nil || fbo != 0 || blitter != nil else { return }
            EAGLContext.setCurrent(eagl)
            if let ctx = renderContext {
                mpv_render_context_set_update_callback(ctx, nil, nil)
                mpv_render_context_free(ctx)
                renderContext = nil
            }
            callbackBox?.release()
            callbackBox = nil
            blitter?.tearDown()
            blitter = nil
            deleteFramebuffer()
            glFinish()
            EAGLContext.setCurrent(nil)
        }
    }

    /// Synchronously enables/disables all GL work.
    func setRenderingAllowed(_ allowed: Bool) {
        renderQueue.sync {
            renderingAllowed = allowed
            if !allowed, renderContext != nil {
                EAGLContext.setCurrent(eagl)
                glFinish()
                EAGLContext.setCurrent(nil)
            }
        }
        if allowed { scheduleRender(force: true) }
    }

    func setPiPFeed(_ feed: ((CVPixelBuffer) -> Void)?) {
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.pipFeed = feed
            if feed == nil { self.blitter?.tearDown(); self.blitter = nil }
        }
    }

    func setVideoAspect(_ aspect: Double) {
        renderQueue.async { [weak self] in self?.videoAspect = aspect }
    }

    func setFlip(_ flipped: Bool) {
        renderQueue.async { [weak self] in
            self?.flipY = flipped ? 0 : 1
            self?.scheduleRender(force: true)
        }
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = CGSize(width: bounds.width * contentScaleFactor, height: bounds.height * contentScaleFactor)
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.pendingSize = size
            self.renderLocked(force: true)
        }
    }

    private func ensureFramebuffer() -> Bool {
        let w = GLint(pendingSize.width.rounded()), h = GLint(pendingSize.height.rounded())
        guard w > 0, h > 0 else { return false }
        if fbo != 0, w == fbWidth, h == fbHeight { return true }
        deleteFramebuffer()
        glGenRenderbuffers(1, &colorRB)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorRB)
        eagl.renderbufferStorage(Int(GL_RENDERBUFFER), from: eaglLayer)
        glGenFramebuffers(1, &fbo)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_RENDERBUFFER), colorRB)
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_WIDTH), &fbWidth)
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_HEIGHT), &fbHeight)
        return glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE)
    }

    private func deleteFramebuffer() {
        if fbo != 0 { glDeleteFramebuffers(1, &fbo); fbo = 0 }
        if colorRB != 0 { glDeleteRenderbuffers(1, &colorRB); colorRB = 0 }
        fbWidth = 0; fbHeight = 0
    }

    // MARK: Rendering

    fileprivate func scheduleRender(force: Bool = false) {
        renderQueue.async { [weak self] in self?.renderLocked(force: force) }
    }

    private func renderLocked(force: Bool) {
        guard let ctx = renderContext else { return }
        // Must be called after every update callback (advanced control).
        let flags = mpv_render_context_update(ctx)
        let hasFrame = flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0
        guard renderingAllowed, hasFrame || force else { return }

        EAGLContext.setCurrent(eagl)
        guard ensureFramebuffer() else { return }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
        glViewport(0, 0, fbWidth, fbHeight)

        var target = mpv_opengl_fbo(fbo: Int32(fbo), w: fbWidth, h: fbHeight, internal_format: 0)
        var flip = flipY
        let r: Int32 = withUnsafeMutablePointer(to: &target) { tp in
            withUnsafeMutablePointer(to: &flip) { fp in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(tp)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(fp)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                return mpv_render_context_render(ctx, &params)
            }
        }
        guard r >= 0 else { return }

        // Blit for the PiP layer before presenting (the renderbuffer content is
        // undefined after present when retained backing is off).
        if let feed = pipFeed {
            if blitter == nil { blitter = FrameBlitter(context: eagl) }
            if let pb = blitter?.blit(from: fbo, width: Int(fbWidth), height: Int(fbHeight), videoAspect: videoAspect, sourceIsBottomUp: flipY == 1) {
                feed(pb)
            }
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
        }

        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorRB)
        eagl.presentRenderbuffer(Int(GL_RENDERBUFFER))
        mpv_render_context_report_swap(ctx)
    }

    private final class CallbackBox {
        weak var view: MPVRenderView?
        init(view: MPVRenderView) { self.view = view }
    }
}

/// Copies the rendered frame (cropped to the video rect) into an
/// IOSurface-backed BGRA pixel buffer using glBlitFramebuffer.
final class FrameBlitter {
    private var cache: CVOpenGLESTextureCache?
    private var pool: CVPixelBufferPool?
    private var poolSize: (Int, Int) = (0, 0)
    private var dstFBO: GLuint = 0

    init?(context: EAGLContext) {
        var c: CVOpenGLESTextureCache?
        guard CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nil, context, nil, &c) == kCVReturnSuccess else { return nil }
        cache = c
        glGenFramebuffers(1, &dstFBO)
    }

    func tearDown() {
        if let cache { CVOpenGLESTextureCacheFlush(cache, 0) }
        cache = nil
        pool = nil
        if dstFBO != 0 { glDeleteFramebuffers(1, &dstFBO); dstFBO = 0 }
    }

    func blit(from srcFBO: GLuint, width: Int, height: Int, videoAspect: Double, sourceIsBottomUp: Bool) -> CVPixelBuffer? {
        guard let cache, width > 0, height > 0 else { return nil }
        // Video rect inside the drawable (letterboxed fit).
        var vx = 0, vy = 0, vw = width, vh = height
        if videoAspect > 0 {
            let viewAspect = Double(width) / Double(height)
            if videoAspect > viewAspect {
                vh = Int((Double(width) / videoAspect).rounded()); vy = (height - vh) / 2
            } else {
                vw = Int((Double(height) * videoAspect).rounded()); vx = (width - vw) / 2
            }
        }
        // Keep the PiP buffer modest.
        let scale = min(1.0, 1280.0 / Double(max(vw, 1)))
        let dw = max(2, Int(Double(vw) * scale) & ~1)
        let dh = max(2, Int(Double(vh) * scale) & ~1)
        guard let pool = ensurePool(dw, dh) else { return nil }
        var pbOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pbOut) == kCVReturnSuccess, let pb = pbOut else { return nil }

        var texOut: CVOpenGLESTexture?
        guard CVOpenGLESTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pb, nil, GLenum(GL_TEXTURE_2D), GL_RGBA,
            GLsizei(dw), GLsizei(dh), GLenum(GL_BGRA), GLenum(GL_UNSIGNED_BYTE), 0, &texOut
        ) == kCVReturnSuccess, let tex = texOut else { return nil }

        glBindTexture(CVOpenGLESTextureGetTarget(tex), CVOpenGLESTextureGetName(tex))
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), dstFBO)
        glFramebufferTexture2D(GLenum(GL_DRAW_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
                               CVOpenGLESTextureGetTarget(tex), CVOpenGLESTextureGetName(tex), 0)
        guard glCheckFramebufferStatus(GLenum(GL_DRAW_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
            glBindTexture(GLenum(GL_TEXTURE_2D), 0)
            return nil
        }
        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), srcFBO)
        // Memory row 0 of the pixel buffer is the image top; a bottom-up GL
        // source therefore has to be flipped while blitting.
        let (y0, y1): (GLint, GLint) = sourceIsBottomUp ? (GLint(dh), 0) : (0, GLint(dh))
        glBlitFramebuffer(GLint(vx), GLint(vy), GLint(vx + vw), GLint(vy + vh),
                          0, y0, GLint(dw), y1,
                          GLbitfield(GL_COLOR_BUFFER_BIT), GLenum(GL_LINEAR))
        glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), 0)
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)
        glFlush()
        CVOpenGLESTextureCacheFlush(cache, 0)
        return pb
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
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &p)
        pool = p
        poolSize = (w, h)
        return p
    }
}
