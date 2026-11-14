import XCTest
@testable import Folio

/// 1.30.3: a stream picked from an episode's own row queues the rest of
/// the season, as the title page's big button does.
final class Fixes1303PlaybackTests: XCTestCase {
    private func season(_ n: Int) -> [MetaVideo] {
        (1...n).map { MetaVideo(id: "tt1:2:\($0)", title: "Episode \($0)", season: 2, episode: $0) }
    }

    private func context(_ v: MetaVideo) -> PlayContext {
        PlayContext(name: "Show", poster: "p.jpg", type: "series", metaId: "tt1", isAnime: false,
                    videoId: v.id, videoLabel: v.label, episode: v.episode)
    }

    /// The tapped episode and every one after it, in order.
    func testSeasonVideosStartAtTheTappedEpisode() {
        let eps = season(6)
        let from3 = AddonPlayback.seasonVideos(from: eps[2], in: eps)
        XCTAssertEqual(from3.map(\.id), ["tt1:2:3", "tt1:2:4", "tt1:2:5", "tt1:2:6"])
        XCTAssertEqual(AddonPlayback.seasonVideos(from: eps[0], in: eps), eps)
        // What the big button gives for the same episode.
        XCTAssertEqual(from3, Array(eps[2...]))
    }

    /// Nothing after it (the last episode, a season of one, an episode not
    /// in the list): no season queue, the one episode plays.
    func testSeasonVideosAreEmptyWhenNothingFollows() {
        let eps = season(6)
        XCTAssertTrue(AddonPlayback.seasonVideos(from: eps[5], in: eps).isEmpty)
        XCTAssertTrue(AddonPlayback.seasonVideos(from: eps[0], in: [eps[0]]).isEmpty)
        XCTAssertTrue(AddonPlayback.seasonVideos(from: MetaVideo(id: "tt1:3:1", title: nil, season: 3, episode: 1), in: eps).isEmpty)
        XCTAssertTrue(AddonPlayback.seasonVideos(from: eps[0], in: []).isEmpty)
    }

    /// The row's copy of an episode may differ from the list's (its date);
    /// it is found by its id.
    func testSeasonVideosFindTheEpisodeByID() {
        let eps = season(4)
        var tapped = eps[1]
        tapped.released = "2026-11-13"
        XCTAssertEqual(AddonPlayback.seasonVideos(from: tapped, in: eps).map(\.id), ["tt1:2:2", "tt1:2:3", "tt1:2:4"])
    }

    /// The queue: the picked stream first, then each later episode without
    /// an address, carrying the pick with its own episode.
    func testSeasonQueueCarriesThePickWithEachEpisode() {
        let eps = AddonPlayback.seasonVideos(from: season(5)[1], in: season(5))
        let first = MediaItem(url: "https://a/e2.mkv", title: "Show", subtitle: eps[0].label, source: .addon(name: "Addon"))
        let pick = StreamPick(addonID: "https://a/manifest.json", bingeGroup: "g|1080p", streamName: "A 1080p", resolution: "1080p",
                              context: context(eps[0]), manifestID: "a.addon")
        let queue = AddonPlayback.seasonQueue(first: first, rest: eps.dropFirst().map(context), pick: pick)
        XCTAssertEqual(queue.count, 4)
        XCTAssertEqual(queue[0], first)
        for (item, v) in zip(queue.dropFirst(), eps.dropFirst()) {
            XCTAssertTrue(item.url.isEmpty, "found just before it plays")
            XCTAssertEqual(item.historyKey, "addon:\(v.id)")
            XCTAssertEqual(item.addonRef, "series|tt1|\(v.id)")
            XCTAssertEqual(item.streamPick?.context.videoId, v.id)
            XCTAssertEqual(item.streamPick?.context.episode, v.episode)
            XCTAssertEqual(item.streamPick?.bingeGroup, "g|1080p")
            XCTAssertEqual(item.streamPick?.addonID, pick.addonID)
            XCTAssertEqual(item.streamPick?.manifestID, "a.addon")
        }
        // A queue of one when nothing follows.
        XCTAssertEqual(AddonPlayback.seasonQueue(first: first, rest: [], pick: pick), [first])
    }

    /// Enter, < and > go to mpv when your input.conf binds them (1.30.3).
    @MainActor
    func testKeysYourInputConfBindsAreYours() {
        let conf = """
        # Key names: SPACE ENTER ESC
        enter   script-binding uosc/menu
          >  add speed 0.1
        	q quit
        """
        let bound = PlayerViewController.boundKeys(in: conf)
        XCTAssertTrue(bound.contains("ENTER"))
        XCTAssertTrue(bound.contains(">"))
        XCTAssertTrue(bound.contains("Q"))
        XCTAssertFalse(bound.contains("<"))
        XCTAssertFalse(bound.contains("SPACE"), "a comment binds nothing")
        XCTAssertTrue(PlayerViewController.boundKeys(in: "").isEmpty)
    }
}
