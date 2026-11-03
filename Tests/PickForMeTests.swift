import XCTest
@testable import Folio

/// "Pick something for me" (1.22.0): newer films and ones with metadata are
/// more likely, Pick again never repeats the film just shown.
final class PickForMeTests: XCTestCase {
    /// A seeded generator (SplitMix64), so the draws are the same every run.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func film(_ name: String, daysAgo: Double, meta: Bool) -> PickForMe.Candidate {
        PickForMe.Candidate(file: URL(fileURLWithPath: "/unit/Documents/Media/\(name).mp4"), added: now.addingTimeInterval(-daysAgo * 86400), hasMeta: meta)
    }

    func testWeights() {
        let today = PickForMe.weight(film("a", daysAgo: 0, meta: false), now: now)
        let lastYear = PickForMe.weight(film("b", daysAgo: 365, meta: false), now: now)
        XCTAssertEqual(today, 4, accuracy: 0.001, "added today: 1 + 3")
        XCTAssertEqual(lastYear, 1, accuracy: 0.01, "a year old: about 1")
        XCTAssertEqual(PickForMe.weight(film("c", daysAgo: 0, meta: true), now: now), 8, accuracy: 0.001, "metadata doubles it")
        XCTAssertGreaterThan(PickForMe.weight(film("d", daysAgo: 10, meta: false), now: now), PickForMe.weight(film("e", daysAgo: 60, meta: false), now: now))
        XCTAssertEqual(PickForMe.weight(film("f", daysAgo: -5, meta: false), now: now), 4, accuracy: 0.001, "a date in the future counts as today")
    }

    func testDrawsFollowTheWeights() {
        let new = film("new", daysAgo: 0, meta: true)          // 8
        let old = film("old", daysAgo: 400, meta: false)       // ~1
        var rng = Seeded(state: 42)
        var counts: [URL: Int] = [:]
        for _ in 0..<9000 { counts[PickForMe.pick([new, old], now: now, using: &rng)!.file, default: 0] += 1 }
        let share = Double(counts[new.file, default: 0]) / 9000
        XCTAssertEqual(share, 8.0 / 9.0, accuracy: 0.02, "the new film with metadata about 8 times in 9")
        XCTAssertGreaterThan(counts[old.file, default: 0], 0, "the old film still comes up")
    }

    func testPickAgainNeverRepeats() {
        let a = film("a", daysAgo: 0, meta: true), b = film("b", daysAgo: 900, meta: false)
        var rng = Seeded(state: 7)
        for _ in 0..<200 { XCTAssertEqual(PickForMe.pick([a, b], avoiding: a.file, now: now, using: &rng), b) }
    }

    func testOneOrNone() {
        let a = film("a", daysAgo: 3, meta: false)
        var rng = Seeded(state: 1)
        XCTAssertEqual(PickForMe.pick([a], avoiding: a.file, now: now, using: &rng), a, "the only film comes up again")
        XCTAssertNil(PickForMe.pick([], now: now, using: &rng), "no unwatched film: nothing")
    }
}
