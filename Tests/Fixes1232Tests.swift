import XCTest
@testable import Folio

/// 1.23.2: the 6 Nov requests (autoplay into episodes in other folders, the
/// Up Next card around scenes and previews, intro pills you watch).
@MainActor
final class Fixes1232Tests: XCTestCase {

    // MARK: Next episodes in other folders (Real-Debrid: a folder per torrent)

    private let root = URL(string: "https://dav.real-debrid.com/torrents/")!

    private func file(_ folder: String, _ name: String) -> LibraryIndex.File {
        LibraryIndex.File(url: root.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(name), name: name, size: 1, added: nil)
    }

    private func single(_ name: String) -> LibraryIndex.File { file(name, name) }

    func testTheGentlemenGoesOnAcrossFolders() {
        let e1 = "The.Gentlemen.S02E01.The.Road.To.Kingdom.2160p.NF.WEB.DL.DDP5.1.Atmos.DV.HDR.H.265-FLUX.mkv"
        let files = [
            single(e1),
            single("The.Gentlemen.S02E02.Theres.A.Rat.In.The.Kitchen.2160p.NF.WEB.DL.DDP5.1.Atmos.DV.HDR.H.265-FLUX.mkv"),
            single("The.Gentlemen.S02E02.1080p.WEB.h264-ETHEL.mkv"),
            single("The.Gentlemen.S02E03.Do.You.Reject.Satan.2160p.NF.WEB.DL.DDP5.1.Atmos.DV.HDR.H.265-FLUX.mkv"),
            single("The.Gentlemen.S02E06.The.Bells.Of.San.Domenico.2160p.NF.WEB.DL.DDP5.1.Atmos.DV.HDR.H.265-FLUX.mkv"),
            file("The.Gentlemen.S02E03.2160p-FLUX", "Sample/the.gentlemen.s02e03.sample.mkv"),
            single("The.Gentlemen.2019.1080p.BluRay.x264-SPARKS.mkv"),             // the film
            single("Gentlemen.Broncos.S01E02.mkv"),                                  // another show
            single("The.Gentlemen.S01E08.2160p.NF.WEB-DL-FLUX.mkv"),                // before this one
        ]
        let next = NextEpisodes.after(e1, url: single(e1).url, in: files)
        XCTAssertEqual(next.map(\.name), [
            "The.Gentlemen.S02E02.Theres.A.Rat.In.The.Kitchen.2160p.NF.WEB.DL.DDP5.1.Atmos.DV.HDR.H.265-FLUX.mkv",   // same group, not ETHEL's
            "The.Gentlemen.S02E03.Do.You.Reject.Satan.2160p.NF.WEB.DL.DDP5.1.Atmos.DV.HDR.H.265-FLUX.mkv",
            "The.Gentlemen.S02E06.The.Bells.Of.San.Domenico.2160p.NF.WEB.DL.DDP5.1.Atmos.DV.HDR.H.265-FLUX.mkv",
        ])
    }

    func testTheNextSeasonFollows() {
        let last = "Show.S01E10.1080p.WEB-GRP.mkv"
        let files = [file("Show.S01.1080p.WEB-GRP", last), file("Show.S02.1080p.WEB-GRP", "Show.S02E01.1080p.WEB-GRP.mkv"),
                     file("Show.S02.1080p.WEB-GRP", "Show.S02E02.1080p.WEB-GRP.mkv")]
        XCTAssertEqual(NextEpisodes.after(last, url: files[0].url, in: files).map(\.name),
                       ["Show.S02E01.1080p.WEB-GRP.mkv", "Show.S02E02.1080p.WEB-GRP.mkv"])
    }

    func testEpisodesWithoutSeasonsStayApart() {
        let e4 = "[SubsPlease] Frieren - 04 (1080p) [ABCD1234].mkv"
        let files = [single(e4), single("[SubsPlease] Frieren - 05 (1080p) [EF012345].mkv"),
                     single("Frieren.S01E05.1080p.WEB-GRP.mkv"),                     // numbered by season: not mixed in
                     single("[SubsPlease] Frieren - OVA 06 (1080p) [12345678].mkv")] // an extra: not the show's episode 6
        XCTAssertEqual(NextEpisodes.after(e4, url: single(e4).url, in: files).map(\.name), ["[SubsPlease] Frieren - 05 (1080p) [EF012345].mkv"])
    }

