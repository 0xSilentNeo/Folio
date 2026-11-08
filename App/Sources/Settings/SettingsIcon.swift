import SwiftUI

/// A Settings row's tile, as iOS Settings draws them: a filled glyph on a
/// coloured rounded square, growing with Dynamic Type (it stayed 28 pt at
/// every text size until 1.26.1).
struct SettingsIcon: View {
    let symbol: String
    let color: Color
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 29

    init(_ symbol: String, color: Color) {
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        Image(systemName: symbol)
            .symbolVariant(.fill)
            .font(.system(size: side * 0.52, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(color.gradient, in: .rect(cornerRadius: side * 0.225, style: .continuous))
            .accessibilityHidden(true)
    }
}
