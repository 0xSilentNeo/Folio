import XCTest
@testable import Folio

/// 1.28.1: the hardware decoder after a trip away.
@MainActor
final class Fixes1281Tests: XCTestCase {
    /// What counts as the hardware decoder (mpv's hwdec-current).
    func testHardwareDecoderNames() {
        XCTAssertTrue(PlayerModel.isHardware("videotoolbox"))
        XCTAssertTrue(PlayerModel.isHardware("videotoolbox-copy"))
        XCTAssertFalse(PlayerModel.isHardware(""))
        XCTAssertFalse(PlayerModel.isHardware("no"))
    }
}
