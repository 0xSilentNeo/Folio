import AVKit
import AVFoundation
import CoreMedia
import UIKit
import QuartzCore

/// View hosting the AVSampleBufferDisplayLayer that Picture in Picture shows.
/// OpenGL renderer (1.20.0): it is the player's picture too. Metal: it sits
/// behind the Metal view, in the window with a real size (PiP requires
/// that), and comes to the front only while PiP hands back.
final class SampleBufferView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    /// The view's size in pixels, after each layout (the OpenGL renderer draws at it).
    var onLayout: ((CGSize) -> Void)?
    /// Layout passes so far (trace).
    private(set) var layouts = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        layouts += 1
        reportSize()
    }

    /// Hands the current size to `onLayout` now (the OpenGL renderer starts
    /// listening in viewDidAppear, after the view's layout has happened).
    func reportSize() {
        let scale = window?.screen.scale ?? UIScreen.main.scale
        onLayout?(CGSize(width: bounds.width * scale, height: bounds.height * scale))
    }
}

protocol PiPManagerDelegate: AnyObject {
    func pipWillStart()
    func pipDidStart()
    func pipWillStop()
    func pipDidStop()
    func pipFailed(_ error: Error)
    func pipRestoreUI(_ completion: @escaping (Bool) -> Void)
    func pipSetPlaying(_ playing: Bool)
    func pipSkip(by seconds: Double)
    var pipIsPaused: Bool { get }
    var pipDuration: Double { get }
}

final class PiPManager: NSObject {
    let view: SampleBufferView
    /// Captured once so render threads never touch UIView APIs.
    private let displayLayer: AVSampleBufferDisplayLayer
    weak var delegate: PiPManagerDelegate?

    private var controller: AVPictureInPictureController?
    private var timebase: CMTimebase?
    private var possibleObservation: NSKeyValueObservation?
    private let enqueueLock = NSLock()
    private var formatDescription: CMVideoFormatDescription?
    private var lastDims: (Int32, Int32) = (0, 0)

    var onPossibleChanged: ((Bool) -> Void)?
    /// The size PiP draws its window at, in pixels, as it changes.
    var onRenderSize: ((CMVideoDimensions) -> Void)?
    private(set) var isActive = false

    /// When the last frame went into the PiP layer, and how many so far
    /// (PiPTrace: which picture the layer holds when it's in front).
    private var lastEnqueue: CFTimeInterval = 0
    private var enqueued = 0
    var lastFrameAge: Double? {
        enqueueLock.lock(); defer { enqueueLock.unlock() }
        return lastEnqueue > 0 ? CACurrentMediaTime() - lastEnqueue : nil
    }
    var framesEnqueued: Int { enqueueLock.lock(); defer { enqueueLock.unlock() }; return enqueued }

    /// PiP trace: when each of the last frames went into the layer.
    private var frameTimes: [CFTimeInterval] = []

    /// PiP trace: the frames that went into the layer since `start`, and the
    /// longest gaps between them (what the picture did through a transition).
    func frameGaps(since start: CFTimeInterval) -> String {
        enqueueLock.lock(); let times = frameTimes.filter { $0 >= start }; enqueueLock.unlock()
        guard times.count > 1 else { return "; layer frames: \(times.count)" }
        let gaps = zip(times.dropFirst(), times).map { ($0 - $1, $1 - start) }.sorted { $0.0 > $1.0 }.prefix(3)
        return "; layer frames: \(times.count) in \(Int((times.last! - times.first!) * 1000)) ms, longest gaps "
            + gaps.map { "\(Int($0.0 * 1000)) ms from +\(Int($0.1 * 1000))" }.joined(separator: ", ")
    }

