import XCTest
@testable import Folio

/// Download packages (DownloadManager.packageName, 1.20.3): two shows'
/// "Season 1" folders used to become one package and one Media folder.
final class DownloadPackageTests: XCTestCase {
    private let base = URL(string: "https://dav.example.com/torrents/")!

    func testSeasonFoldersTakeTheirShowsName() {
        let a = DownloadManager.packageName(folder: base.appendingPathComponent("Mob.Land.S01.1080p.WEB-DL/Season 1"), title: "Season 1")
        let b = DownloadManager.packageName(folder: base.appendingPathComponent("Classroom.of.the.Elite.1080p/Season 1"), title: "Season 1")
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasSuffix("– Season 1"), a)
        XCTAssertTrue(b.hasSuffix("– Season 1"), b)
    }

    func testOtherSubFolders() {
        for sub in ["Extras", "Specials", "S02", "Featurettes", "Subs"] {
            let name = DownloadManager.packageName(folder: base.appendingPathComponent("Some Show/\(sub)"), title: sub)
            XCTAssertEqual(name, "Some Show – \(sub)", sub)
        }
    }

    func testAReleaseFolderKeepsItsTitle() {
        let url = base.appendingPathComponent("Mob.Land.S01.1080p.WEB-DL")
        XCTAssertEqual(DownloadManager.packageName(folder: url, title: "Mob Land"), "Mob Land")
        XCTAssertEqual(DownloadManager.packageName(folder: URL(string: "https://dav.example.com/Season%201")!, title: "Season 1"), "Season 1")
    }
}
