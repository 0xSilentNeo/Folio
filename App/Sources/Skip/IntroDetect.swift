import Foundation
import Accelerate

/// Finding a show's intro on the phone (1.30.0): the opening is the same
/// sound in every episode, so the first minutes of two episodes are compared
/// and the long stretch they share is the intro. This file is the arithmetic,
/// with no files and no player in it: a fingerprint of the sound, the
/// comparison of two fingerprints, and which episode to compare with.
/// IntroFinder.swift decodes the sound and keeps the results.
enum IntroFingerprint {
    /// The sound as it is analysed: mono, 8 kHz (speech and music up to 4 kHz
    /// are plenty to tell a theme tune by).
    static let sampleRate = 8000
    /// One fingerprint value per 1/8 s…
    static let hop = 1000
    /// …each from about half a second of sound, so two episodes whose intros
    /// start a fraction of a frame apart still give the same values.
    static let window = 4096
    static var framesPerSecond: Double { Double(sampleRate) / Double(hop) }
    /// A value compares a frame with the one this many frames before it.
    static let lag = 2
    /// 17 bands from 150 Hz to 3.6 kHz, evenly spaced by pitch: 16 bits.
    static let bandEdges: [Int] = {
        let lo = 150.0, hi = 3600.0, n = 17
        return (0...n).map { i in
            let f = lo * pow(hi / lo, Double(i) / Double(n))
            return Int((f * Double(window) / Double(sampleRate)).rounded())
        }
    }()
    /// Quieter than this (about −60 dB) is silence. Silence has no shape to
    /// compare, and two silences must not count as the same sound: its value
    /// is 0, which the comparison treats as "nothing here".
    static let silenceMeanSquare: Float = 1e-6

    /// The fingerprint of 16-bit mono sound at `sampleRate`: one 16-bit value
    /// per `hop`. Each bit says whether the loudness step between two
    /// neighbouring bands grew or shrank since `lag` frames ago (Haitsma and
    /// Kalker's audio fingerprint, the idea behind Chromaprint too): it
    /// survives a different encode and a different volume. Ten minutes are
    /// 4,800 values, under 10 KB.
    static func compute(pcm: UnsafeBufferPointer<Int16>) -> [UInt16] {
        let n = pcm.count
        guard n >= window, let base = pcm.baseAddress else { return [] }
        let frames = (n - window) / hop + 1
        let log2n = vDSP_Length(12)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        let half = window / 2
        var hann = [Float](repeating: 0, count: window)
        vDSP_hann_window(&hann, vDSP_Length(window), Int32(vDSP_HANN_NORM))
        var frame = [Float](repeating: 0, count: window)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        let bands = bandEdges.count - 1
        // Band energies of the last `lag` + 1 frames; nil for a silent frame.
        var history = [[Float]?](repeating: nil, count: lag + 1)
        var out = [UInt16](repeating: 0, count: frames)
        var scale: Float = 1 / 32768
        for f in 0..<frames {
            vDSP_vflt16(base + f * hop, 1, &frame, 1, vDSP_Length(window))
            vDSP_vsmul(frame, 1, &scale, &frame, 1, vDSP_Length(window))
            var meanSquare: Float = 0
            vDSP_measqv(frame, 1, &meanSquare, vDSP_Length(window))
            var energies: [Float]?
            if meanSquare >= silenceMeanSquare {
                vDSP_vmul(frame, 1, hann, 1, &frame, 1, vDSP_Length(window))
                real.withUnsafeMutableBufferPointer { rp in
                    imag.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        frame.withUnsafeBufferPointer { fp in
                            fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
                    }
                }
                var e = [Float](repeating: 0, count: bands)
                power.withUnsafeBufferPointer { pp in
                    for b in 0..<bands {
                        let lo = bandEdges[b], hi = max(bandEdges[b + 1], lo + 1)
                        var sum: Float = 0
                        vDSP_sve(pp.baseAddress! + lo, 1, &sum, vDSP_Length(min(hi, half) - lo))
                        e[b] = sum
                    }
                }
                energies = e
            }
            history.removeFirst()
            history.append(energies)
            guard let now = history[lag], let before = history[0] else { continue }
            var bits: UInt16 = 0
            for b in 0..<(bands - 1) where (now[b] - now[b + 1]) - (before[b] - before[b + 1]) > 0 {
                bits |= 1 << UInt16(b)
            }
            out[f] = bits
        }
        return out
    }

    /// For tests: sound as numbers from −1 to 1.
    static func compute(samples: [Float]) -> [UInt16] {
        let pcm = samples.map { Int16(max(-1, min(1, $0)) * 32767) }
        return pcm.withUnsafeBufferPointer { compute(pcm: $0) }
    }

    /// When frame `i` is, in seconds: the middle of the sound it was made from.
    static func time(ofFrame i: Int) -> Double {
        (Double(i * hop) + Double(window) / 2 - Double(lag * hop) / 2) / Double(sampleRate)
    }
}

/// Where two episodes share their intro.
struct IntroMatch: Equatable {
    /// In the first episode, seconds.
    var startA: Double, endA: Double
    /// In the second.
    var startB: Double, endB: Double
    /// Share of fingerprint bits that differ inside it (0 = identical).
    var errorRate: Double
}

