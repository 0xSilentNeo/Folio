import SwiftUI

/// Logs where a scroll view is scrolled to whenever it moves (LibTrace, iOS 18
/// and later): which of the scrolls on opening Now Playing took (1.26.3 lab).
struct ScrollOffsetTrace: ViewModifier {
    let label: String

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Int.self) { Int($0.contentOffset.y.rounded()) } action: { old, new in
                // One line once the scroll rests (0.90.0): it logged every frame.
                LibTrace.scrolled(label, from: old, to: new)
            }
        } else {
            content
        }
    }
}
