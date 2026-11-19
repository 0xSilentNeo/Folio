import XCTest
@testable import Folio

/// 0.90.0: the player fixes from the 18 Nov log — the opening card's time on
/// screen, a download host that fails, an end that isn't the file's end.
@MainActor
final class Fixes0900PlayerTests: XCTestCase {

    // MARK: The opening card

    /// A file on the phone waits half a second for its card; anything else
    /// shows it at once.
    func testOpeningCardShowsAtOnceForAStream() {
        XCTAssertEqual(OpeningCardTiming.showDelay(local: false), 0)
        XCTAssertEqual(OpeningCardTiming.showDelay(local: true), 0.5)
    }

    /// Once up it stays a second at least; no longer than that for a file
    /// that took its time, and not at all under the problem card.
    func testOpeningCardStaysASecond() {
        XCTAssertEqual(OpeningCardTiming.hideDelay(shownFor: 0, blocked: false), 1.0, accuracy: 0.001)
        XCTAssertEqual(OpeningCardTiming.hideDelay(shownFor: 0.3, blocked: false), 0.7, accuracy: 0.001)
        XCTAssertEqual(OpeningCardTiming.hideDelay(shownFor: 1.0, blocked: false), 0)
        XCTAssertEqual(OpeningCardTiming.hideDelay(shownFor: 34, blocked: false), 0)
        XCTAssertEqual(OpeningCardTiming.hideDelay(shownFor: 0.1, blocked: true), 0)
        // A clock that went back doesn't keep it longer than the second.
        XCTAssertEqual(OpeningCardTiming.hideDelay(shownFor: -5, blocked: false), 1.0, accuracy: 0.001)
    }

    /// The prepared next episode, the same file again and a server that
    /// sends its files itself get 0.3 s before any card; a card that only
    /// came up for the wait for the first picture goes with the picture.
    func testOpeningCardLeavesQuickOpensAlone() {
        XCTAssertEqual(OpeningCardTiming.showDelay(local: false, quick: true), 0.3)
        XCTAssertEqual(OpeningCardTiming.showDelay(local: true, quick: true), 0.5)
        XCTAssertEqual(OpeningCardTiming.hideDelay(shownFor: 0.1, blocked: false, upBeforeLoaded: false), 0)
        XCTAssertEqual(OpeningCardTiming.hideDelay(shownFor: 0.1, blocked: false, upBeforeLoaded: true), 0.9, accuracy: 0.001)
    }

    // MARK: A download host that fails

    /// 5xx or 429 from the host a link led on to: followed again after
    /// 0.3 s, 1 s and 2 s, then no more.
    func testLinkIsFollowedAgainThreeTimes() {
        XCTAssertEqual(LinkWarmer.retryWait(status: 503, redirected: true, tries: 0), 0.3)
        XCTAssertEqual(LinkWarmer.retryWait(status: 500, redirected: true, tries: 1), 1)
        XCTAssertEqual(LinkWarmer.retryWait(status: 502, redirected: true, tries: 2), 2)
        XCTAssertNil(LinkWarmer.retryWait(status: 503, redirected: true, tries: 3))
        XCTAssertNil(LinkWarmer.retryWait(status: 503, redirected: true, tries: -1))
    }

    /// A host asking for fewer requests (429) gets one more, not at once:
    /// after the time it names, 2 s at least and 5 s at most.
    func testTooManyRequestsIsAskedOnceMoreAndLater() {
        XCTAssertEqual(LinkWarmer.retryWait(status: 429, redirected: true, tries: 0), 2)
        XCTAssertEqual(LinkWarmer.retryWait(status: 429, redirected: true, tries: 0, retryAfter: 1), 2)
        XCTAssertEqual(LinkWarmer.retryWait(status: 429, redirected: true, tries: 0, retryAfter: 4), 4)
        XCTAssertEqual(LinkWarmer.retryWait(status: 429, redirected: true, tries: 0, retryAfter: 120), 5)
        XCTAssertNil(LinkWarmer.retryWait(status: 429, redirected: true, tries: 1))
        XCTAssertNil(LinkWarmer.retryWait(status: 429, redirected: false, tries: 0))
        XCTAssertEqual(LinkWarmer.retryAfter("3"), 3)
        XCTAssertEqual(LinkWarmer.retryAfter(" 10 "), 10)
        XCTAssertNil(LinkWarmer.retryAfter("Wed, 21 Oct 2026 07:28:00 GMT"))
        XCTAssertNil(LinkWarmer.retryAfter(nil))
    }

