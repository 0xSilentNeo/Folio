import AVKit
import AVFoundation
import CoreMedia
import UIKit

/// View hosting the AVSampleBufferDisplayLayer that Picture in Picture shows.
/// It sits *behind* the opaque GL view, so it is in the window with a real
/// size (PiP requires that) without ever being visible.
final class SampleBufferView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

protocol PiPManagerDelegate: AnyObject {
    func pipWillStart()
    func pipDidStart()
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
    private(set) var isActive = false

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
        guard Self.isSupported, controller == nil else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: view.displayLayer, playbackDelegate: self)
        let c = AVPictureInPictureController(contentSource: source)
        c.delegate = self
        c.canStartPictureInPictureAutomaticallyFromInline = autoStart
        controller = c
        possibleObservation = c.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            let possible = c.isPictureInPicturePossible
            DispatchQueue.main.async { self?.onPossibleChanged?(possible) }
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

    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        delegate?.pipSkip(by: skipInterval.seconds)
        completionHandler()
    }
}
