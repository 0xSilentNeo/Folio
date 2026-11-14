import XCTest
@testable import Folio

/// 1.30.4: the player fixes from the 14 Nov report — Up Next's countdown on
/// its own clock, a scrub that began on the last file, the second skip
/// database's answer merged in, and a slow stream opened again.
@MainActor
final class Fixes1304PlayerTests: XCTestCase {

    // MARK: Up Next's countdown

    /// Counted in real time from the first look at which it runs.
    func testCountdownCountsRealTimeWhileRunning() {
        var c = UpNextCountdown(length: 10)
        c.tick(at: 100, counting: true)
        XCTAssertEqual(c.left, 10, "the first look only starts it")
        for i in 1...20 { c.tick(at: 100 + Double(i) * 0.25, counting: true) }
        XCTAssertEqual(c.left, 5, accuracy: 0.0001)
        XCTAssertFalse(c.finished)
        for i in 21...40 { c.tick(at: 100 + Double(i) * 0.25, counting: true) }
        XCTAssertTrue(c.finished)
        XCTAssertEqual(c.left, 0)
    }

    /// Paused, seeking, scrubbing or hidden: it stands still, and the first
    /// look after only starts it again (never less than the card's time).
    func testCountdownStandsStillWhileNotCounting() {
        var c = UpNextCountdown(length: 10)
        c.tick(at: 0, counting: true)
        c.tick(at: 2, counting: true)          // capped at one step
        XCTAssertEqual(c.left, 10 - UpNextCountdown.maxStep, accuracy: 0.0001)
        c.tick(at: 2.25, counting: false)
        c.tick(at: 60, counting: false)
        XCTAssertEqual(c.left, 10 - UpNextCountdown.maxStep, accuracy: 0.0001)
        c.tick(at: 60.25, counting: true)      // starts again, adds nothing
        XCTAssertEqual(c.left, 10 - UpNextCountdown.maxStep, accuracy: 0.0001)
        c.tick(at: 60.5, counting: true)
        XCTAssertEqual(c.left, 10 - UpNextCountdown.maxStep - 0.25, accuracy: 0.0001)
    }

    /// The 14 Nov case: the position jumping 10 s into the credits (a seek
    /// or a scrub) no longer ends it; only time does.
    func testCountdownIgnoresThePosition() {
        var c = UpNextCountdown(length: PlayerModel.upNextCountdown)
        c.tick(at: 0, counting: true)
        c.tick(at: 0.167, counting: true)
        XCTAssertFalse(c.finished, "167 ms after the card")
        XCTAssertGreaterThan(c.left, 9.8)
    }

    // MARK: A scrub that began on the last file

    func testScrubOnTheSameFileSeeks() {
        var s = ScrubSession()
        XCTAssertFalse(s.active)
        XCTAssertTrue(s.mayRelease(currentFile: 4), "no scrub: any seek goes")
        XCTAssertTrue(s.move(currentFile: 4))
        XCTAssertTrue(s.active)
        XCTAssertTrue(s.move(currentFile: 4))
        XCTAssertTrue(s.mayRelease(currentFile: 4))
        s.lift()
        XCTAssertFalse(s.active)
    }

    /// Up Next moved on under the finger: the rest of the scrub, and its
    /// release, are for the last file and are dropped until it lifts.
    func testScrubBegunOnTheLastFileIsDropped() {
        var s = ScrubSession()
        XCTAssertTrue(s.move(currentFile: 3))
        // load(): the next file is 4.
        XCTAssertFalse(s.move(currentFile: 4))
        XCTAssertFalse(s.move(currentFile: 4), "the scrub stays the last file's")
        XCTAssertFalse(s.mayRelease(currentFile: 4))
        s.lift()
        XCTAssertTrue(s.mayRelease(currentFile: 4))
        XCTAssertTrue(s.move(currentFile: 4), "a new scrub is the new file's")
    }

    // MARK: Moving on from the open file only