    /// mpv couldn't open a file behind a link: what the server says of it
    /// decides whether Folio opens it again by itself.
    func testFailedOpenIsTriedAgainOnlyForAHostThatFailed() {
        func wait(_ status: Int?, redirected: Bool = true, connection: Bool = false, tries: Int = 0, after: Double? = nil, online: Bool = true) -> Double? {
            SilentRetry.waitAfterFailedOpen(tries: tries, online: online, status: status, redirected: redirected,
                                            connectionFailed: connection, retryAfter: after)
        }
        // 18 Nov: the host that failed mpv was one of many; asked again, the file is sent.
        XCTAssertEqual(wait(206), 0.3)
        XCTAssertEqual(wait(206, tries: 1), 1)
        XCTAssertNil(wait(206, tries: 2))
        XCTAssertEqual(wait(503), 0.3)
        XCTAssertEqual(wait(nil, connection: true), 0.3)
        // A removed file, a refused login: never, however few tries.
        for gone in [401, 403, 404, 410] { XCTAssertNil(wait(gone), "\(gone)") }
        // The server itself failing, or anything else it says.
        XCTAssertNil(wait(503, redirected: false))
        XCTAssertNil(wait(400))
        XCTAssertNil(wait(nil, connection: false))
        XCTAssertNil(wait(503, online: false))
        // 429: once, and not quickly.
        XCTAssertEqual(wait(429), 2)
        XCTAssertEqual(wait(429, after: 3), 3)
        XCTAssertEqual(wait(429, after: 600), 5)
        XCTAssertNil(wait(429, tries: 1))
        XCTAssertTrue(SilentRetry.connectionFailures.contains(.timedOut))
        XCTAssertFalse(SilentRetry.connectionFailures.contains(.notConnectedToInternet))
    }

    /// Not the server itself failing, a file that's gone, a refused login,
    /// no answer at all, or an answer that's fine.
    func testLinkIsNotFollowedAgainForOtherAnswers() {
        XCTAssertNil(LinkWarmer.retryWait(status: 503, redirected: false, tries: 0))
        XCTAssertNil(LinkWarmer.retryWait(status: 404, redirected: true, tries: 0))
        XCTAssertNil(LinkWarmer.retryWait(status: 401, redirected: true, tries: 0))
        XCTAssertNil(LinkWarmer.retryWait(status: nil, redirected: true, tries: 0))
        XCTAssertNil(LinkWarmer.retryWait(status: 206, redirected: true, tries: 0))
    }

    /// The player's own tries: twice for an address a link led to, online.
    func testSilentRetryTwiceForAFollowedLink() {
        XCTAssertEqual(SilentRetry.wait(tries: 0, followsLink: true, online: true), 0.3)
        XCTAssertEqual(SilentRetry.wait(tries: 1, followsLink: true, online: true), 1)
        XCTAssertNil(SilentRetry.wait(tries: 2, followsLink: true, online: true))
        XCTAssertNil(SilentRetry.wait(tries: 0, followsLink: false, online: true), "a NAS or a file on the phone has no other host to go to")
        XCTAssertNil(SilentRetry.wait(tries: 0, followsLink: true, online: false))
    }

