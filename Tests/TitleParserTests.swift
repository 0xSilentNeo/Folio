import XCTest
@testable import Folio

/// File names as the library, metadata and skip lookups read them
/// (TitleParser, 1.20.3): films with a number in the title, a possessive "s",
/// and a year inside the title, plus the cases that already worked.
final class TitleParserTests: XCTestCase {
    private func p(_ name: String) -> TitleParser.Parsed { TitleParser.parse(name) }

    func testSequelNumbersStayInTheTitle() {
        let toy = p("Toy.Story.4.2019.1080p.BluRay.x264.mkv")
        XCTAssertEqual(toy.title, "Toy Story 4")
        XCTAssertNil(toy.episode)
        XCTAssertEqual(toy.year, 2019)
        let apollo = p("Apollo 13 (1995) 1080p.mkv")
        XCTAssertEqual(apollo.title, "Apollo 13")
        XCTAssertNil(apollo.episode)
    }

    func testAPossessiveIsNotASeason() {
        let o = p("Ocean's 11 (2001) 1080p.mkv")
        XCTAssertNil(o.season)
        XCTAssertNil(o.episode)
        XCTAssertEqual(o.title, "Ocean's 11")
        XCTAssertEqual(o.year, 2001)
    }

    func testAYearInTheTitle() {
        for name in ["Blade.Runner.2049.2017.2160p.UHD.mkv", "Blade Runner 2049 (2017).mkv"] {
            let b = p(name)
            XCTAssertEqual(b.title, "Blade Runner 2049", name)
            XCTAssertEqual(b.year, 2017, name)
        }
    }

    func testEpisodesStillParse() {
        let a = p("Show.Name.S02E05.1080p.WEB-DL.mkv")
        XCTAssertEqual(a.title, "Show Name"); XCTAssertEqual(a.season, 2); XCTAssertEqual(a.episode, 5)
        let b = p("[SubsPlease] Frieren - 12 (1080p) [ABCD1234].mkv")
        XCTAssertEqual(b.title, "Frieren"); XCTAssertEqual(b.episode, 12)
        let c = p("Show Season 2 Episode 3.mkv")
        XCTAssertEqual(c.season, 2); XCTAssertEqual(c.episode, 3)
        let d = p("Dragon Ball Super 05.mkv")
        XCTAssertEqual(d.title, "Dragon Ball Super"); XCTAssertEqual(d.episode, 5)
        let e = p("Show.S03.1080p.mkv")
        XCTAssertEqual(e.season, 3)
    }
}
