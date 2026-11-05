import QuartzCore
import UIKit

/// Frames the main thread drew late (over 25 ms apart) for a moment after
/// something starts, logged once: "[tag] what: frames over 25 ms: 48 ms at
/// +120 ms". Used where a screen felt slow to open (the search, 1.23.0), so
/// a report shows where the time went.
@MainActor
final class HitchProbe: NSObject {
    private static var running: [String: HitchProbe] = [:]

    private let tag: String
    private let what: String
    private let start = CACurrentMediaTime()
    private let until: CFTimeInterval
    private var last: CFTimeInterval = 0
    private var hitches: [String] = []
    private var worst = 0.0
    private var link: CADisplayLink?
    private var marks: [String] = []

    private init(tag: String, what: String, seconds: Double) {
        self.tag = tag
        self.what = what
        until = start + seconds
        super.init()
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    /// Starts watching (a new start under the same tag replaces the old one).
    static func start(_ tag: String, _ what: String, seconds: Double = 1.5) {
        running[tag]?.link?.invalidate()
        running[tag] = HitchProbe(tag: tag, what: what, seconds: seconds)
    }

    /// A step to show on the same line ("page appeared at +40 ms").
    static func mark(_ tag: String, _ step: String) {
        guard let p = running[tag] else { return }
        p.marks.append("\(step) at +\(Int((CACurrentMediaTime() - p.start) * 1000)) ms")
    }

    @objc private func tick(_ l: CADisplayLink) {
        if last > 0 {
            let gap = (l.timestamp - last) * 1000
            if gap > 25 {
                hitches.append("\(Int(gap)) ms at +\(Int((last - start) * 1000))")
                worst = max(worst, gap)
            }
        }
        last = l.timestamp
        guard CACurrentMediaTime() > until else { return }
        l.invalidate()
        link = nil
        if Self.running[tag] === self { Self.running[tag] = nil }
        let frames = hitches.isEmpty ? "no frame over 25 ms" : "frames over 25 ms: " + hitches.prefix(12).joined(separator: ", ")
        dlog(tag, "\(what): \(frames)" + (marks.isEmpty ? "" : "; " + marks.joined(separator: ", ")))
    }
}