    /// The end of a file, or the countdown, moves on only from the file mpv
    /// has open as the queue's current one, with no other move under way.
    func testMoveOnOnlyFromTheOpenFile() {
        XCTAssertTrue(PlayerModel.mayMoveOn(fileLoaded: true, playingID: "e5", itemID: "e5", navigating: false))
        // load() has let go of it (the last file's end, still on its way).
        XCTAssertFalse(PlayerModel.mayMoveOn(fileLoaded: false, playingID: "e6", itemID: "e6", navigating: false))
        // The next episode's subtitles are fetched: queueIndex is on it, e5 still plays.
        XCTAssertFalse(PlayerModel.mayMoveOn(fileLoaded: true, playingID: "e5", itemID: "e6", navigating: true))
        // Its stream is looked up: queueIndex still e5, but a move is under way.
        XCTAssertFalse(PlayerModel.mayMoveOn(fileLoaded: true, playingID: "e5", itemID: "e5", navigating: true))
        XCTAssertFalse(PlayerModel.mayMoveOn(fileLoaded: true, playingID: nil, itemID: "e1", navigating: false))
    }

    // MARK: The second database merged in

    private func seg(_ kind: SkipSegment.Kind, _ start: Double, _ end: Double, _ source: String) -> SkipSegment {
        SkipSegment(kind: kind, start: start, end: end, source: source)
    }

    /// S01E07: TheIntroDB had only the credits; IntroDB's recap and intro come
    /// with it, its own credits winning.
    func testMergeAddsTheSlowerDatabasesKinds() {
        let theIntroDB = SkipLookup(segments: [seg(.outro, 2521, 2557, "TheIntroDB")])
        let introDB = SkipLookup(segments: [seg(.recap, 5, 65, "IntroDB"), seg(.intro, 300, 366, "IntroDB"), seg(.outro, 2519, 2552, "IntroDB")],
                                 postCredits: true)
        let m = SkipService.merge(preferred: introDB, other: theIntroDB)
        XCTAssertEqual(m.segments.map(\.kind), [.recap, .intro, .outro])
        XCTAssertEqual(m.segments.last?.source, "IntroDB")
        XCTAssertTrue(m.postCredits)
    }

    /// IntroDB didn't answer: TheIntroDB's answer as it is.
    func testMergeWithNothingPreferredKeepsTheOther() {
        let theIntroDB = SkipLookup(segments: [seg(.intro, 143, 208, "TheIntroDB"), seg(.outro, 2154, 2184, "TheIntroDB")])
        let m = SkipService.merge(preferred: SkipLookup(), other: theIntroDB)
        XCTAssertEqual(m.segments, theIntroDB.segments)
        XCTAssertFalse(m.postCredits)
    }

    /// S01E02: TheIntroDB's preview overlaps IntroDB's credits; the two
    /// disagree, and IntroDB's answer stands alone, as before.
    func testMergeLeavesOutAnOverlappingKind() {
        let theIntroDB = SkipLookup(segments: [seg(.recap, 0, 69, "TheIntroDB"), seg(.preview, 2174, 2205, "TheIntroDB"), seg(.outro, 2205, 2238, "TheIntroDB")])
        let introDB = SkipLookup(segments: [seg(.recap, 5, 65, "IntroDB"), seg(.intro, 176, 243, "IntroDB"), seg(.outro, 2190, 2223, "IntroDB")])
        let m = SkipService.merge(preferred: introDB, other: theIntroDB)
        XCTAssertEqual(m.segments, introDB.segments)
    }

    /// A preview after IntroDB's credits that only TheIntroDB knows is added.
    func testMergeAddsANonOverlappingPreview() {
        let theIntroDB = SkipLookup(segments: [seg(.preview, 2230, 2260, "TheIntroDB")])
        let introDB = SkipLookup(segments: [seg(.outro, 2190, 2223, "IntroDB")])
        let m = SkipService.merge(preferred: introDB, other: theIntroDB)
        XCTAssertEqual(m.segments.map(\.kind), [.outro, .preview])
    }

    // MARK: A slow connection

    private let mb = 1_048_576.0

