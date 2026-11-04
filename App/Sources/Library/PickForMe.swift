import Foundation

/// "Pick something for me" (1.22.0): an unwatched film from the library, at
/// random, with newer files and ones Folio has metadata for more likely.
///
/// A film's weight is (1 + 3·e^(−days since added / 45)) × (2 with
/// metadata, else 1): one added today is about 4 times as likely as one
/// from last year, and a film with a poster and a plot twice as likely as a
/// bare file name. Pick again never lands on the same film twice in a row
/// while there's another.
enum PickForMe {
    struct Candidate: Hashable {
        let file: URL
        let added: Date
        /// Folio found the film (a poster or a plot to show).
        let hasMeta: Bool
    }

    static func weight(_ c: Candidate, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(c.added) / 86400)
        return (1 + 3 * exp(-days / 45)) * (c.hasMeta ? 2 : 1)
    }

    static func pick<R: RandomNumberGenerator>(_ candidates: [Candidate], avoiding last: URL? = nil, now: Date = Date(), using rng: inout R) -> Candidate? {
        let pool = candidates.count > 1 ? candidates.filter { $0.file != last } : candidates
        guard !pool.isEmpty else { return nil }
        let weights = pool.map { weight($0, now: now) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return pool.randomElement(using: &rng) }
        var x = Double.random(in: 0..<total, using: &rng)
        for (c, w) in zip(pool, weights) {
            if x < w { return c }
            x -= w
        }
        return pool.last
    }

    static func pick(_ candidates: [Candidate], avoiding last: URL? = nil) -> Candidate? {
        var g = SystemRandomNumberGenerator()
        return pick(candidates, avoiding: last, using: &g)
    }
}