    /// A 5xx from a host the server sent Folio on to isn't the server
    /// "having trouble … in a few minutes"; from the server itself it is.
    func testProblemWordsForADownloadHost() {
        let host = ServerProblem.classify(status: 503, error: nil, server: "Real-Debrid", realDebrid: true, afterRedirect: true)
        XCTAssertEqual(host.kind, .serverError(503))
        XCTAssertTrue(host.retryable)
        XCTAssertFalse(host.detail.contains("few minutes"))
        XCTAssertTrue(host.detail.contains("Trying again usually works"))
        XCTAssertTrue(host.title.contains("download hosts"))
        let own = ServerProblem.classify(status: 503, error: nil, server: "Real-Debrid", realDebrid: true)
        XCTAssertTrue(own.detail.contains("few minutes"))
        XCTAssertEqual(own.title, "Real-Debrid is having trouble")
        // A removed file reads the same wherever the answer came from.
        XCTAssertEqual(ServerProblem.classify(status: 404, error: nil, server: "Real-Debrid", realDebrid: true, afterRedirect: true).kind, .gone)
    }

    // MARK: An end that isn't the end

    private let length = 30.0 * 60

    /// The 18 Nov log: opened again at 29:10 of a half-hour episode, 30 ms
    /// played, then the end, with mpv's position on the last frame.
    func testEndJustAfterOpeningIsNotTheEnd() {
        var p = PlayedPlace()
        p.asked(1750, now: 0)
        p.landed()
        p.moved(from: 0, to: 1750, now: 10)             // the first position: a jump, the place asked for
        p.moved(from: 1750, to: 1750.03, now: 10.03)
        p.moved(from: 1750.03, to: length, now: 10.1)   // mpv's own seek to the last frame
        XCTAssertEqual(p.reached ?? 0, 1750.03, accuracy: 0.001)
        XCTAssertEqual(p.parked, length)
        XCTAssertTrue(PlayedPlace.stoppedEarly(duration: length, reached: p.reached ?? 0, playedSince: p.playedSince, parked: p.parked))
        // The same with no frame played at all, mpv left at the place asked for.
        var q = PlayedPlace()
        q.asked(1750, now: 0)
        q.moved(from: 0, to: 1750, now: 10)
        XCTAssertEqual(q.reached, 1750)
        XCTAssertTrue(PlayedPlace.stoppedEarly(duration: length, reached: q.reached ?? 0, playedSince: q.playedSince, parked: q.parked))
        // History keeps it under its "finished" line: 29:10 of 30:00 is past
        // 92%, and saved as it is the episode would read as watched.
        let saved = PlayedPlace.savedPlace(stopped: 1750.03, duration: length)
        XCTAssertFalse(HistoryEntry(item: MediaItem(url: "http://x/a.mkv", title: "a", source: .url), position: saved, duration: length, updated: Date()).isFinished)
        XCTAssertTrue(HistoryEntry(item: MediaItem(url: "http://x/a.mkv", title: "a", source: .url), position: saved, duration: length, updated: Date()).canResume)
    }

    /// A stop saved for history: as it is before the finished line, just
    /// under the line past it, for short and long files.
    func testSavedPlaceStaysResumable() {
        XCTAssertEqual(PlayedPlace.savedPlace(stopped: 600, duration: length), 600)
        for (stopped, duration) in [(1795.0, 1800.0), (1700.0, 1800.0), (290.0, 300.0), (5390.0, 5400.0), (0.0, 1800.0)] {
            let saved = PlayedPlace.savedPlace(stopped: stopped, duration: duration)
            XCTAssertLessThanOrEqual(saved, stopped)
            XCTAssertGreaterThanOrEqual(saved, 0)
            let e = HistoryEntry(item: MediaItem(url: "http://x/a.mkv", title: "a", source: .url), position: saved, duration: duration, updated: Date())
            XCTAssertFalse(e.isFinished, "\(stopped) of \(duration) saved at \(saved) reads as finished")
        }
        XCTAssertEqual(PlayedPlace.savedPlace(stopped: 40, duration: 0), 40)
    }

