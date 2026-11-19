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
        // 60 a second asked for, not 120 (0.90.0): asking for 120 held a
        // ProMotion screen at its top rate for the whole watch. A frame
        // over 25 ms shows at 60 as well, and while something else runs the
        // screen at 120 this is still called for each frame.
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 60)
        l.add(to: .main, forMode: .common)
        link = l
    }

    /// Starts watching (a new start under the same tag replaces the old one).
    static func start(_ tag: String, _ what: String, seconds: Double = 1.5) {
        // Only while a trace is on (1.28.4): every player button started a
        // second of 120 Hz display link, held ProMotion up, and logged a line.
        // For the trace it belongs to only (0.90.0): the player's buttons
        // ("ui") with the Picture in Picture trace, the tabs and the search
        // with the library trace. Either trace started both.
        guard wanted(tag, lib: LibTrace.on, pip: PiPTrace.on) else { return }
        // Not while the screen is recorded (0.90.0): the recorder's own
        // work is in every frame's time, and a display link on top makes
        // the recording worse. Said in one line when it starts ("[trace]
        // paused while the screen is recorded"), by TraceFlags; asked again
        // here for a trace turned on after the recording began.
        guard !TraceFlags.captured else {
            running[tag]?.link?.invalidate()
            running[tag] = nil
            TraceFlags.noteCapture()
            return
        }
        running[tag]?.link?.invalidate()
        running[tag] = HitchProbe(tag: tag, what: what, seconds: seconds)
    }

    /// Which trace a tag's frames are timed for.
    nonisolated static func wanted(_ tag: String, lib: Bool, pip: Bool) -> Bool {
        tag == "ui" ? pip : lib
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
