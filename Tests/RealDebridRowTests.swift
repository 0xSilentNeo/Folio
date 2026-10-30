import XCTest
@testable import GlassPlayer

/// Home's Real-Debrid row (LibraryIndexStore.newestReleases, 1.20.0): the
/// start folder's releases, newest first, one per title, at most the limit.
/// 1.19.0's collage took the newest folders anywhere in the index, so a
/// title could show twice (31 Oct: Daemons of the Shadow Realm twice, The
/// Gentlemen twice).
@MainActor
final class RealDebridRowTests: XCTestCase {
    private let root = URL(string: "https://dav.example.com/")!

    /// A start folder with these releases, `age` seconds old each.
    private func index(_ names: [(String, TimeInterval)]) -> LibraryIndex {
        var i = LibraryIndex(account: "lab", root: LibraryIndex.key(root))
        var subs: [String] = []
        for (n, age) in names {
            let u = root.appendingPathComponent(n, isDirectory: true)
            let d = Date(timeIntervalSince1970: 1_800_000_000 - age)
            i.folders[LibraryIndex.key(u)] = LibraryIndex.Folder(name: n, etag: nil, modified: d, added: d, listed: d, subfolders: [], files: [])
            subs.append(LibraryIndex.key(u))
        }
        i.folders[i.root] = LibraryIndex.Folder(name: "", etag: nil, modified: nil, added: nil, listed: Date(), subfolders: subs, files: [])
        return i
    }

    func testNewestFirstOncePerTitle() {
        let names = ShotsSeed.labReleases.enumerated().map { ($0.element, Double($0.offset) * 3600) }
        let row = LibraryIndexStore.newestReleases(index(names), limit: 20)
        let titles = row.compactMap { ReleaseName.folder($0.name)?.title }
        XCTAssertEqual(titles.count, 20, "\(titles)")
        XCTAssertEqual(Set(titles).count, titles.count, "a title twice: \(titles)")
        XCTAssertEqual(row.first?.name, ShotsSeed.labReleases[0], "not The Gentlemen's newest release first")
        XCTAssertFalse(row.contains { $0.name == ShotsSeed.labReleases[3] }, "The Gentlemen's older release is in the row")
        XCTAssertFalse(row.contains { $0.name == ShotsSeed.labReleases[5] }, "Daemons of the Shadow Realm's older release is in the row")
        let dates = row.compactMap(\.added)
        XCTAssertEqual(dates, dates.sorted(by: >), "not newest first")
    }

    func testLimit() {
        let names = ShotsSeed.labReleases.enumerated().map { ($0.element, Double($0.offset)) }
        XCTAssertEqual(LibraryIndexStore.newestReleases(index(names), limit: 5).count, 5)
    }

    /// Only the start folder's own folders: a folder inside a release (newer
    /// than everything) is never an entry of its own.
    func testOnlyTheStartFolder() {
        var i = index([("MobLand.S01.2160p.AMZN.WEB-DL.DDP5.1.H.265-NTb", 100)])
        let release = i.folders[i.root]!.subfolders[0]
        let inner = LibraryIndex.key(URL(string: release)!.appendingPathComponent("Severance.S02.1080p.ATVP.WEB-DL-FLUX", isDirectory: true))
        let d = Date(timeIntervalSince1970: 1_900_000_000)
        i.folders[inner] = LibraryIndex.Folder(name: "Severance.S02.1080p.ATVP.WEB-DL-FLUX", etag: nil, modified: d, added: d, listed: d, subfolders: [], files: [])
        i.folders[release]!.subfolders.append(inner)
        XCTAssertEqual(LibraryIndexStore.newestReleases(i, limit: 20).map(\.name), ["MobLand.S01.2160p.AMZN.WEB-DL.DDP5.1.H.265-NTb"])
    }

    /// Folders that aren't releases ("torrents", "Season 1") are left out.
    func testFoldersThatArentReleases() {
        let row = LibraryIndexStore.newestReleases(index([("torrents", 0), ("Season 1", 1), ("Dune.Part.Two.2024.2160p.UHD.BluRay-FGT", 2)]), limit: 20)
        XCTAssertEqual(row.map(\.name), ["Dune.Part.Two.2024.2160p.UHD.BluRay-FGT"])
    }
}