    /// A skip or scrub to past the last frame of a file whose stated length
    /// is too long: mpv answers with its last frame, behind the place asked
    /// for, and that is the end. A stream that drops leaves mpv at the
    /// place or at the stated end, and isn't.
    func testAskedPastTheLastFrameIsTheEnd() {
        // 30:00 stated, the last frame at 29:20; +10 s asked from 29:15.
        var p = PlayedPlace()
        p.asked(0, now: 0); p.landed()
        p.moved(from: 1754.5, to: 1755, now: 100)
        p.asked(1765, now: 101)
        p.moved(from: 1755, to: 1760, now: 101.2)       // mpv's last frame
        XCTAssertEqual(p.parked, 1760)
        XCTAssertFalse(PlayedPlace.stoppedEarly(duration: length, reached: p.reached ?? 0, playedSince: p.playedSince, parked: p.parked))
        // The same ask, the stream dropping there: mpv at the place, or at the stated end.
        XCTAssertTrue(PlayedPlace.stoppedEarly(duration: length, reached: 1765, playedSince: 0, parked: 1765))
        XCTAssertTrue(PlayedPlace.stoppedEarly(duration: length, reached: 1765, playedSince: 0, parked: length))
        XCTAssertTrue(PlayedPlace.stoppedEarly(duration: length, reached: 1765, playedSince: 0, parked: nil))
        // Playing on from where it landed forgets where mpv had jumped to.
        p.landed()
        p.moved(from: 1760, to: 1760.5, now: 102)
        XCTAssertNil(p.parked)
        // Far from the end, mpv behind the place asked for doesn't make it the end.
        XCTAssertTrue(PlayedPlace.stoppedEarly(duration: length, reached: 900, playedSince: 0, parked: 600))
    }

    /// A file played through to its end is at its end.
    func testPlayedThroughIsTheEnd() {
        var p = PlayedPlace()
        p.asked(0, now: 0)
        p.landed()
        var t = 0.0
        while t < length - 0.5 { p.moved(from: t, to: t + 0.25, now: 5 + t); t += 0.25 }
        XCTAssertFalse(PlayedPlace.stoppedEarly(duration: length, reached: p.reached ?? 0, playedSince: p.playedSince))
        XCTAssertGreaterThan(p.playedSince, length - 2)
    }

    /// A stream that drops in the middle, however long it had played, and
    /// wherever mpv's position sits afterwards.
    func testDropMidwayIsNotTheEnd() {
        var p = PlayedPlace()
        p.asked(0, now: 0)
        p.landed()
        var t = 0.0
        while t < 600 { p.moved(from: t, to: t + 0.5, now: 5 + t); t += 0.5 }
        p.moved(from: 600, to: length, now: 700)
        XCTAssertEqual(p.reached ?? 0, 600, accuracy: 0.001)
        XCTAssertTrue(PlayedPlace.stoppedEarly(duration: length, reached: p.reached ?? 0, playedSince: p.playedSince))
    }

    /// A scrub or a skip to the very end is an end you asked for; a seek to
    /// 50 s before it that ends at once is not.
    func testSeekToTheEndIsTheEnd() {
        var p = PlayedPlace()
        p.asked(0, now: 0); p.landed()
        p.moved(from: 0, to: 0.5, now: 1)
        p.asked(length - 2, now: 2)
        XCTAssertFalse(PlayedPlace.stoppedEarly(duration: length, reached: p.reached ?? 0, playedSince: p.playedSince))
        p.asked(length - 50, now: 3)
        XCTAssertTrue(PlayedPlace.stoppedEarly(duration: length, reached: p.reached ?? 0, playedSince: p.playedSince))
        // Played on from there to the end: the end.
        p.landed()
        var t = length - 50
        while t < length - 1 { p.moved(from: t, to: t + 0.5, now: 4 + t); t += 0.5 }
        XCTAssertFalse(PlayedPlace.stoppedEarly(duration: length, reached: p.reached ?? 0, playedSince: p.playedSince))
    }

