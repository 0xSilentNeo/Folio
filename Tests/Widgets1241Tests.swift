import SwiftUI
import WidgetKit
import XCTest
@testable import Folio

/// 1.24.1: the widgets' looks (glass in light mode, tinted in dark, iOS's
/// accented mode for Clear and Tinted) and the pictures they're made of.
final class Widgets1241Tests: XCTestCase {
    func testEachAppearanceGetsItsLook() {
        XCTAssertEqual(WidgetPalette(scheme: .light, mode: .fullColor).kind, .glass)
        XCTAssertEqual(WidgetPalette(scheme: .dark, mode: .fullColor).kind, .tinted)
        XCTAssertEqual(WidgetPalette(scheme: .light, mode: .accented).kind, .accented)
        XCTAssertEqual(WidgetPalette(scheme: .dark, mode: .accented).kind, .accented)
        XCTAssertEqual(WidgetPalette(scheme: .dark, mode: .vibrant).kind, .accented)
        XCTAssertTrue(WidgetPalette(scheme: .light, mode: .accented).accented)
        XCTAssertFalse(WidgetPalette(scheme: .light, mode: .fullColor).accented)
    }

    func testTheGlassIsMadeFromTheArtwork() throws {
        let art = UIGraphicsImageRenderer(size: CGSize(width: 540, height: 304)).image { ctx in
            UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 540, height: 304))
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 270, height: 304))
        }
        let soft = try XCTUnwrap(WidgetImages.softened(art))
        XCTAssertEqual(soft.size.width * soft.scale, 64)
        XCTAssertEqual(soft.size.height * soft.scale, 64)
        // Generated art is the same picture for the same title, and there is always a wallpaper.
        XCTAssertTrue(WidgetImages.generated("Lab Show") === WidgetImages.generated("Lab Show"))
        XCTAssertGreaterThan(WidgetImages.wallpaper("").size.width, 0)
    }

    func testTheScrimsAreDarkAtTheirEdge() throws {
        let bottom = try XCTUnwrap(WidgetImages.scrimBottom.cgImage)
        let leading = try XCTUnwrap(WidgetImages.scrimLeading.cgImage)
        XCTAssertGreaterThan(alpha(bottom, x: 1, y: bottom.height - 1), alpha(bottom, x: 1, y: 2))
        XCTAssertGreaterThan(alpha(leading, x: 1, y: 1), alpha(leading, x: leading.width - 2, y: 1))
    }

    private func alpha(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return px[3]
    }
}
