import QuartzCore

/// Calls a closure on each screen refresh while running. CADisplayLink
/// needs an NSObject target and retains it; this stands in for the owner,
/// which the closure holds weakly, and stops when told or freed.
@MainActor
final class FrameTicker: NSObject {
    private var link: CADisplayLink?
    private let tick: (CADisplayLink) -> Void

    init(_ tick: @escaping (CADisplayLink) -> Void) {
        self.tick = tick
        super.init()
    }

    var isRunning: Bool { link != nil }

    /// `fps`: at most this many calls a second (a whole range lets the
    /// display pick, so ProMotion isn't held at 120 Hz for nothing).
    func start(fps: Float = 60) {
        link?.invalidate()
        let l = CADisplayLink(target: self, selector: #selector(step(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, fps), maximum: fps, preferred: fps)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ l: CADisplayLink) { tick(l) }
}
