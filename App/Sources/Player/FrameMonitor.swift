import UIKit

/// Measures how smoothly a transition ran on the main thread: frame-to-frame
/// times from CADisplayLink while it runs, logged as one line, e.g.
/// "panel open settings: 31 frames in 412 ms, worst 48 ms, 3 late".
/// A "late" frame took more than 1.5× the display's frame time.
@MainActor
final class FrameMonitor: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var started: CFTimeInterval = 0
    private var deltas: [Double] = []
    private var label = ""
    private var extra = ""

    func begin(_ label: String) {
        if link != nil { end() }
        self.label = label
        extra = ""
        deltas = []
        last = 0
        started = CACurrentMediaTime()
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    /// Notes something measured along the way (e.g. how long building the panel took).
    func note(_ s: String) { extra += (extra.isEmpty ? "" : ", ") + s }

    func end() {
        guard let l = link else { return }
        l.invalidate()
        link = nil
        let total = (CACurrentMediaTime() - started) * 1000
        let frame = 1000.0 / Double(max(60, UIScreen.main.maximumFramesPerSecond))
        let late = deltas.filter { $0 > frame * 1.5 }.count
        let worst = deltas.max() ?? 0
        dlog("perf", String(format: "%@: %d frames in %.0f ms, worst %.0f ms, %d late (frame %.1f ms)%@",
                            label, deltas.count, total, worst, late, frame, extra.isEmpty ? "" : " · " + extra))
    }

    @objc private func tick(_ l: CADisplayLink) {
        if last > 0 { deltas.append((l.timestamp - last) * 1000) }
        last = l.timestamp
        if CACurrentMediaTime() - started > 3 { end() }      // safety
    }
}
