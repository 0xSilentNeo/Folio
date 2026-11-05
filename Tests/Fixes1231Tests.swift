import XCTest
@testable import Folio

/// 1.23.1, from the 5 Nov report.
final class Fixes1231Tests: XCTestCase {
    /// A 1080p video on this phone is shown at 1.22×: Anime4K's ×2 upscaler
    /// would run (its WHEN is "> 1.2") and build a 4K image every frame.
    /// Below 1.5× only the restore stages run.
    func testAnime4KRestoreOnlyChain() {
        XCTAssertEqual(Anime4K.chain(mode: .aa, quality: .fast, restoreOnly: true),
                       ["Anime4K_Clamp_Highlights.glsl", "Anime4K_Restore_CNN_M.glsl", "Anime4K_Restore_CNN_S.glsl"])
        XCTAssertEqual(Anime4K.chain(mode: .a, quality: .fast, restoreOnly: true),
                       ["Anime4K_Clamp_Highlights.glsl", "Anime4K_Restore_CNN_M.glsl"])
        XCTAssertFalse(Anime4K.chain(mode: .aa, quality: .fast, restoreOnly: true).contains { $0.contains("Upscale") || $0.contains("Downscale") })
        // C's denoise is its upscaler: it keeps its chain.
        XCTAssertEqual(Anime4K.chain(mode: .c, quality: .fast, restoreOnly: true), Anime4K.chain(mode: .c, quality: .fast))
        // The full chain is unchanged.
        XCTAssertTrue(Anime4K.chain(mode: .aa, quality: .fast).contains("Anime4K_Upscale_CNN_x2_M.glsl"))
        XCTAssertTrue(1920 * 1.22 / 1920 < Anime4K.fullChainScale)
    }

    /// The Lock Screen's artwork asks IMDb and TMDB for the picture at its size.
    func testArtworkAtFullSize() {
        XCTAssertEqual(NowPlayingArt.large("https://m.media-amazon.com/images/M/abc._V1_QL80_UX480_.jpg"),
                       "https://m.media-amazon.com/images/M/abc._V1_QL80_UX1400_.jpg")
        XCTAssertEqual(NowPlayingArt.large("https://image.tmdb.org/t/p/w300/xyz.jpg"), "https://image.tmdb.org/t/p/w1280/xyz.jpg")
        XCTAssertEqual(NowPlayingArt.large("https://example.com/a.jpg"), "https://example.com/a.jpg")
    }
}
