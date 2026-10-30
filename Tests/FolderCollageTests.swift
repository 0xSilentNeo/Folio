import XCTest
@testable import GlassPlayer

/// A folder tile's collage (LibraryGroup.collageFiles, 1.20.0): one picture
/// per title in the folder, up to four. Until 1.20.0 it was the folder's
/// first four files, so a show's episodes filled it.
final class FolderCollageTests: XCTestCase {
    private func folder(_ names: [String]) -> LibraryGroup {
        let dir = URL(fileURLWithPath: "/lab/Media/Mixed", isDirectory: true)
        return LibraryGroup(id: "d|" + dir.path, title: "Mixed", files: names.map { dir.appendingPathComponent($0) },
                            isSeries: false, date: Date(), size: 0, folder: dir)
    }

    func testAShowsEpisodesAreOnePicture() {
        let g = folder(["Another Film 2019.mp4", "Bright Movie 2024.mp4", "Lab Show S01E04.mp4", "Lab Show S01E05.mp4", "Lab Show S01E06.mp4"])
        XCTAssertEqual(g.collageFiles.map(\.lastPathComponent), ["Another Film 2019.mp4", "Bright Movie 2024.mp4", "Lab Show S01E04.mp4"])
    }

    func testFourTitlesAtMost() {
        let g = folder(["A 2001.mp4", "B 2002.mp4", "C 2003.mp4", "D 2004.mp4", "E 2005.mp4"])
        XCTAssertEqual(g.collageFiles.count, 4)
    }

    /// Two films that happen to share a name are two titles.
    func testFilmsAreEachTheirOwn() {
        let g = folder(["Dune 1984.mkv", "Dune 2021.mkv"])
        XCTAssertEqual(g.collageFiles.count, 2)
    }
}
