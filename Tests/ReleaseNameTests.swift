import XCTest
@testable import GlassPlayer

/// ReleaseName: the WebDAV browser script's clean-title rules
/// (webdav-browser-posters.lua, CT.parse / CT.parse_folder) in Swift. File
/// names are real ones from your library (device logs of 25–29 Oct); the
/// folder names are the script's own examples and an addon torrent title
/// from the same logs.
final class ReleaseNameTests: XCTestCase {
    private func attrs(_ r: ReleaseName?) -> [String] { r?.attributes.map(\.text) ?? [] }

    // MARK: Files from your library

    func testMobLandRemux() throws {
        let r = try XCTUnwrap(ReleaseName.file("MobLand.S01E01.Stick.or.Twist.1080p.Blu-ray.Remux.AVC.TrueHD.5.1-SiCFoI.mkv"))
        XCTAssertEqual(r.title, "MobLand")
        XCTAssertEqual(r.label, "S01E01")
        XCTAssertEqual(r.episodeTitle, "Stick or Twist")
        XCTAssertEqual(r.group, "SiCFoI")
        XCTAssertNil(r.year)
        XCTAssertEqual(attrs(r), ["1080p", "Remux", "AVC", "TrueHD", "5.1"])
    }

    func testClassroomLongEpisodeTitle() throws {
        let r = try XCTUnwrap(ReleaseName.file("Classroom.of.the.Elite.S01E02.It.takes.a.great.talent.and.skill.to.conceal.one's.talent.and.skill.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR.mkv"))
        XCTAssertEqual(r.title, "Classroom of the Elite")
        XCTAssertEqual(r.label, "S01E02")
        XCTAssertEqual(r.episodeTitle, "It takes a great talent and skill to conceal one's talent and skill")
        XCTAssertEqual(r.group, "FraMeSToR")
        XCTAssertEqual(attrs(r), ["1080p", "Remux", "AVC", "FLAC", "2.0"])
    }

    func testDaemonsYearBeforeEpisode() throws {
        let r = try XCTUnwrap(ReleaseName.file("Daemons.of.the.Shadow.Realm.2026.S01E01.1080p.CR.WEB.DL.DUAL.DDP2.0.H.264-AnoZu.mkv"))
        XCTAssertEqual(r.title, "Daemons of the Shadow Realm", "the year is the year, not part of the title (differs from the script)")
        XCTAssertEqual(r.year, "2026")
        XCTAssertEqual(r.label, "S01E01")
        XCTAssertNil(r.episodeTitle)
        XCTAssertEqual(r.group, "AnoZu")
        XCTAssertEqual(attrs(r), ["1080p", "WEB-DL", "AVC", "DD+", "2.0", "CR", "Dual Audio"])
    }

    func testDragonBallRepack() throws {
        let r = try XCTUnwrap(ReleaseName.file("Dragon.Ball.Super.Beerus.S01E02.REPACK.1080p.CR.WEB-DL.JPN.AAC2.0.H.264.MSubs-ToonsHub.mkv"))
        XCTAssertEqual(r.title, "Dragon Ball Super Beerus")
        XCTAssertEqual(r.label, "S01E02")
        XCTAssertNil(r.episodeTitle, "REPACK ends the episode title")
        XCTAssertEqual(r.group, "ToonsHub")
        XCTAssertEqual(attrs(r), ["1080p", "WEB-DL", "AVC", "AAC", "2.0", "CR", "REPACK"])
    }

    func testGentlemenDolbyVision() throws {
        let r = try XCTUnwrap(ReleaseName.file("The.Gentlemen.S02E01.The.Road.To.Kingdom.2160p.NF.WEB.DL.DDP5.1.Atmos.DV.HDR.H.265-FLUX.mkv"))
        XCTAssertEqual(r.title, "The Gentlemen")
        XCTAssertEqual(r.label, "S02E01")
        XCTAssertEqual(r.episodeTitle, "The Road To Kingdom")
        XCTAssertEqual(r.group, "FLUX")
        XCTAssertEqual(attrs(r), ["4K", "WEB-DL", "HDR", "DV", "HEVC", "DD+ Atmos", "5.1", "NF"])
    }

