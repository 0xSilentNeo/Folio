import XCTest
@testable import Folio

/// Settings' search (1.26.1): what people type finds the setting's page.
final class SettingsIndexTests: XCTestCase {
    private func titles(_ q: String) -> [String] { SettingsIndex.search(q).map(\.title) }

    func testNothingTypedFindsNothing() {
        XCTAssertTrue(SettingsIndex.search("").isEmpty)
        XCTAssertTrue(SettingsIndex.search("   ").isEmpty)
    }

    func testEveryEntryIsDistinct() {
        let ids = SettingsIndex.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "two entries with one name on one page")
    }

    func testEveryPageIsFound() {
        for p in SettingsPage.allCases {
            XCTAssertTrue(titles(p.title).contains(p.title), "\(p.title) isn't found by its name")
        }
    }

    func testKeywords() {
        XCTAssertEqual(titles("pip").first, "Picture in Picture")
        XCTAssertTrue(titles("vulkan").contains("Renderer"))
        XCTAssertTrue(titles("dark mode").contains("Appearance"))
        XCTAssertTrue(titles("cellular").contains("Use Mobile Data"))
    }

    func testSubpagesOpenThemselves() {
        let trakt = SettingsIndex.search("trakt").first
        XCTAssertEqual(trakt?.route, .settingsSubpage(.syncService(.trakt)))
        XCTAssertEqual(trakt?.page, .sync)
        XCTAssertEqual(SettingsIndex.search("audio languages").first?.route, .settingsSubpage(.audioLanguages))
    }

    func testCaseDoesntMatter() {
        XCTAssertEqual(titles("PICTURE IN"), titles("picture in"))
        XCTAssertFalse(titles("PICTURE IN").isEmpty)
    }

    func testTitlesStartingWithTheQueryComeFirst() {
        // "Subtitle Languages" and "Subtitle Style" start with it; "Show Subtitles" only has it.
        let found = titles("subtitle")
        let show = found.firstIndex(of: "Show Subtitles")
        let style = found.firstIndex(of: "Subtitle Style")
        XCTAssertNotNil(show)
        XCTAssertNotNil(style)
        if let show, let style { XCTAssertLessThan(style, show) }
    }

    func testThePageNameAloneDoesntMatch() {
        // Night Mode is on Audio & Subtitles, but has nothing to do with subtitles.
        XCTAssertFalse(titles("subtitle").contains("Night Mode"))
        XCTAssertTrue(titles("subtitle").contains("Audio & Subtitles"), "the page itself is found")
    }

    func testUnknownWordsFindNothing() {
        XCTAssertTrue(SettingsIndex.search("zzqx").isEmpty)
        XCTAssertTrue(SettingsIndex.search("subtitle zzqx").isEmpty, "every word has to match")
    }
}
