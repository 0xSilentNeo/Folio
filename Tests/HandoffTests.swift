import XCTest
@testable import Folio

/// Handoff (1.22.0): what an activity carries, read back as it was sent.
final class HandoffTests: XCTestCase {
    private typealias Payload = HandoffActivity.Payload

    /// Through a property list, as Handoff sends userInfo between devices.
    private func roundTrip(_ p: Payload) throws -> Payload? {
        let data = try PropertyListSerialization.data(fromPropertyList: p.userInfo, format: .binary, options: 0)
        let back = try PropertyListSerialization.propertyList(from: data, format: nil) as? [AnyHashable: Any]
        return Payload(userInfo: back)
    }

    func testDiscoverTitle() throws {
        let p = Payload(target: .discover(id: "tt0944947", type: "series", name: "Game of Thrones", poster: "https://example.com/p.jpg", addon: "org.example.kitsu"))
        XCTAssertEqual(try roundTrip(p), p)
        let bare = Payload(target: .discover(id: "kitsu:1", type: "series", name: "Show", poster: nil, addon: nil))
        XCTAssertEqual(try roundTrip(bare), bare)
    }

    func testLibraryFile() throws {
        let p = Payload(target: .library(file: "Lab Show S01E02.mp4", title: "Lab Show"))
        XCTAssertEqual(try roundTrip(p), p)
        XCTAssertNil(Payload(userInfo: ["v": 1, "kind": "library", "file": "../Documents/x.mp4"]), "a name, never a path")
    }

    func testPlaying() throws {
        var local = MediaItem(url: "/var/mobile/Documents/Media/Bright Movie 2024.mp4", title: "Bright Movie", source: .local)
        local.historyKey = local.url
        let p = Payload.playing(local, position: 612.5, duration: 5400)
        XCTAssertEqual(p.target, .library(file: "Bright Movie 2024.mp4", title: "Bright Movie"), "a library file goes by its name")
        XCTAssertEqual(try roundTrip(p)?.position, 612.5)
        XCTAssertEqual(try roundTrip(p)?.duration, 5400)

        var addon = MediaItem(url: "https://stream.example.com/abc", title: "Episode 3", source: .addon(name: "Lab"))
        addon.historyKey = "addon:tt0944947:1:3"
        addon.addonRef = "series|tt0944947|tt0944947:1:3"
        let q = Payload.playing(addon, position: 30, duration: 0)
        XCTAssertEqual(q.target, .item(key: "addon:tt0944947:1:3", title: "Episode 3", addonRef: "series|tt0944947|tt0944947:1:3"),
                       "an addon item by its history key, never its stream link")
        XCTAssertNil(q.duration, "an unknown length isn't sent")
        XCTAssertEqual(try roundTrip(q), q)
        XCTAssertFalse(q.userInfo.values.contains { ($0 as? String)?.contains("stream.example.com") == true })
    }

    func testTitleFromAnAddonRef() {
        XCTAssertEqual(Payload.discover(fromRef: "series|tt0944947|tt0944947:1:3", name: "GoT")?.target,
                       .discover(id: "tt0944947", type: "series", name: "GoT", poster: nil, addon: nil))
        XCTAssertNil(Payload.discover(fromRef: "nothing", name: "x"))
    }

    func testWhatCantBeOpened() {
        XCTAssertNil(Payload(userInfo: nil))
        XCTAssertNil(Payload(userInfo: ["v": 1]))
        XCTAssertNil(Payload(userInfo: ["v": 2, "kind": "somethingNewer", "id": "x"]), "a kind from a later version")
        XCTAssertNil(Payload(userInfo: ["v": 1, "kind": "discover"]), "no id")
        XCTAssertNotNil(Payload(userInfo: ["v": 2, "kind": "discover", "id": "tt1", "extra": true]), "fields it doesn't know are ignored")
    }
}