    override init() {
        let v = SampleBufferView()
        view = v
        displayLayer = v.displayLayer
        super.init()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.displayLayer.videoGravity = .resizeAspect

        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
        if let tb {
            CMTimebaseSetTime(tb, time: .zero)
            CMTimebaseSetRate(tb, rate: 0)
            view.displayLayer.controlTimebase = tb
            timebase = tb
        }
    }

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func setUp(autoStart: Bool) {
        Task { @MainActor in PiPTrace.event("PiP supported: \(Self.isSupported ? "yes" : "no")") }
        guard Self.isSupported, controller == nil else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: view.displayLayer, playbackDelegate: self)
        let c = AVPictureInPictureController(contentSource: source)
        c.delegate = self
        c.canStartPictureInPictureAutomaticallyFromInline = autoStart
        controller = c
        possibleObservation = c.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            let possible = c.isPictureInPicturePossible
            DispatchQueue.main.async { self?.onPossibleChanged?(possible) }
            Task { @MainActor in PiPTrace.event("PiP \(possible ? "possible" : "not possible")") }
        }
    }

    func setAutoStart(_ on: Bool) {
        controller?.canStartPictureInPictureAutomaticallyFromInline = on
    }

    func start() { controller?.startPictureInPicture() }
    func stop() { controller?.stopPictureInPicture() }

    func tearDown() {
        possibleObservation = nil
        if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
        controller?.delegate = nil
        controller = nil
        view.displayLayer.flushAndRemoveImage()
    }

    /// Keeps the PiP progress bar in sync with mpv.
    func updatePlayback(position: Double, rate: Double) {
        guard let timebase, position.isFinite else { return }
        CMTimebaseSetTime(timebase, time: CMTime(seconds: max(0, position), preferredTimescale: 1000))
        CMTimebaseSetRate(timebase, rate: rate)
    }

    func invalidate() {
        controller?.invalidatePlaybackState()
    }

    /// Thread-safe; called from render queues.
    func enqueue(_ pixelBuffer: CVPixelBuffer) {
        enqueueLock.lock()
        defer { enqueueLock.unlock() }
        let w = Int32(CVPixelBufferGetWidth(pixelBuffer)), h = Int32(CVPixelBufferGetHeight(pixelBuffer))
        if formatDescription == nil || lastDims != (w, h) {
            var fd: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &fd)
            formatDescription = fd
            lastDims = (w, h)
        }
        guard let fd = formatDescription else { return }
        let pts = timebase.map { CMTimebaseGetTime($0) } ?? .zero
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                 formatDescription: fd, sampleTiming: &timing, sampleBufferOut: &sb)
        guard let sb else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sb)
        lastEnqueue = CACurrentMediaTime()
        enqueued += 1
        if UserDefaults.standard.bool(forKey: SettingsKey.pipTrace) {   // PiPTrace.on, off the main thread
            frameTimes.append(lastEnqueue)
            if frameTimes.count > 600 { frameTimes.removeFirst(frameTimes.count - 600) }
        }
    }

    /// Frame sink for the renderers (built outside any actor context).
    func makeSink() -> (CVPixelBuffer) -> Void {
        return { [weak self] pb in self?.enqueue(pb) }
    }
}

extension PiPManager: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
        isActive = true
        delegate?.pipWillStart()
    }
    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        delegate?.pipDidStart()
    }
    func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        isActive = false
        delegate?.pipFailed(error)
    }
    func pictureInPictureControllerWillStopPictureInPicture(_ c: AVPictureInPictureController) {
        delegate?.pipWillStop()
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        isActive = false
        delegate?.pipDidStop()
    }
    func pictureInPictureController(_ c: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        if let delegate { delegate.pipRestoreUI(completionHandler) } else { completionHandler(true) }
    }
}

extension PiPManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
        delegate?.pipSetPlaying(playing)
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        let d = delegate?.pipDuration ?? 0
        if d > 0 { return CMTimeRange(start: .zero, duration: CMTime(seconds: d, preferredTimescale: 1000)) }
        return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool {
        delegate?.pipIsPaused ?? true
    }

    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        onRenderSize?(newRenderSize)
    }

    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        delegate?.pipSkip(by: skipInterval.seconds)
        completionHandler()
    }
}
