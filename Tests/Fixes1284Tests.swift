import XCTest
import UIKit
import WidgetKit
@testable import Folio

/// 1.28.4: the Airing Day poster, the Resume control's link.
@MainActor
final class Fixes1284Tests: XCTestCase {
    /// Each service's full-size poster for the widget, not the small one
    /// the tracked show keeps.
    func testTheAiringWidgetAsksForLargePosters() {
        XCTAssertEqual(AiringSnapshotWriter.largePoster("https://static.tvmaze.com/uploads/images/medium_portrait/512/1280917.jpg"),
                       "https://static.tvmaze.com/uploads/images/original_untouched/512/1280917.jpg")
        XCTAssertEqual(AiringSnapshotWriter.largePoster("https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx171018-2ldCj6QywuOa.jpg"),
                       "https://s4.anilist.co/file/anilistcdn/media/anime/cover/extraLarge/bx171018-2ldCj6QywuOa.jpg")
        XCTAssertEqual(AiringSnapshotWriter.largePoster("https://m.media-amazon.com/images/M/MV5BMTk._V1_QL75_UX190_.jpg"),
                       "https://m.media-amazon.com/images/M/MV5BMTk._V1_QL80_UX400_.jpg")
        XCTAssertEqual(AiringSnapshotWriter.largePoster("https://example.com/p.jpg"), "https://example.com/p.jpg")
        XCTAssertGreaterThanOrEqual(AiringSnapshot.picturePixels, 600)
    }

    // MARK: The glass

    /// The frosted picture is dimmed as far as its brightness needs: light
    /// over a dark picture, deeper over a bright one.
    func testTheFrostedPictureIsDimmedByItsBrightness() {
        func plain(_ c: UIColor) -> UIImage {
            let f = UIGraphicsImageRendererFormat(); f.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: f).image { ctx in
                c.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
        }
        XCTAssertEqual(WidgetImages.veil(for: plain(.black)), 0.25, accuracy: 0.01)
        XCTAssertEqual(WidgetImages.veil(for: plain(.white)), 0.55, accuracy: 0.01)
        XCTAssertLessThan(WidgetImages.veil(for: plain(UIColor(white: 0.3, alpha: 1))), WidgetImages.veil(for: plain(UIColor(white: 0.7, alpha: 1))))
    }
}
