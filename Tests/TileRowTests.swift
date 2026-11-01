import XCTest
@testable import GlassPlayer

/// Home's Thumbnails rows (TileRow, 1.20.1): the tiles split into rows of the
/// column count, a fourth entry in a second row when there are three columns
/// (2 Nov report: "Mixed" drawn in the first row), and new row ids when the
/// column count changes.
final class TileRowTests: XCTestCase {
    private func groups(_ titles: [String]) -> [LibraryGroup] {
        titles.map { LibraryGroup(id: "g|" + $0, title: $0, files: [URL(fileURLWithPath: "/lab/Media/\($0).mkv")],
                                  isSeries: false, date: Date(), size: 0) }
    }

    func testFourEntriesInThreeColumnsMakeTwoRows() {
        let rows = TileRow.rows(groups(["MobLand", "Classroom", "Dragon Ball", "Mixed"]), columns: 3)
        XCTAssertEqual(rows.map { $0.groups.map(\.title) }, [["MobLand", "Classroom", "Dragon Ball"], ["Mixed"]])
        XCTAssertEqual(rows.map(\.isLast), [false, true])
        XCTAssertEqual(rows.map(\.index), [0, 1])
    }

    func testLandscapeColumnsMakeOneRowWithNewIDs() {
        let g = groups(["MobLand", "Classroom", "Dragon Ball", "Mixed"])
        let upright = TileRow.rows(g, columns: 3), landscape = TileRow.rows(g, columns: 6)
        XCTAssertEqual(landscape.count, 1)
        XCTAssertTrue(landscape[0].isLast)
        XCTAssertTrue(Set(upright.map(\.id)).isDisjoint(with: landscape.map(\.id)))
    }

    func testEdges() {
        XCTAssertTrue(TileRow.rows([], columns: 3).isEmpty)
        XCTAssertEqual(TileRow.rows(groups(["A", "B", "C"]), columns: 3).count, 1)
        XCTAssertEqual(TileRow.rows(groups(["A", "B"]), columns: 0).count, 2)   // never a zero-wide row
    }
}
