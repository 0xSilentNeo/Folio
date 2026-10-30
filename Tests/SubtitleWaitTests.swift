import XCTest
@testable import GlassPlayer

/// A stream start waits for subtitle addons at most AddonPlayback.subtitleWait
/// (1.20.0; the 30 Oct log had 20.3 s waits, twice). Answers that come later
/// are handed to the player (lateSubtitlesArrived) and kept for it
/// (lateSubtitles(for:)). The limit here is shorter, to keep the test quick.
@MainActor
final class SubtitleWaitTests: XCTestCase {
    private func source(_ name: String, after ms: Int = 0, fails: Bool = false) -> AddonPlayback.SubtitleSource {
        AddonPlayback.SubtitleSource(name: name) {
            if ms > 0 { try await Task.sleep(for: .milliseconds(ms)) }
            if fails { throw URLError(.timedOut) }
            return [AddonSubtitle(id: nil, url: "https://subs.example/\(name).srt", lang: "eng")]
        }
    }

    private func videoID() -> String { "tt0000001:1:" + UUID().uuidString.prefix(8) }

    func testStartsWithoutASlowAddonThenHandsItsSubtitlesOver() async {
        let id = videoID()
        let late = expectation(forNotification: AddonPlayback.lateSubtitlesArrived, object: nil) { ($0.userInfo?["videoId"] as? String) == id }
        let t0 = Date()
        let first = await AddonPlayback.subtitles(videoId: id, from: [source("fast"), source("slow", after: 1500)], waitingAtMost: .milliseconds(400))
        let waited = Date().timeIntervalSince(t0)
        XCTAssertLessThan(waited, 1.2, "waited \(waited) s")
        XCTAssertEqual(first.map(\.url), ["https://subs.example/fast.srt"])
        XCTAssertTrue(AddonPlayback.lateSubtitles(for: id).isEmpty)
        await fulfillment(of: [late], timeout: 5)
        XCTAssertEqual(AddonPlayback.lateSubtitles(for: id).map(\.url), ["https://subs.example/slow.srt"])
    }

    func testAllOnTimeNoWaitingForTheLimit() async {
        let id = videoID()
        let t0 = Date()
        let subs = await AddonPlayback.subtitles(videoId: id, from: [source("a"), source("b", after: 100)], waitingAtMost: .seconds(3))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.5)
        XCTAssertEqual(Set(subs.map(\.url)), ["https://subs.example/a.srt", "https://subs.example/b.srt"])
        XCTAssertTrue(AddonPlayback.lateSubtitles(for: id).isEmpty)
    }

    func testAFailingAddonDoesntHoldTheStart() async {
        let id = videoID()
        let t0 = Date()
        let subs = await AddonPlayback.subtitles(videoId: id, from: [source("ok"), source("broken", fails: true)], waitingAtMost: .seconds(3))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.5)
        XCTAssertEqual(subs.map(\.url), ["https://subs.example/ok.srt"])
    }
}
