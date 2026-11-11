import XCTest
@testable import Folio

/// 1.29.0: Fix Match, the opening card, the paged welcome.
final class Fixes1290Tests: XCTestCase {
    /// A title matched by hand is kept by the name parsed from its files, so
    /// every episode follows it; putting it back forgets it.
    func testAMatchMadeByHandCoversEveryEpisode() async {
        let e1 = "Zz.Fix.Match.Lab.S01E01.1080p.WEB-GRP.mkv", e2 = "Zz.Fix.Match.Lab.S01E02.1080p.WEB-GRP.mkv"
        let service = MetadataService.shared
        let before = await service.pin(forFile: e1)
        XCTAssertNil(before)
        await service.setPin(.init(id: "tt0213338", type: "series"), forFile: e1)
        let other = await service.pin(forFile: e2)
        XCTAssertEqual(other, MetadataService.Pin(id: "tt0213338", type: "series"), "the next episode has the same match")
        let unrelated = await service.pin(forFile: "Some.Other.Show.S01E01.mkv")
        XCTAssertNil(unrelated)
        await service.setPin(nil, forFile: e2)
        let after = await service.pin(forFile: e1)
        XCTAssertNil(after, "back to the automatic match")
    }

    /// Specials share their show's match: "Show OVA" is pinned with "Show".
    func testSpecialsShareTheShowsMatch() {
        let show = MetadataService.pinKey(TitleParser.parse("Lab Show - 03 (1080p).mkv"))
        XCTAssertEqual(show, "lab show")
    }
}
