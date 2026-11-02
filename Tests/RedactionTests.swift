import XCTest
@testable import Folio

/// What Diagnostics.redact hides before a log line or the report is written
/// (1.20.2: Torrentio-style debrid keys in plain text and API-key headers got
/// through, review of 31 Oct).
final class RedactionTests: XCTestCase {
    private let key = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcd"

    func testDebridKeyInAnAddonPath() {
        let line = "loadfile https://addon.example/sort=qualitysize|realdebrid=\(key)/stream/series/tt1.json"
        let out = Diagnostics.redact(line)
        XCTAssertFalse(out.contains(key), out)
        XCTAssertTrue(out.contains("realdebrid=••••"), out)
        XCTAssertTrue(out.contains("sort=qualitysize"), out)        // ordinary settings stay readable
    }

    func testOtherDebridServicesAndShortKeys() {
        for service in ["alldebrid", "premiumize", "torbox", "debridlink"] {
            let out = Diagnostics.redact("https://a.example/\(service)=short1234|x/manifest.json")
            XCTAssertTrue(out.contains("\(service)=••••"), out)
        }
    }

    func testLongKeyLikeSettingValue() {
        let out = Diagnostics.redact("https://a.example/configure?token_v2=\(key)&lang=en")
        XCTAssertFalse(out.contains(key), out)
        XCTAssertTrue(out.contains("lang=en"), out)
    }

    func testKeysInResolvePathsAndEncodedSeparators() {
        let short = "AbCdEf1234567890XyZw"                 // 20 characters, under the 40-character path rule
        let a = Diagnostics.redact("https://a.example/resolve/alldebrid/\(short)/tt1/1/ep.mkv")
        XCTAssertFalse(a.contains(short), a)
        let b = Diagnostics.redact("https://a.example/sort=size%7Calldebrid=\(short)/manifest.json")
        XCTAssertFalse(b.contains(short), b)
    }

    func testALongLineStaysFast() {
        let line = String(repeating: "a1", count: 10_000) + "=x"
        let t0 = Date()
        _ = Diagnostics.redact(line)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.5)
    }

    func testApiKeyHeader() {
        let out = Diagnostics.redact("X-Api-Key: \(key)")
        XCTAssertFalse(out.contains(key), out)
    }

    func testEverydayLinesUnchanged() {
        let line = "[player] loadfile /Media/Show S01E02.mkv start=+12.5 -> 0"
        XCTAssertEqual(Diagnostics.redact(line), line)
    }
}
