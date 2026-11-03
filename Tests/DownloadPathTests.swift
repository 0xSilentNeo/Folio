import XCTest
@testable import Folio

/// Where a download is saved (1.22.1): inside Documents, not as a whole
/// path. iOS moves the app's container on an update or a reinstall; a
/// download queued before kept the old container's path and its finished
/// file couldn't be saved ("You don't have permission to save the file",
/// 4 Nov report).
final class DownloadPathTests: XCTestCase {
    private let docs = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/NEW-0000/Documents", isDirectory: true)

    func testAPathInsideDocuments() {
        XCTAssertEqual(DownloadItem.documentsPath(docs.path + "/Media/Show/E1.mkv", documents: docs.path), "Media/Show/E1.mkv")
        // Another container's (the install before an update), /private or not.
        XCTAssertEqual(DownloadItem.documentsPath("/var/mobile/Containers/Data/Application/OLD-1111/Documents/Media/E1.mkv", documents: docs.path), "Media/E1.mkv")
        XCTAssertEqual(DownloadItem.documentsPath("/private/var/mobile/Containers/Data/Application/OLD-1111/Documents/Media/My Show/E1.mkv", documents: docs.path), "Media/My Show/E1.mkv")
        XCTAssertEqual(DownloadItem.documentsPath("file:///var/mobile/Containers/Data/Application/OLD/Documents/Media/My%20Show/E1.mkv", documents: docs.path), "Media/My Show/E1.mkv")
        XCTAssertNil(DownloadItem.documentsPath("/tmp/a.mkv", documents: docs.path))
        XCTAssertNil(DownloadItem.documentsPath(docs.path + "/", documents: docs.path))
    }

    func testAnOldContainersPathMovesToThisOne() {
        let old = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/OLD-1111/Documents/Media/Classroom of the Elite/E02.mkv")
        XCTAssertEqual(DownloadItem.rebased(old, documents: docs).path, docs.path + "/Media/Classroom of the Elite/E02.mkv")
        // Outside any Documents: as it was.
        XCTAssertEqual(DownloadItem.rebased(URL(fileURLWithPath: "/tmp/a.mkv"), documents: docs).path, "/tmp/a.mkv")
        XCTAssertNil(DownloadItem.inDocuments("../Library/x", documents: docs))
        XCTAssertNil(DownloadItem.inDocuments("/etc/x", documents: docs))
    }

    func testAListSavedBefore1221IsReadIntoThisContainer() throws {
        // As 1.22.0 saved it: the whole path of the container before the update.
        let json = #"[{"url":"https://dav.example.invalid/E02.mkv","fileName":"E02.mkv","package":"P","expected":10,"state":"queued","destination":"file:///var/mobile/Containers/Data/Application/OLD-1111/Documents/Media/P/E02.mkv"}]"#
        let items = try XCTUnwrap(JSONDecoder().decodeLossy(DownloadItem.self, from: Data(json.utf8)))
        XCTAssertEqual(items.first?.destination.path, MPVFiles.documents.appendingPathComponent("Media/P/E02.mkv").path)
    }

    func testSavedInsideDocumentsAndStillReadableByOlderVersions() throws {
        let dest = MPVFiles.documents.appendingPathComponent("Media/P/E1.mkv")
        let item = DownloadItem(url: URL(string: "https://dav.example.invalid/E1.mkv")!, fileName: "E1.mkv", package: "P", expected: 1, destination: dest)
        let data = try JSONEncoder().encode(item)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["destinationPath"] as? String, "Media/P/E1.mkv")
        XCTAssertNotNil(object["destination"], "1.22.0 needs the whole path to read the item at all")
        // Read back: the saved path inside Documents wins over the whole one.
        var edited = object
        edited["destination"] = "file:///var/mobile/Containers/Data/Application/GONE/Documents/Elsewhere/E1.mkv"
        let again = try JSONDecoder().decode(DownloadItem.self, from: JSONSerialization.data(withJSONObject: edited))
        XCTAssertEqual(again.destination.path, dest.path)
    }

    func testPartsSurviveTheList() throws {
        var item = DownloadItem(url: URL(string: "https://dav.example.invalid/E1.mkv")!, fileName: "E1.mkv", package: "P", expected: 100,
                                destination: MPVFiles.mediaDir.appendingPathComponent("E1.mkv"))
        item.parts = DownloadManager.split(total: 200_000_000, into: 4)
        item.parts?[1].done = true
        item.parts?[2].resumeFile = "x.2.resume"
        let again = try JSONDecoder().decode(DownloadItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(again.parts, item.parts)
        // A list from before parts reads without them.
        let old = #"{"url":"https://dav.example.invalid/a.mkv","fileName":"a.mkv","destination":"file:///tmp/a.mkv"}"#
        XCTAssertNil(try JSONDecoder().decode(DownloadItem.self, from: Data(old.utf8)).parts)
    }

    @MainActor
    func testAPackageCantLeaveMedia() {
        let dest = DownloadManager.destination(fileName: "E1.mkv", package: "..")
        XCTAssertTrue(dest.path.hasPrefix(MPVFiles.mediaDir.path + "/"), dest.path)
    }
}
