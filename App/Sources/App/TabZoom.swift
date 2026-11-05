import SwiftUI

/// "Zoom between tabs" (Settings → General; 1.22.4, an experiment): the
/// page you switch to settles into place from a little larger, so it looks
/// as if it comes up to you. A tab view swaps its pages at once, so only
/// the new page can move, and only once it's on screen (started from the
/// tab's selection, the animation ran while the page was still hidden).
///
/// 1.22.5: from larger, not smaller, and without fading. Shrinking the page
/// showed its edges, the top and bottom of the screen empty for a moment,
/// and fading the whole page made iOS draw it off screen each frame, which
/// stuttered (5 Nov). Nothing with Reduce Motion, nor on the app's first
/// page at launch.
struct TabZoom: ViewModifier {
    @AppStorage(SettingsKey.tabZoom) private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = true
    @State private var shownBefore = false

    /// How much larger the page starts.
    static let from: CGFloat = 1.035

    func body(content: Content) -> some View {
        content
            .scaleEffect(settled ? 1 : Self.from)
            .onAppear {
                defer { shownBefore = true }
                guard on, !reduceMotion, shownBefore else { return }
                settled = false
                DispatchQueue.main.async {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) { settled = true }
                }
            }
    }
}

extension View {
    func tabZoom() -> some View { modifier(TabZoom()) }
}
