import XCTest
@testable import GlassPlayer

/// The WebDAV browser's order (DAVOrder): folders first in every sort,
/// numeric-aware names, items without a date or size last, direction.
final class DAVOrderTests: XCTestCase {
    private func item(_ name: String, dir: Bool = false, size: Int64? = nil, modified: Double? = nil, created: Double? = nil) -> DAVItem {
        var i = DAVItem(url: URL(string: "https://dav.test/" + name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)!, name: name, isDirectory: dir,
                        size: size, modified: modified.map { Date(timeIntervalSince1970: $0) }, contentType: nil)
        i.created = created.map { Date(timeIntervalSince1970: $0) }
        return i
    }

    private lazy var items: [DAVItem] = [
        item("Season 1", dir: true, modified: 300),
        item("Extras", dir: true),
        item("Another Show", dir: true, modified: 900),
        item("Show - Episode 10.mkv", size: 700, modified: 100, created: 1000),
        item("Show - Episode 2.mkv", size: 650, modified: 200),
        item("Show - Episode 1.mkv", size: 900, modified: 50),
        item("notes.txt"),
    ]

    private func names(_ sort: DAVSort, _ ascending: Bool, clean: Bool = false) -> [String] {
        DAVOrder.sorted(DAVOrder.keyed(items, clean: clean), by: sort, ascending: ascending).map(\.name)
    }

    func testNameIsNumericAwareAndFoldersFirst() {
        XCTAssertEqual(names(.name, true), ["Another Show", "Extras", "Season 1",
                                            "notes.txt", "Show - Episode 1.mkv", "Show - Episode 2.mkv", "Show - Episode 10.mkv"])
        XCTAssertEqual(names(.name, false), ["Season 1", "Extras", "Another Show",
                                             "Show - Episode 10.mkv", "Show - Episode 2.mkv", "Show - Episode 1.mkv", "notes.txt"])
    }

    func testRecentUsesCreationDateThenLastModifiedAndUndatedLast() {
        // Episode 10: created 1000 (beats its modified 100). Undated: last, by name.
        XCTAssertEqual(names(.recent, false), ["Another Show", "Season 1", "Extras",
                                               "Show - Episode 10.mkv", "Show - Episode 2.mkv", "Show - Episode 1.mkv", "notes.txt"])
        XCTAssertEqual(names(.recent, true), ["Season 1", "Another Show", "Extras",
                                              "Show - Episode 1.mkv", "Show - Episode 2.mkv", "Show - Episode 10.mkv", "notes.txt"])
    }

    func testSizeKeepsFoldersByNameAndSizelessLast() {
        XCTAssertEqual(names(.size, false), ["Another Show", "Extras", "Season 1",
                                             "Show - Episode 1.mkv", "Show - Episode 10.mkv", "Show - Episode 2.mkv", "notes.txt"])
        XCTAssertEqual(names(.size, true), ["Another Show", "Extras", "Season 1",
                                            "Show - Episode 2.mkv", "Show - Episode 10.mkv", "Show - Episode 1.mkv", "notes.txt"])
    }

    func testStartingDirections() {
        XCTAssertTrue(DAVSort.name.startsAscending)
        XCTAssertFalse(DAVSort.recent.startsAscending)
        XCTAssertFalse(DAVSort.size.startsAscending)
        XCTAssertEqual(DAVSort(rawValue: "date"), .recent, "choices saved before 1.18.1 still read back")
    }
}
