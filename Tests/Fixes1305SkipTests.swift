import XCTest
@testable import Folio

/// 1.30.5: the skip pills sooner (16 Nov report) — the lookup starts with
/// load() and its answers wait for the file, the next episode's is asked in
/// prepare() and kept, what was asked before the file's length was known is
/// fitted to it, and a later answer leaves a pill on screen as it is.
@MainActor
final class Fixes1305SkipTests: XCTestCase {

    private func seg(_ kind: SkipSegment.Kind, _ start: Double, _ end: Double, _ source: String = "IntroDB", length: Double? = nil) -> SkipSegment {
        SkipSegment(kind: kind, start: start, end: end, source: source, length: length)
    }

    // MARK: The next episode's answer, kept

    /// Asked in prepare() minutes ahead, both databases answering: its load() takes it.
    func testCompletePrefetchedAnswerIsReused() {
        XCTAssertTrue(SkipService.reuse(complete: true, found: true, age: 0))
        XCTAssertTrue(SkipService.reuse(complete: true, found: true, age: 6 * 3600), "kept for the session")
    }

    /// One database didn't answer: asked again after a minute, so the
    /// episode opening minutes later asks both again.
    func testPartialPrefetchedAnswerIsAskedAgain() {
        XCTAssertTrue(SkipService.reuse(complete: false, found: true, age: 30))
        XCTAssertFalse(SkipService.reuse(complete: false, found: true, age: SkipService.partialTTL + 1))
        XCTAssertFalse(SkipService.reuse(complete: false, found: true, age: PlayerModel.prepareLead), "prepare() runs four minutes before the card")
    }

    /// Both answered with nothing: kept ten minutes, then asked again.
    func testCompleteEmptyAnswerIsKeptTenMinutes() {
        XCTAssertTrue(SkipService.reuse(complete: true, found: false, age: 300))
        XCTAssertFalse(SkipService.reuse(complete: true, found: false, age: SkipService.missTTL + 1))
    }

    // MARK: Answers wait for the file

    private func answer(_ segs: [SkipSegment], done: Bool) -> SkipAnswers.Answer {
        SkipAnswers.Answer(lookup: SkipLookup(segments: segs), anime: false, done: done)
    }

    /// A stream that takes 6.7 s to open: both answers are in before it
    /// has; the last one shows the moment it loads.
    func testAnswersBeforeTheFileShowAtItsLoad() {
        var s = SkipAnswers(token: 3)
        XCTAssertNil(s.add(answer([seg(.intro, 268, 333, "TheIntroDB")], done: false), from: 3), "the file isn't open yet")
        XCTAssertNil(s.add(answer([seg(.recap, 5, 65), seg(.intro, 277, 331)], done: true), from: 3))
        let shown = s.show()
        XCTAssertEqual(shown?.done, true)
        XCTAssertEqual(shown?.lookup.segments.map(\.kind), [.recap, .intro])
    }

    /// A file that opens before the second database answers: the first
    /// answer at its load, the merged one as it comes.
    func testAnswerAfterTheFileShowsAsItComes() {
        var s = SkipAnswers(token: 1)
        XCTAssertNil(s.add(answer([seg(.intro, 268, 333, "TheIntroDB")], done: false), from: 1))
        XCTAssertEqual(s.show()?.done, false)
        XCTAssertEqual(s.add(answer([seg(.intro, 277, 331)], done: true), from: 1)?.done, true)
    }

    /// Nothing in when the file loads: nothing to show then, the answer when it comes.
    func testNoAnswerYetAtLoad() {
        var s = SkipAnswers(token: 2)
        XCTAssertNil(s.show())
        XCTAssertNotNil(s.add(answer([seg(.outro, 2202, 2215)], done: true), from: 2))
    }

    /// An answer asked for the last file never shows on the next one.
    func testAnotherLoadsAnswerIsDropped() {
        var s = SkipAnswers(token: 5)
        XCTAssertNil(s.add(answer([seg(.intro, 60, 120)], done: true), from: 4))
        XCTAssertNil(s.show())
    }

    /// The file's chapters won: the lookup's answers never show.
    func testAnswersNeverShowWhenChaptersWon() {
        var s = SkipAnswers(token: 1)
        XCTAssertNil(s.add(answer([seg(.intro, 60, 120)], done: false), from: 1))
        XCTAssertNil(s.add(answer([seg(.intro, 60, 120)], done: true), from: 1))
        XCTAssertFalse(s.showing)
    }

    /// Nothing comes after the lookup's last answer.
    func testNothingAfterTheLastAnswer() {
        var s = SkipAnswers(token: 1)
        _ = s.show()
        XCTAssertNotNil(s.add(answer([seg(.intro, 277, 331)], done: true), from: 1))
        XCTAssertNil(s.add(answer([seg(.intro, 268, 333, "TheIntroDB")], done: false), from: 1))
        XCTAssertEqual(s.latest?.lookup.segments.first?.start, 277)
    }

    // MARK: Asked before the file's length was known

    /// An end left open is the file's end; what lies past its end goes.
    func testFitClosesOpenEndsAndDropsWhatIsPastTheEnd() {
        let out = SkipService.fit([seg(.recap, 5, 65), seg(.outro, 2202, SkipService.untilEnd, "TheIntroDB"), seg(.preview, 2300, 2330)], duration: 2215)
        XCTAssertEqual(out.map(\.kind), [.recap, .outro])
        XCTAssertEqual(out.last?.end, 2215)
        XCTAssertEqual(out.first, seg(.recap, 5, 65), "a closed segment inside the file is left as it is")
    }