enum IntroMatcher {
    /// An intro is at least this long: shorter stretches two episodes share
    /// are a studio logo or a sting.
    static let minLength = 15.0
    /// And at most this long: more is two copies of one episode, or a recap
    /// both carry.
    static let maxLength = 150.0
    /// It starts in the first 8 minutes.
    static let latestStart = 480.0
    /// An episode's cold open can be this much longer than the other's.
    static let maxOffset = 90.0
    /// Bits that may differ where the sound is the same. Unrelated sound
    /// differs in half of them; the same intro in two encodes in about a tenth.
    static let maxErrorRate = 0.30

    /// The longest stretch the two fingerprints share, at any shift of one
    /// against the other up to `maxOffset`; nil unless it is an intro by the
    /// limits above.
    static func match(_ a: [UInt16], _ b: [UInt16]) -> IntroMatch? {
        let fps = IntroFingerprint.framesPerSecond
        let wide = Int(5 * fps)            // the stretch is found 5 s at a time…
        let fine = Int(fps)                // …and its ends to the second
        guard a.count >= wide, b.count >= wide else { return nil }
        let maxShift = Int(maxOffset * fps)
        let wideLimit = Int(maxErrorRate * 16 * Double(wide))
        let fineLimit = Int(maxErrorRate * 16 * Double(fine))
        var best: (start: Int, end: Int, shift: Int, errors: Int)?
        var err = [UInt8](repeating: 0, count: max(a.count, b.count))
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                err.withUnsafeMutableBufferPointer { ep in
                    for shift in -maxShift...maxShift {
                        // Frame i of a against frame i + shift of b.
                        let from = max(0, -shift), to = min(ap.count, bp.count - shift)
                        let n = to - from
                        guard n >= wide else { continue }
                        for k in 0..<n {
                            let x = ap[from + k], y = bp[from + k + shift]
                            // Silence (0) on either side is never "the same".
                            ep[k] = x == 0 || y == 0 ? 8 : UInt8((x ^ y).nonzeroBitCount)
                        }
                        var sum = 0
                        for k in 0..<wide { sum += Int(ep[k]) }
                        var runStart = -1
                        var k = 0
                        while true {
                            let ok = sum <= wideLimit
                            if ok, runStart < 0 { runStart = k }
                            let last = k + wide >= n
                            if runStart >= 0, !ok || last {
                                var s = runStart, e = (ok ? k : k - 1) + wide
                                func errors(_ lo: Int, _ hi: Int) -> Int { var t = 0; for q in lo..<hi { t += Int(ep[q]) }; return t }
                                while e - s > fine, errors(s, s + fine) > fineLimit { s += 1 }
                                while e - s > fine, errors(e - fine, e) > fineLimit { e -= 1 }
                                // A lone differing frame at an end isn't part of it.
                                while e - s > fine, ep[s] > 5 { s += 1 }
                                while e - s > fine, ep[e - 1] > 5 { e -= 1 }
                                if e - s > (best.map { $0.end - $0.start } ?? 0) {
                                    best = (from + s, from + e, shift, errors(s, e))
                                }
                                runStart = -1
                            }
                            if last { break }
                            sum += Int(ep[k + wide]) - Int(ep[k])
                            k += 1
                        }
                    }
                }
            }
        }
        guard let best else { return nil }
        let t = IntroFingerprint.time(ofFrame:)
        var m = IntroMatch(startA: t(best.start), endA: t(best.end - 1),
                           startB: t(best.start + best.shift), endB: t(best.end - 1 + best.shift),
                           errorRate: Double(best.errors) / Double((best.end - best.start) * 16))
        let length = m.endA - m.startA
        guard length >= minLength, length <= maxLength, m.startA < latestStart, m.startB < latestStart else { return nil }
        // A file shorter than what is analysed was read whole: what its
        // second half shares with the other is the ending, not the intro.
        let whole = Double(IntroAudio.analysed) - 10
        for (start, frames) in [(m.startA, a.count), (m.startB, b.count)] {
            let seconds = Double(frames) / fps
            if seconds < whole, start > seconds * 0.4 { return nil }
        }
        // An intro that opens the file starts at 0, not half a second in.
        if m.startA < 1.5 { m.startA = 0 }
        if m.startB < 1.5 { m.startB = 0 }
        return m
    }
}

enum IntroNeighbours {
    /// The episodes to compare `name` with, among the files of its folder:
    /// the next episode of the same show and season, then the one before
    /// (seasons often change their intro). Empty for a film, a special, or a
    /// show with one episode here.
    static func of(_ name: String, among names: [String]) -> [String] {
        let p = TitleParser.parse(name)
        guard let episode = p.episode, p.extra == nil else { return [] }
        let key = NextEpisodes.showKey(p.title)
        guard !key.isEmpty else { return [] }
        var next: (Int, String)?, previous: (Int, String)?
        for other in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
        where other != name && TitleParser.isMedia(other) {
            let q = TitleParser.parse(other)
            guard let e = q.episode, q.extra == nil, q.season == p.season, e != episode,
                  NextEpisodes.showKey(q.title) == key else { continue }
            if e > episode { if next == nil || e < next!.0 { next = (e, other) } }
            else if previous == nil || e > previous!.0 { previous = (e, other) }
        }
        return [next?.1, previous?.1].compactMap { $0 }
    }
}
