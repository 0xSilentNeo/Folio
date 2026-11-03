import XCTest
@testable import Folio

/// Home's Real-Debrid row (1.21.0): one tile per show, whatever its season
/// packs say about the year; films keep their year.
@MainActor
final class ReleaseRowTests: XCTestCase {
    private func key(_ folder: String) throws -> String {
        LibraryIndexStore.rowKey(try XCTUnwrap(ReleaseName.folder(folder), folder))
    }

    func testAShowsSeasonPacksAreOneTile() throws {
        XCTAssertEqual(try key("Mob.Land.S01.1080p.WEB-DL"), try key("Mob.Land.2025.S02.2160p.WEB-DL"))
    }

    func testFilmsKeepTheirYear() throws {
        XCTAssertNotEqual(try key("Dune.1984.1080p.BluRay"), try key("Dune.2021.2160p.WEB-DL"))
    }
}