    func testMovieRemux() throws {
        let r = try XCTUnwrap(ReleaseName.file("Obsession.2025.2160p.UHD.Blu-ray.Remux.DV.HDR.HEVC.TrueHD.Atmos.7.1-CiNEPHiLES.mkv"))
        XCTAssertEqual(r.title, "Obsession")
        XCTAssertEqual(r.year, "2025")
        XCTAssertNil(r.label)
        XCTAssertEqual(r.group, "CiNEPHiLES")
        XCTAssertEqual(attrs(r), ["4K", "Remux", "HDR", "DV", "HEVC", "TrueHD Atmos", "7.1"])
        XCTAssertEqual(r.titleWithYear, "Obsession (2025)")
    }

    // MARK: Anime and numbering (the script's own cases)

    func testAnimeDashEpisode() throws {
        let r = try XCTUnwrap(ReleaseName.file("[SubsPlease] Sousou no Frieren - 01 (1080p) [ABCD1234].mkv"))
        XCTAssertEqual(r.title, "Sousou no Frieren")
        XCTAssertEqual(r.label, "E01")
        XCTAssertEqual(r.group, "SubsPlease")
        XCTAssertNil(r.episodeTitle)
        XCTAssertEqual(attrs(r), ["1080p"])
    }

    func testAbsoluteNumberAfterYear() throws {
        let r = try XCTUnwrap(ReleaseName.file("Show.2009.004.1080p.BD.mkv"))
        XCTAssertEqual(r.title, "Show")
        XCTAssertEqual(r.year, "2009")
        XCTAssertEqual(r.label, "E04")
    }

    func testNumberInTitleStays() throws {
        let r = try XCTUnwrap(ReleaseName.file("The.300.Spartans.1962.1080p.BluRay.x264.mkv"))
        XCTAssertEqual(r.title, "The 300 Spartans")
        XCTAssertEqual(r.year, "1962")
        XCTAssertNil(r.label)
    }

    func testNothingToRead() {
        XCTAssertNil(ReleaseName.file("notes.txt"))
        XCTAssertNil(ReleaseName.file("Holiday video.mp4"))
    }

    // MARK: Folders

    func testSeasonPackFolder() throws {
        let r = try XCTUnwrap(ReleaseName.folder("MASHLE.MAGIC.AND.MUSCLES.S01.1080p.BluRay.REMUX.AVC.FLAC.2.0-NAN0"))
        XCTAssertEqual(r.title, "Mashle Magic and Muscles", "all upper case is re-cased, small words stay lower")
        XCTAssertEqual(r.label, "S01")
        XCTAssertEqual(r.group, "NAN0")
        XCTAssertEqual(attrs(r), ["1080p", "Remux", "AVC", "FLAC", "2.0"])
    }

    func testAddonTorrentFolder() throws {
        let r = try XCTUnwrap(ReleaseName.folder("[AnoZu] Daemons of the Shadow Realm S01 1080p CR WEB.DL Dual-Audio DDP 2.0 H.264 Yomi no Tsugai {imdb-tt37532356}"))
        XCTAssertEqual(r.title, "Daemons of the Shadow Realm")
        XCTAssertEqual(r.label, "S01")
        XCTAssertEqual(r.group, "AnoZu")
        XCTAssertEqual(attrs(r), ["1080p", "WEB-DL", "AVC", "DD+", "2.0", "CR", "Dual Audio"])
    }

    func testMovieFolder() throws {
        let r = try XCTUnwrap(ReleaseName.folder("The.Movie.2023.2160p.UHD.BluRay.REMUX.DV.HDR.HEVC.TrueHD.7.1.Atmos-GROUP"))
        XCTAssertEqual(r.title, "The Movie")
        XCTAssertEqual(r.year, "2023")
        XCTAssertNil(r.label)
        XCTAssertEqual(r.group, "GROUP")
    }

