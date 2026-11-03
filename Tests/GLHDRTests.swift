import XCTest
@testable import Folio

/// The HDR data the OpenGL renderer attaches to its frames (1.22.1): the
/// layouts of HEVC's content light level and mastering display SEI, which
/// Core Video's attachments use.
final class GLHDRTests: XCTestCase {
    func testContentLightLevelIsTwoBigEndianShorts() {
        let h = SampleBufferRenderer.HDROutput(hlg: false, maxCLL: 1000, maxFALL: 400, maxLuma: nil, minLuma: nil)
        XCTAssertEqual(SampleBufferRenderer.contentLightLevel(h).map([UInt8].init), [0x03, 0xE8, 0x01, 0x90])
        XCTAssertNil(SampleBufferRenderer.contentLightLevel(.init(hlg: false, maxCLL: nil, maxFALL: nil, maxLuma: nil, minLuma: nil)))
    }

    func testMasteringDisplayLayout() throws {
        let h = SampleBufferRenderer.HDROutput(hlg: false, maxCLL: nil, maxFALL: nil, maxLuma: 1000, minLuma: 0.005)
        let d = try XCTUnwrap(SampleBufferRenderer.masteringDisplay(h))
        XCTAssertEqual(d.count, 24)
        let bytes = [UInt8](d)
        func u16(_ i: Int) -> Int { Int(bytes[i]) << 8 | Int(bytes[i + 1]) }
        func u32(_ i: Int) -> Int { (0..<4).reduce(0) { $0 << 8 | Int(bytes[i + $1]) } }
        XCTAssertEqual(u16(0), 8500)        // green x 0.170
        XCTAssertEqual(u16(12), 15635)      // white x 0.3127
        XCTAssertEqual(u32(16), 10_000_000) // 1000 nits
        XCTAssertEqual(u32(20), 50)         // 0.005 nits
        XCTAssertNil(SampleBufferRenderer.masteringDisplay(.init(hlg: true, maxCLL: nil, maxFALL: nil, maxLuma: nil, minLuma: nil)))
    }
}