    func testAFilmHasNoNextEpisode() {
        let film = "Conclave.2024.1080p.WEB-DL.mkv"
        XCTAssertTrue(NextEpisodes.after(film, url: single(film).url, in: [single(film), single("Conclave.S01E01.mkv")]).isEmpty)
    }

    func testReleaseGroups() {
        XCTAssertEqual(NextEpisodes.group("The.Gentlemen.S02E01.2160p.H.265-FLUX.mkv"), "flux")
        XCTAssertNil(NextEpisodes.group("[SubsPlease] Frieren - 04 (1080p) [ABCD1234].mkv"))
        XCTAssertEqual(NextEpisodes.showKey("The Gentlemen"), NextEpisodes.showKey("the.gentlemen"))
    }

    // MARK: The Up Next card

    private func seg(_ kind: SkipSegment.Kind, _ a: Double, _ b: Double, _ name: String? = nil) -> SkipSegment {
        SkipSegment(kind: kind, start: a, end: b, source: "Chapters", name: name)
    }

    func testTheCardNamesThePartItCovers() {
        // Classroom of the Elite S3E12 (5 Nov log): "Ending" 1330–1421 of 1440.
        let t = PlayerModel.upNextTrigger(segments: [seg(.outro, 1330, 1421, "Ending")], duration: 1440, postCredits: false, autoplay: true)
        XCTAssertEqual(t?.time, 1330)
        XCTAssertEqual(t?.stay, "Watch Ending")
        XCTAssertEqual(t?.autoplay, true)
    }

    func testNoCardBeforeAScene() {
        // S3E13: "Ending" 1054–1135, then the "Epilouge" chapter to 1421.
        XCTAssertNil(PlayerModel.upNextTrigger(segments: [seg(.outro, 1054, 1135, "Ending")], duration: 1421, postCredits: false, autoplay: true))
        // IntroDB says a scene follows the credits.
        XCTAssertNil(PlayerModel.upNextTrigger(segments: [seg(.outro, 3095, 3106, "Credits")], duration: 3110, postCredits: true, autoplay: true))
    }

    func testAPreviewAfterTheCreditsKeepsTheCard() {
        let credits = seg(.outro, 1345, 1435, "Ending"), preview = seg(.preview, 1435, 1442, "Preview")
        let t = PlayerModel.upNextTrigger(segments: [credits, preview], duration: 1500, postCredits: false, autoplay: true)
        XCTAssertEqual(t?.time, 1345)
        // A scene between the credits and the preview: the card at the preview.
        let late = seg(.preview, 1480, 1500, "Next Episode Preview")
        let u = PlayerModel.upNextTrigger(segments: [credits, late], duration: 1510, postCredits: false, autoplay: true)
        XCTAssertEqual(u?.time, 1480)
        XCTAssertEqual(u?.stay, "Watch Next Episode Preview")
    }

    func testNothingKnownMeansTheLast30Seconds() {
        let t = PlayerModel.upNextTrigger(segments: [], duration: 1400, postCredits: false, autoplay: true)
        XCTAssertEqual(t?.time, 1370)
        XCTAssertEqual(t?.stay, "Keep Watching")
    }

    // MARK: Intro pills you watch

    func testHiddenIntrosComeBack() {
        let store = ShowMemoryStore(url: nil)
        let key = ShowKey(keys: ["show:classroomoftheelite"], name: "Classroom of the Elite")
        store.update(key) { $0.settings.introHidden = ["intro"]; $0.settings.introWatched = ["intro": ["a", "b"]] }
        XCTAssertEqual(store.hiddenIntroShows.map(\.name), ["Classroom of the Elite"])
        store.showIntrosAgain(store.hiddenIntroShows[0].id)
        XCTAssertTrue(store.hiddenIntroShows.isEmpty)
        XCTAssertNil(store.entry(for: key.keys)?.settings.introWatched)
    }

    // MARK: What the logs say about opening and rendering

    func testTheOpenTimelineReadsMPVsLog() {
        let log = """
        [   0.022][v][stream_callback] Opening https://dav.real-debrid.com/torrents/x/y.mkv
        [   0.022][v][ffmpeg] Opening https://dav.real-debrid.com/torrents/x/y.mkv
        [   0.023][d][ffmpeg] tcp: Starting connection attempt to 81.85.62.11 port 443
        [   2.100][d][ffmpeg] tcp: Starting connection attempt to 203.0.113.9 port 443
        [   2.300][v][mkv] Seeking to 1157696902 to read header element 0x1254c367.
        [   2.310][d][ffmpeg] tcp: Starting connection attempt to 81.85.62.11 port 443
        [   2.320][v][mkv] Deferring reading cues.
        [   2.330][v][demux] Detected file format: Matroska
        [   2.331][v][cplayer] Opening done: https://dav.real-debrid.com/torrents/x/y.mkv
        [   2.500][v][cplayer] first video frame after restart shown
        """
        let s = OpenTimeline.summary(log) ?? ""
        XCTAssertTrue(s.hasPrefix("open timeline: 3 connection(s) (2 address(es))"), s)
        XCTAssertTrue(s.contains("connect 203.0.113.9 +2.08"), s)
        XCTAssertTrue(s.contains("first picture +2.48"), s)
        XCTAssertFalse(s.contains("torrents"), "no paths: \(s)")
    }