    /// AniSkip's times measured on another length are rescaled to the file's;
    /// within 3 s they stand. Either way the length is let go.
    func testFitRescalesAniSkipTimes() {
        let out = SkipService.fit([seg(.intro, 100, 190, "AniSkip", length: 1440)], duration: 1420)
        XCTAssertEqual(out.first?.start ?? 0, 100 * 1420 / 1440, accuracy: 0.001)
        XCTAssertEqual(out.first?.end ?? 0, 190 * 1420 / 1440, accuracy: 0.001)
        XCTAssertNil(out.first?.length)
        let near = SkipService.fit([seg(.intro, 100, 190, "AniSkip", length: 1421)], duration: 1420)
        XCTAssertEqual(near, [seg(.intro, 100, 190, "AniSkip")])
    }

    /// No length yet: nothing is changed.
    func testFitWithoutALengthLeavesThemAlone() {
        let segs = [seg(.outro, 2202, SkipService.untilEnd), seg(.intro, 100, 190, "AniSkip", length: 1440)]
        XCTAssertEqual(SkipService.fit(segs, duration: 0), segs)
    }

    func testLogSaysEndForAnOpenEnd() {
        XCTAssertEqual(SkipService.span(seg(.outro, 2202, SkipService.untilEnd)), "outro 2202-end")
        XCTAssertEqual(SkipService.span(seg(.intro, 268, 333)), "intro 268-333")
    }

    // MARK: A later answer over a pill on screen

    /// TheIntroDB's recap shows at once; IntroDB's, merged in a second
    /// later, doesn't move the pill on screen (it went and came back at 5 s).
    func testPillOnScreenStaysWhenTheOtherAnswerComes() {
        let current = [seg(.recap, 0, 69, "TheIntroDB")]
        let next = [seg(.recap, 5, 65), seg(.intro, 277, 331)]
        let out = SkipService.keepShown(next, current: current, position: 1.3, handled: [])
        XCTAssertEqual(out, [seg(.recap, 0, 69, "TheIntroDB"), seg(.intro, 277, 331)])
    }

    /// A part already skipped keeps its id, so it isn't skipped again by
    /// the later answer's version of it.
    func testSkippedPartIsNotSkippedTwice() {
        let skipped = seg(.intro, 268, 333, "TheIntroDB")
        let out = SkipService.keepShown([seg(.intro, 277, 331)], current: [skipped], position: 333.2, handled: [skipped.id])
        XCTAssertEqual(out, [skipped])
        XCTAssertTrue(out.contains { $0.id == skipped.id })
    }

    /// A part still ahead takes the preferred database's answer.
    func testPartAheadTakesTheNewAnswer() {
        let next = [seg(.recap, 5, 65), seg(.intro, 277, 331)]
        XCTAssertEqual(SkipService.keepShown(next, current: [seg(.intro, 268, 333, "TheIntroDB")], position: 2, handled: []), next)
        XCTAssertEqual(SkipService.keepShown(next, current: [], position: 300, handled: []), next, "the first answer: nothing on screen yet")
    }

    /// Only the same kind over the same stretch gives way: an intro the
    /// later answer adds over the end of the recap on screen stays.
    func testOtherKindOverTheStretchStays() {
        let out = SkipService.keepShown([seg(.intro, 60, 120)], current: [seg(.recap, 0, 69, "TheIntroDB")], position: 10, handled: [])
        XCTAssertEqual(out.map(\.kind), [.recap, .intro])
    }

    // MARK: What is asked

    /// The address's file name when it is a media file's, else the item's title.
    func testQueryFileName() {
        let q = SkipQuery(name: "Tulsa.King.S02E04.1080p.WEB.h264.mkv", title: "Tulsa King", anime: nil, duration: 0, oatLength: 0)
        XCTAssertEqual(q.fileName, "Tulsa.King.S02E04.1080p.WEB.h264.mkv")
        XCTAssertEqual(q.parsed, TitleParser.parse(q.fileName))
        XCTAssertEqual(q.hint.episode, q.parsed.episode)
        XCTAssertEqual(q.hint.title, q.parsed.title)
        XCTAssertFalse(q.explicitAnime)
        XCTAssertFalse(q.fansubName)
        XCTAssertEqual(q.oatLength, 90, "the setting unset: 90 s")
        let stream = SkipQuery(name: "play", title: "Tulsa King S02E04", anime: nil, duration: 0, oatLength: 85)
        XCTAssertEqual(stream.fileName, "Tulsa King S02E04")
        XCTAssertEqual(stream.oatLength, 85)
    }

    /// An anime id or fansub naming marks it; the hint's own values stay.
    func testQueryAnimeSignals() {
        var hint = AnimeHint()
        hint.malId = 52991
        hint.episode = 5
        let q = SkipQuery(name: "[SubsPlease] Sousou no Frieren - 05 (1080p).mkv", title: "Frieren", anime: hint, duration: 1440, oatLength: 90)
        XCTAssertTrue(q.explicitAnime)
        XCTAssertTrue(q.fansubName)
        XCTAssertEqual(q.hint.episode, 5)
        XCTAssertEqual(q.hint.malId, 52991)
        XCTAssertEqual(q.duration, 1440)
    }
}
