import XCTest
@testable import Folio

/// Removing finished downloads with their files (Downloads → a package's
/// menu → Delete downloaded files, 4 Nov crash report). Deleting a file
/// makes LocalMediaStore.delete call DownloadManager.forgetDeleted, which
/// takes the same item off the list; `remove` then removed by the index it
/// had looked up before: out of range when the item was last (the crash), or
/// another download taken off the list in its place.
@MainActor
final class DownloadRemoveTests: XCTestCase {
    private var made: [URL] = []

    override func tearDown() {
        for u in made { try? FileManager.default.removeItem(at: u) }
        made = []
        super.tearDown()
    }

    /// Finished downloads of a new package, their files in Media.
    private func finished(_ names: [String], package: String) throws -> [DownloadItem] {
        let dir = MPVFiles.mediaDir.appendingPathComponent(package, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        made.append(dir)
        return try names.map { name in
            let dest = dir.appendingPathComponent(name)
            try Data("lab".utf8).write(to: dest)
            var d = DownloadItem(url: URL(string: "https://dav.example.invalid/\(UUID().uuidString)/\(name)")!, fileName: name,
                                 package: package, expected: 3, destination: dest)
            d.state = .done
            d.received = 3
            d.finished = Date()
            return d
        }
    }

    private func paused(_ name: String, package: String) -> DownloadItem {
        var d = DownloadItem(url: URL(string: "https://dav.example.invalid/\(UUID().uuidString)/\(name)")!, fileName: name,
                             package: package, expected: 100,
                             destination: MPVFiles.mediaDir.appendingPathComponent(package).appendingPathComponent(name))
        d.state = .paused
        return d
    }

    func testDeletingTheLastFinishedFileDoesNotCrash() throws {
        let dm = DownloadManager.shared
        let package = "Remove Lab \(UUID().uuidString.prefix(6))"
        let other = paused("Other.mkv", package: package + " other")
        let done = try finished(["E1.mkv"], package: package)
        // As in the report: the finished file is the last one in the list.
        dm.insertForTests([other] + done)
        dm.removeFinished(package: package, deleteFiles: true)
        XCTAssertFalse(dm.items.contains { $0.package == package })
        XCTAssertTrue(dm.items.contains { $0.id == other.id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: done[0].destination.path))
        dm.remove(other.id)
    }

    func testDeletingFilesTakesOnlyThoseDownloadsOffTheList() throws {
        let dm = DownloadManager.shared
        let package = "Remove Lab \(UUID().uuidString.prefix(6))"
        let done = try finished(["E1.mkv", "E2.mkv"], package: package)
        let other = paused("Other.mkv", package: package + " other")
        dm.insertForTests(done + [other])
        dm.removeFinished(package: package, deleteFiles: true)
        XCTAssertFalse(dm.items.contains { $0.package == package })
        XCTAssertTrue(dm.items.contains { $0.id == other.id }, "another package's download stays")
        for d in done { XCTAssertFalse(FileManager.default.fileExists(atPath: d.destination.path), d.fileName) }
        dm.remove(other.id)
    }

    func testOneFileDeletedFromTheRow() throws {
        let dm = DownloadManager.shared
        let package = "Remove Lab \(UUID().uuidString.prefix(6))"
        let done = try finished(["E1.mkv", "E2.mkv"], package: package)
        dm.insertForTests(done)
        dm.remove(done[1].id, deleteFile: true)
        XCTAssertEqual(dm.items.filter { $0.package == package }.map(\.id), [done[0].id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: done[1].destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: done[0].destination.path))
        dm.removeFinished(package: package, deleteFiles: true)
    }
}