    func testRenderPassesInOneLine() {
        let json = #"{"fresh":[{"desc":"user shader: Anime4K-Restore-CNN-M","avg":3100000,"peak":4200000},{"desc":"scaling","avg":400000,"peak":600000}],"redraw":[]}"#
        let s = RenderPasses.summary(json) ?? ""
        XCTAssertTrue(s.hasPrefix("2 passes, 3.5 ms on average"), s)
        XCTAssertTrue(s.contains("Anime4K-Restore-CNN-M 3.10 ms"), s)
        XCTAssertEqual(RenderPasses.summary(#"{"fresh":[{"desc":"a","avg":0}]}"#), "1 passes (no GPU timings): a")
    }

    // MARK: Resume after a reinstall (library files' paths)

    private func libEntry(_ path: String, _ pos: Double, _ dur: Double, ago: Double) -> HistoryEntry {
        var m = MediaItem(url: path, title: "Lab Show S01E02", source: .local)
        m.historyKey = path
        return HistoryEntry(item: m, position: pos, duration: dur, updated: Date().addingTimeInterval(-ago))
    }

    func testLibraryFilesAreKnownByTheirPlaceInMedia() {
        XCTAssertEqual(HistoryStore.libraryRelative("/private/var/mobile/Containers/Data/Application/986B236C-AAAA/Documents/Media/show/E1.mkv"), "show/E1.mkv")
        XCTAssertEqual(HistoryStore.libraryRelative("/var/mobile/Containers/Data/Application/DFBF5E79-BBBB/Documents/Media/show/E1.mkv"), "show/E1.mkv")
        XCTAssertNil(HistoryStore.libraryRelative("https://dav.real-debrid.com/torrents/x/E1.mkv"))
        XCTAssertNil(HistoryStore.libraryRelative("/private/var/mobile/Library/Mobile Documents/E1.mkv"))
    }

    func testAReinstallKeepsThePlaceToResume() {
        // 5 Nov: E12 at 12:53 under the old install's folder; after 1.23.0 a
        // page played it from 0 and 7 s were saved under the new folder.
        let old = libEntry("/var/mobile/Containers/Data/Application/DFBF5E79-1111/Documents/Media/Lab Show S01E02.mp4", 773, 1440, ago: 3600)
        let falseStart = libEntry("/private/var/mobile/Containers/Data/Application/986B236C-2222/Documents/Media/Lab Show S01E02.mp4", 7, 1440, ago: 60)
        let other = libEntry("/var/mobile/Containers/Data/Application/DFBF5E79-1111/Documents/Media/Other/Lab Show S01E02.mp4", 300, 1440, ago: 30)
        let dir = "/var/mobile/Containers/Data/Application/986B236C-2222/Documents/Media"
        let r = HistoryStore.rebased([old, falseStart, other], mediaDir: dir)
        XCTAssertEqual(r.entries.count, 2, "the two entries for one file became one; the file in another folder stays its own")
        XCTAssertEqual(r.merged, 1)
        let e = r.entries.first { $0.item.url.hasSuffix("Media/Lab Show S01E02.mp4") }
        XCTAssertEqual(e?.position, 773, "the entry with a place to resume wins over a few seconds' false start")
        XCTAssertEqual(e?.item.url, dir + "/Lab Show S01E02.mp4")
        XCTAssertEqual(e?.id, dir + "/Lab Show S01E02.mp4", "its id moves too, so the player finds it")
        XCTAssertEqual(r.entries.first { $0.item.url.contains("/Other/") }?.position, 300)
    }

    func testANewerEntryThatSaysMoreWins() {
        let a = libEntry("/x/Documents/Media/E.mkv", 400, 1440, ago: 100)
        let b = libEntry("/y/Documents/Media/E.mkv", 900, 1440, ago: 10)
        XCTAssertTrue(HistoryStore.better(b, than: a))
        let finished = libEntry("/y/Documents/Media/E.mkv", 1440, 1440, ago: 5)
        XCTAssertTrue(HistoryStore.better(finished, than: a), "watched to the end since: start over next time")
    }

    // MARK: Subtitles that follow the zoom (1.23.4)

    func testFillOnOpenGLMovesSubtitlesUpIntoView() {
        // The 6 Nov recording: a 16:9 file on the 2868×1320 px landscape screen, OpenGL, Fill.
        let video = CGSize(width: 3840, height: 2160), view = CGSize(width: 956, height: 440)
        let ratio: CGFloat = 956 / (440 * 16 / 9)                        // Fill is 1.22× Fit
        let f = PlayerModel.subtitleFraming(gl: true, fill: true, fillRatio: ratio, pinch: 1, video: video, view: view)
        XCTAssertEqual(f.scale, ratio, accuracy: 0.001)
        XCTAssertEqual(f.visible, 1 / ratio, accuracy: 0.001, "82% of the frame's height is on screen")
        let p = PlayerModel.subtitlePlacement(userPos: 100, userScale: 1, framing: f, follow: true, gl: true)
        XCTAssertEqual(p.pos, 91, "up by the 9% Fill cuts off the bottom")
        XCTAssertEqual(p.scale, 1 / Double(ratio), accuracy: 0.001, "the same size on screen as in Fit")
        // Manual: left as set.
        let m = PlayerModel.subtitlePlacement(userPos: 100, userScale: 1, framing: f, follow: false, gl: true)
        XCTAssertEqual(m.pos, 100); XCTAssertEqual(m.scale, 1)
    }

    func testFitAndWidePicturesLeaveSubtitlesAlone() {
        let view = CGSize(width: 956, height: 440)
        let fit = PlayerModel.subtitleFraming(gl: true, fill: false, fillRatio: 1.22, pinch: 1, video: CGSize(width: 3840, height: 2160), view: view)
        XCTAssertEqual(PlayerModel.subtitlePlacement(userPos: 95, userScale: 1.2, framing: fit, follow: true, gl: true).pos, 95)
        // A 2.39:1 film fills by cropping its sides: nothing cut at the bottom, only the size kept.
        let wide = PlayerModel.subtitleFraming(gl: true, fill: true, fillRatio: 1.1, pinch: 1, video: CGSize(width: 3840, height: 1606), view: view)
        XCTAssertEqual(wide.visible, 1, accuracy: 0.001)
        XCTAssertEqual(PlayerModel.subtitlePlacement(userPos: 100, userScale: 1, framing: wide, follow: true, gl: true).pos, 100)
    }

    func testAPinchOnMetalKeepsSubtitlesInView() {
        let f = PlayerModel.subtitleFraming(gl: false, fill: false, fillRatio: 1.22, pinch: 1.2, video: CGSize(width: 1920, height: 1080), view: CGSize(width: 956, height: 440))
        XCTAssertEqual(f.visible, 1 / 1.2, accuracy: 0.001)
        XCTAssertEqual(PlayerModel.subtitlePlacement(userPos: 100, userScale: 1, framing: f, follow: true, gl: false).pos, 92)
        // OpenGL can't go below the frame's bottom (no black bars drawn in).
        XCTAssertEqual(PlayerModel.subtitlePlacement(userPos: 140, userScale: 1, framing: (1, 1), follow: true, gl: true).pos, 100)
    }

    func testOneUnreadableAddonDoesntLoseTheOthers() throws {
        let good = #"{"transportURL":"https://a.example/manifest.json","manifest":{"id":"a","name":"A","types":["movie"],"catalogs":[],"resources":["stream"]}}"#
        let bad = #"{"transportURL":"https://b.example/manifest.json"}"#         // no manifest: can't be read
        let data = Data("[\(good),\(bad)]".utf8)
        XCTAssertNil(try? JSONDecoder().decode([InstalledAddon].self, from: data), "read whole, one bad entry fails the list")
        let lossy = try XCTUnwrap(JSONDecoder().decodeLossy(InstalledAddon.self, from: data))
        XCTAssertEqual(lossy.map(\.manifest.name), ["A"])
    }

    func testOnlyAnAnimeIDMakesAnime() {
        XCTAssertFalse(AnimeHint(title: "MobLand", episode: 2).hasAnimeID)
        XCTAssertTrue(AnimeHint(title: "Frieren", episode: 4, malId: 52991).hasAnimeID)
    }
}
