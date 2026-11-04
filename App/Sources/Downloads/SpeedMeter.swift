import Foundation

/// The download speed over the last few seconds (1.22.3), and whether it
/// may give the Live Activity an estimate yet.
///
/// Until 1.22.2 the speed was a running average seeded with the first
/// reading, and the Live Activity's time left was taken from it as soon as
/// there was one: the first seconds of a download, while its connections
/// are still starting. On the 4 Nov phone report that was 337 KB/s, so the
/// activity said 46 minutes for a file that was in 25 s later; Folio was
/// then suspended (iOS's background session downloaded alone) and nothing
/// corrected it until the end. Now the speed is what came in over the last
/// `window` seconds, and there's no estimate until bytes have flowed for
/// `settle` seconds.
struct SpeedMeter {
    /// Readings older than this no longer count.
    static let window: TimeInterval = 5
    /// No estimate before bytes have come in for this long.
    static let settle: TimeInterval = 3

    /// Bytes counted so far, and when each reading was taken.
    private var samples: [(t: TimeInterval, total: Int64)] = []
    private(set) var total: Int64 = 0
    /// When bytes started coming in (the reading before the first one with any).
    private var flowSince: TimeInterval?

    /// `bytes` came in since the last reading, at `t` (seconds, any clock).
    mutating func add(_ bytes: Int64, at t: TimeInterval) {
        if bytes > 0, flowSince == nil { flowSince = samples.last?.t ?? t }
        total += max(0, bytes)
        samples.append((t, total))
        // The window's readings and the one before it (an average over a long gap).
        while samples.count > 2, samples[1].t <= t - Self.window { samples.removeFirst() }
    }

    /// Bytes per second over the window, or since the reading before it
    /// when there's none in it (Folio was suspended meanwhile).
    var rate: Double {
        guard samples.count >= 2, let last = samples.last else { return 0 }
        let from = samples.first { $0.t >= last.t - Self.window && $0.t < last.t } ?? samples[samples.count - 2]
        let dt = last.t - from.t
        return dt > 0 ? Double(last.total - from.total) / dt : 0
    }

    /// Bytes have come in long enough for the speed to say when the run ends.
    func settled(at t: TimeInterval) -> Bool { flowSince.map { t - $0 >= Self.settle } ?? false }

    /// The speed to estimate the time left from; 0 until it has settled.
    func estimate(at t: TimeInterval) -> Double { settled(at: t) ? rate : 0 }

    mutating func reset() {
        samples.removeAll()
        total = 0
        flowSince = nil
    }
}
