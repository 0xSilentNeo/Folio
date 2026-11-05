import SwiftUI
import UIKit
import WidgetKit

/// The downloads Live Activity's liquid-glass look (1.22.1): kept from the
/// now-playing activity's file when that activity went (1.23.0).

/// The activities' look (1.22.1). The Dynamic Island is always black, so
/// the Lock Screen gets a dark pane too, see-through over the wallpaper:
/// one look in both places, light mode or dark.
enum LiquidGlass {
    static let backdrop = Color.black.opacity(0.42)
    static let secondary = Color.white.opacity(0.66)
    static let track = Color.white.opacity(0.16)
    /// The downloads activity's colour: water.
    static let aqua = Color(red: 0.42, green: 0.86, blue: 0.97)

    /// Width for a compact timer counting `range`: an hour or more needs "1:02:03".
    static func clockWidth(_ range: ClosedRange<Date>?) -> CGFloat {
        guard let range else { return 44 }
        return range.upperBound.timeIntervalSince(range.lowerBound) >= 3600 ? 60 : 44
    }

}

/// A pane of glass: a faint white fill, lighter at the top, and a rim that
/// catches the light at the top left.
struct GlassFill<S: InsettableShape>: View {
    let shape: S

    var body: some View {
        shape
            .fill(LinearGradient(colors: [.white.opacity(0.26), .white.opacity(0.07)], startPoint: .top, endPoint: .bottom))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.06), .white.opacity(0.22)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8))
    }
}

/// A soft light behind the pane's top left, in the activity's colour.
struct Glow: View {
    let color: Color

    var body: some View {
        RadialGradient(colors: [color.opacity(0.5), color.opacity(0.16), color.opacity(0)], center: .topLeading, startRadius: 0, endRadius: 230)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Progress as liquid in a glass tube. With `range` it fills by itself
/// (ProgressView(timerInterval:)), else it shows `progress` still.
struct LiquidBar: View {
    let range: ClosedRange<Date>?
    let progress: Double
    let tint: Color

    var body: some View {
        Group {
            if let range {
                ProgressView(timerInterval: range, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    .progressViewStyle(.linear)
                    .tint(tint)
            } else {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(LiquidGlass.track)
                        Capsule().fill(tint).frame(width: max(4, g.size.width * min(1, max(0, progress))))
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 3)
        .background(GlassFill(shape: Capsule()))
        .accessibilityHidden(true)
    }
}