    /// Credits skipped to 25 s before the end, which then play out: the end,
    /// though the length says a few seconds more than the last frame.
    func testLengthALittleLongerThanTheLastFrame() {
        var p = PlayedPlace()
        p.asked(length - 25, now: 0); p.landed()
        var t = length - 25
        while t < length - 12 { p.moved(from: t, to: t + 0.5, now: 1 + t); t += 0.5 }
        XCTAssertFalse(PlayedPlace.stoppedEarly(duration: length, reached: p.reached ?? 0, playedSince: p.playedSince))
    }

    /// Positions still coming from the old place just after a seek is asked
    /// don't move the place asked for; a seek mpv never answers doesn't
    /// stop the counting for good.
    func testPositionsFromBeforeASeekDoNotCount() {
        var p = PlayedPlace()
        p.asked(100, now: 0); p.landed()
        p.moved(from: 100, to: 100.5, now: 1)
        p.asked(1700, now: 2)
        p.moved(from: 100.5, to: 100.54, now: 2.04)     // the old place, the seek not begun
        XCTAssertEqual(p.reached, 1700)
        XCTAssertEqual(p.playedSince, 0)
        p.moved(from: 100.54, to: 101, now: 3.5)        // still there a second on: it plays there
        XCTAssertEqual(p.reached, 101)
        XCTAssertFalse(p.landing)
    }

    /// mpv's own keys and console commands seek without saying where to: a
    /// jump within 2 s of one is taken as asked for.
    func testAJumpAfterAKeyIsAskedFor() {
        var p = PlayedPlace()
        p.asked(0, now: 0); p.landed()
        p.moved(from: 0, to: 0.5, now: 1)
        p.mayJump(now: 10)
        p.moved(from: 0.5, to: length - 1, now: 10.3)
        XCTAssertEqual(p.reached, length - 1)
        XCTAssertFalse(PlayedPlace.stoppedEarly(duration: length, reached: p.reached ?? 0, playedSince: p.playedSince))
        // Without one, a jump is mpv's own.
        var q = PlayedPlace()
        q.asked(0, now: 0); q.landed()
        q.moved(from: 0, to: 0.5, now: 1)
        q.moved(from: 0.5, to: length - 1, now: 10.3)
        XCTAssertEqual(q.reached, 0.5)
    }

    /// Short clips have no "early" (as before): their end is their end.
    func testShortFilesAlwaysEnd() {
        XCTAssertFalse(PlayedPlace.stoppedEarly(duration: 90, reached: 10, playedSince: 0))
    }

    // MARK: The log

    /// mpv's counts start again with the video output: never a negative
    /// number of dropped frames.
    func testDroppedFramesNeverNegative() {
        XCTAssertEqual(PlayerModel.countSince(now: 40, last: nil), 40)
        XCTAssertEqual(PlayerModel.countSince(now: 55, last: 40), 15)
        XCTAssertEqual(PlayerModel.countSince(now: 3, last: 215), 3)
        XCTAssertEqual(PlayerModel.countSince(now: 0, last: 215), 0)
    }

    /// What mpv's reader holds, from its cache state.
    func testCacheBytesRead() {
        let state = #"{"cache-end":1310.5,"reader-pts":1250.1,"cache-duration":60.4,"eof":false,"underrun":false,"idle":true,"total-bytes":412345678,"fw-bytes":62000000,"raw-input-rate":4000000}"#
        let held = PlayerModel.cacheBytes(state)
        XCTAssertEqual(held?.total, 412_345_678)
        XCTAssertEqual(held?.ahead, 62_000_000)
        XCTAssertNil(PlayerModel.cacheBytes(""))
    }
}