    /// The 14 Nov case: a 3 MB/s remux read at 1.4–1.5 MB/s, a wait every few
    /// seconds: the third one opens it again.
    func testThreeWaitsOnASlowConnectionReconnect() {
        let need = StallRecovery.needRate(fileBytes: 7_230_399_712, duration: 2290, bitsPerSecond: 0)
        XCTAssertEqual(need / mb, 3.01, accuracy: 0.01)
        var waits = [StallRecovery.Wait(start: 0, end: 1.2, readRate: 1.5 * mb),
                     StallRecovery.Wait(start: 3.1, end: 6.2, readRate: 2.3 * mb)]
        XCTAssertNil(StallRecovery.reconnectReadRate(waits: waits, now: 6.5, needRate: need, lastReconnect: nil), "two waits aren't enough")
        waits.append(StallRecovery.Wait(start: 8.9, end: nil, readRate: 1.4 * mb))
        let rate = StallRecovery.reconnectReadRate(waits: waits, now: 9, needRate: need, lastReconnect: nil)
        XCTAssertNotNil(rate)
        XCTAssertEqual((rate ?? 0) / mb, 1.733, accuracy: 0.01)
    }

    /// Reading as fast as the file plays: waits are something else (a busy
    /// server for a moment), and nothing is reopened.
    func testWaitsWithAFastEnoughReadDoNotReconnect() {
        let waits = (0..<4).map { StallRecovery.Wait(start: Double($0) * 5, end: Double($0) * 5 + 2, readRate: 4 * mb) }
        XCTAssertNil(StallRecovery.reconnectReadRate(waits: waits, now: 20, needRate: 3 * mb, lastReconnect: nil))
    }

    /// One long wait counts once 15 s have gone; a rate is needed to judge.
    func testOneLongWait() {
        let w = [StallRecovery.Wait(start: 0, end: nil, readRate: 0.5 * mb)]
        XCTAssertNil(StallRecovery.reconnectReadRate(waits: w, now: 10, needRate: 3 * mb, lastReconnect: nil))
        XCTAssertNotNil(StallRecovery.reconnectReadRate(waits: w, now: 15.5, needRate: 3 * mb, lastReconnect: nil))
        let unknown = [StallRecovery.Wait(start: 0, end: nil, readRate: nil)]
        XCTAssertNil(StallRecovery.reconnectReadRate(waits: unknown, now: 20, needRate: 3 * mb, lastReconnect: nil))
    }

    /// Waits older than the window don't count; nor does a file whose need isn't known.
    func testOldWaitsAndAnUnknownNeed() {
        let old = [StallRecovery.Wait(start: 0, end: 2, readRate: mb), StallRecovery.Wait(start: 5, end: 7, readRate: mb),
                   StallRecovery.Wait(start: 50, end: 52, readRate: mb)]
        XCTAssertNil(StallRecovery.reconnectReadRate(waits: old, now: 52, needRate: 3 * mb, lastReconnect: nil))
        let recent = old.map { StallRecovery.Wait(start: $0.start + 45, end: $0.end.map { $0 + 45 }, readRate: $0.readRate) }
        XCTAssertNil(StallRecovery.reconnectReadRate(waits: recent, now: 97, needRate: 0, lastReconnect: nil))
        XCTAssertEqual(StallRecovery.needRate(fileBytes: 0, duration: 2000, bitsPerSecond: 24_000_000), 3_000_000)
        XCTAssertEqual(StallRecovery.needRate(fileBytes: 0, duration: 0, bitsPerSecond: 0), 0)
    }

    /// At most once in two minutes for a file.
    func testReconnectSpacing() {
        let waits = (0..<3).map { StallRecovery.Wait(start: 200 + Double($0) * 4, end: 202 + Double($0) * 4, readRate: mb) }
        XCTAssertNil(StallRecovery.reconnectReadRate(waits: waits, now: 210, needRate: 3 * mb, lastReconnect: 100))
        XCTAssertNotNil(StallRecovery.reconnectReadRate(waits: waits, now: 221, needRate: 3 * mb, lastReconnect: 100))
    }
}
