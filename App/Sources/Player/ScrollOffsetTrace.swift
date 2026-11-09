import SwiftUI

/// Logs where a scroll view is scrolled to whenever it moves (LibTrace, iOS 18
/// and later): which of the scrolls on opening Now Playing took (1.26.3 lab).
struct ScrollOffsetTrace: ViewModifier {
    let label: String

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Int.self) { Int($0.contentOffset.y.rounded()) } action: { old, new in
                guard LibTrace.on else { return }
                LibTrace.panel.log("\(label) offset \(old) → \(new)")
            }
        } else {
            content
        }
    }
}