    func testSeasonRangeAndComplete() throws {
        XCTAssertEqual(ReleaseName.folder("Show.Name.S01-S03.1080p.WEB-DL-GRP")?.label, "S01-S03")
        let c = try XCTUnwrap(ReleaseName.folder("Show Name COMPLETE 720p"))
        XCTAssertEqual(c.title, "Show Name")
        XCTAssertEqual(c.label, "Complete")
    }

    func testTailWords() {
        XCTAssertEqual(ReleaseName.stripTail("Silo Season 1"), "Silo")
        XCTAssertEqual(ReleaseName.stripTail("Pokemon Horizons Eng Dub"), "Pokemon Horizons")
        XCTAssertEqual(ReleaseName.stripTail("The Collection"), "The Collection", "never down to a bare article")
        XCTAssertEqual(ReleaseName.stripEpisodeRange("Pokemon Horizons Episode 1 to 6 [720p]"), "Pokemon Horizons [720p]")
    }

    func testLookAlikeCharacters() {
        XCTAssertEqual(ReleaseName.fixChars("Time\u{F025}!"), "Time?!")
        XCTAssertEqual(ReleaseName.fixChars("Re\u{A789}Zero"), "Re:Zero")
    }

    // MARK: Telling entries apart

    func testIdenticalTitlesGetMoreAttributes() throws {
        let a = try XCTUnwrap(ReleaseName.folder("Show.S01.1080p.WEB-DL.DDP5.1.H.264-GRP"))
        let b = try XCTUnwrap(ReleaseName.folder("Show.S01.1080p.WEB-DL.DDP5.1.H.265-GRP"))
        let c = try XCTUnwrap(ReleaseName.folder("Show.S01.2160p.WEB-DL.DDP5.1.H.265-OTHER"))
        let shown = ReleaseName.distinguishing([a, b, c])
        XCTAssertEqual(shown[2], ["4K", "WEB-DL", "OTHER"], "already distinct: only the default attributes")
        XCTAssertNotEqual(shown[0], shown[1], "same title, resolution, source and group: the codec is added")
        XCTAssertTrue(shown[0].contains("AVC") && shown[1].contains("HEVC"))
    }

    func testIdenticalInEverythingGetsTheNameEnd() throws {
        let a = try XCTUnwrap(ReleaseName.folder("Show.S01.1080p.WEB-DL-GRP"))
        let b = try XCTUnwrap(ReleaseName.folder("Show.S01.1080p.WEB-DL-GRP [rarbg]"))
        let shown = ReleaseName.distinguishing([a, b])
        XCTAssertNotEqual(shown[0], shown[1])
    }
}

/// Metadata text arrives with HTML character references (IMDb plots,
/// some addons): decoded once where it enters the app.
final class HTMLTextTests: XCTestCase {
    func testReferencesFromTheScreenshots() {
        XCTAssertEqual("In the Cotswolds, O&#39;Hara points out".decodingHTMLEntities, "In the Cotswolds, O'Hara points out")
        XCTAssertEqual("Tattersall gets Alice&#39;s tootsies".decodingHTMLEntities, "Tattersall gets Alice's tootsies")
    }

    func testNumericNamedAndUnknown() {
        XCTAssertEqual("Tom &amp; Jerry &#x27;s &quot;x&quot; &eacute;t&eacute; &rsquo;".decodingHTMLEntities, "Tom & Jerry 's \"x\" été ’")
        XCTAssertEqual("A &bogus; one & a lone ampersand".decodingHTMLEntities, "A &bogus; one & a lone ampersand")
        XCTAssertEqual("No references".decodingHTMLEntities, "No references")
    }

    func testAddonModelsDecodeOnRead() throws {
        let json = #"{"id":"tt1:1:1","title":"O&#39;Hara","overview":"Alice&#39;s day"}"#
        let v = try JSONDecoder().decode(MetaVideo.self, from: Data(json.utf8))
        XCTAssertEqual(v.title, "O'Hara")
        XCTAssertEqual(v.overview, "Alice's day")
    }
}
