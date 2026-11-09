import XCTest
@testable import Folio

/// The Metal renderer drawing into the video layer (1.28.0): frames take
/// the video's shape, as OpenGL's do.
final class MetalFrameRendererTests: XCTestCase {
    /// 16:9 in a landscape iPhone (2868×1320): the full height, pillarboxed by the layer.
    func testFramesTakeTheVideosShapeInTheView() {
        let s = MetalFrameRenderer.frameSize(view: (2868, 1320), video: (3840, 2160), pip: nil)
        XCTAssertEqual(s.1, 1320)
        XCTAssertEqual(s.0, 2346)
    }

    /// A small video on a big screen: at most twice its own size.
    func testAtMostTwiceTheVideosSize() {
        let s = MetalFrameRenderer.frameSize(view: (2732, 2048), video: (640, 360), pip: nil)
        XCTAssertEqual(s.0, 1280)
        XCTAssertEqual(s.1, 720)
    }

    func testPiPsSizeWinsAndTheViewsBeforeTheVideoIsKnown() {
        XCTAssertTrue(MetalFrameRenderer.frameSize(view: (2868, 1320), video: (1920, 1080), pip: (960, 540)) == (960, 540))
        XCTAssertTrue(MetalFrameRenderer.frameSize(view: (1320, 2868), video: nil, pip: nil) == (1320, 2868))
    }
}
