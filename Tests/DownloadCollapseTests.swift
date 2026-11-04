import XCTest
@testable import Folio

/// Folding a package on the Downloads screen to its header (1.22.3, item 15
/// of the 4 Nov list): per package, kept between launches.
final class DownloadCollapseTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "folio.tests.collapse.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testATapFoldsAndASecondOpens() {
        XCTAssertTrue(DownloadCollapse.load(defaults).isEmpty)
        XCTAssertEqual(DownloadCollapse.toggle("Show A", in: defaults), ["Show A"])
        XCTAssertEqual(DownloadCollapse.toggle("Show B", in: defaults), ["Show A", "Show B"])
        XCTAssertEqual(DownloadCollapse.toggle("Show A", in: defaults), ["Show B"])
        XCTAssertEqual(DownloadCollapse.toggle("Show B", in: defaults), [])
        XCTAssertNil(defaults.object(forKey: DownloadCollapse.key), "nothing kept once none is folded")
    }

    func testFoldedPackagesStayFoldedAcrossLaunches() {
        DownloadCollapse.toggle("Show A – Season 1", in: defaults)
        // A new launch reads them from the same defaults.
        let again = UserDefaults(suiteName: suite)!
        XCTAssertEqual(DownloadCollapse.load(again), ["Show A – Season 1"])
    }

    func testPackagesNoLongerListedAreForgotten() {
        DownloadCollapse.toggle("Gone", in: defaults)
        DownloadCollapse.toggle("Kept", in: defaults)
        XCTAssertEqual(DownloadCollapse.prune(keeping: ["Kept", "Other"], in: defaults), ["Kept"])
        XCTAssertEqual(DownloadCollapse.load(defaults), ["Kept"])
    }
}
