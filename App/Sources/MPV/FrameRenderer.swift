import CoreGraphics

/// A renderer whose frames go into the player's video layer, the one
/// Picture in Picture takes over (1.28.0): OpenGL (SampleBufferRenderer) or
/// Metal (MetalFrameRenderer). PiP, the background, Fill and the subtitle
/// framing work the same for both: the frames are the video's shape and
/// the layer fits or fills them, nothing is swapped when PiP starts, and
/// GPU work stops while the app is away without PiP.
protocol FrameRenderer: AnyObject {
    /// Synchronously allows or stops all GPU work (stopped: the app is going
    /// to the background without PiP).
    func setRenderingAllowed(_ on: Bool, why: String)
    /// The player view's size, in pixels.
    func setViewSize(_ size: CGSize)
    /// The video's display size: frames take its shape, fitted in the view.
    func setVideoSize(_ w: Int, _ h: Int)
    /// PiP's size for the frames (nil: PiP ended).
    func setPiPSize(_ size: (Int, Int)?)
    /// HDR frames (half-float, tagged BT.2020 PQ/HLG), or SDR (nil).
    func setHDR(_ h: SampleBufferRenderer.HDROutput?)
    /// Told when HDR frames can't be made here: the player goes back to SDR.
    var onHDRFailed: (() -> Void)? { get set }
    /// Lets go of mpv: no more frames.
    func detach()
}

extension SampleBufferRenderer: FrameRenderer {}
