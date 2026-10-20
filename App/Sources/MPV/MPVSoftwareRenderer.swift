import Foundation
import CoreVideo

/// CPU renderer (MPV_RENDER_API_TYPE_SW) used while Picture in Picture is
/// active. It renders straight into IOSurface-backed pixel buffers with no
/// GPU involvement, so it keeps working after the app is backgrounded.
final class MPVSoftwareRenderer {
    private let queue = DispatchQueue(label: "glassplayer.sw", qos: .userInteractive)
    private var ctx: OpaquePointer?
    private var box: Unmanaged<Box>?
    private var pool: CVPixelBufferPool?
    private var poolSize: (Int, Int) = (0, 0)
    private var targetSize: (Int, Int) = (1280, 720)
    private let output: (CVPixelBuffer) -> Void
    // "bgra" makes mpv write opaque alpha; if this build rejects it we fall
    // back to "bgr0" and force alpha ourselves (bgr0 leaves it undefined,
    // which AVSampleBufferDisplayLayer may treat as transparent).
    private static let formatBGRA = strdup("bgra")!
    private static let formatBGR0 = strdup("bgr0")!
    private var useBGR0 = false

    init(output: @escaping (CVPixelBuffer) -> Void) {
        self.output = output
    }

    var isAttached: Bool { queue.sync { ctx != nil } }

    func attach(to client: MPVClient) throws {
        var err: Int32 = 0
        queue.sync {
            guard ctx == nil else { return }
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: gp_render_api_sw())),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            var c: OpaquePointer?
            err = mpv_render_context_create(&c, client.handle, &params)
            guard err >= 0, let c else { return }
            ctx = c
            let b = Unmanaged.passRetained(Box(owner: self))
            box = b
            mpv_render_context_set_update_callback(c, { raw in
                guard let raw else { return }
                Unmanaged<Box>.fromOpaque(raw).takeUnretainedValue().owner?.schedule()
            }, b.toOpaque())
        }
        if err < 0 { throw MPVClientError(code: err) }
    }

    func detach() {
        queue.sync {
            if let c = ctx {
                mpv_render_context_set_update_callback(c, nil, nil)
                mpv_render_context_free(c)
                ctx = nil
            }
            box?.release()
            box = nil
            pool = nil
        }
    }

    /// Output size follows the video aspect, capped to keep CPU cost down.
    func setVideoSize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        let maxH = 720.0, maxW = 1280.0
        let s = min(1.0, maxW / Double(width), maxH / Double(height))
        let w = max(16, Int(Double(width) * s) & ~15)
        let h = max(16, Int(Double(height) * s) & ~1)
        queue.async { self.targetSize = (w, h) }
    }

    private func schedule() {
        queue.async { [weak self] in self?.render() }
    }

    private func render() {
        guard let c = ctx else { return }
        let flags = mpv_render_context_update(c)
        guard flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { return }
        let (w, h) = targetSize
        guard let pool = ensurePool(w, h) else { return }
        var pbOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pbOut) == kCVReturnSuccess, let pb = pbOut else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        guard let base = CVPixelBufferGetBaseAddress(pb) else {
            CVPixelBufferUnlockBaseAddress(pb, [])
            return
        }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        var r = draw(c, base: base, stride: stride, w: w, h: h)
        if r < 0 && !useBGR0 {
            useBGR0 = true
            r = draw(c, base: base, stride: stride, w: w, h: h)
        }
        if r >= 0 && useBGR0 {
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<h {
                let row = bytes + y * stride
                var x = 3
                while x < w * 4 { row[x] = 255; x += 4 }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        mpv_render_context_report_swap(c)
        if r >= 0 { output(pb) }
    }

    private func draw(_ c: OpaquePointer, base: UnsafeMutableRawPointer, stride: Int, w: Int, h: Int) -> Int32 {
        var size: [Int32] = [Int32(w), Int32(h)]
        var strideValue = stride
        let format = useBGR0 ? Self.formatBGR0 : Self.formatBGRA
        return size.withUnsafeMutableBufferPointer { sp in
            withUnsafeMutablePointer(to: &strideValue) { stp in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(sp.baseAddress!)),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(format)),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(stp)),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: base),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                return mpv_render_context_render(c, &params)
            }
        }
    }

    private func ensurePool(_ w: Int, _ h: Int) -> CVPixelBufferPool? {
        if let pool, poolSize == (w, h) { return pool }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferBytesPerRowAlignmentKey as String: 64,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &p)
        pool = p
        poolSize = (w, h)
        return p
    }

    private final class Box {
        weak var owner: MPVSoftwareRenderer?
        init(owner: MPVSoftwareRenderer) { self.owner = owner }
    }
}
