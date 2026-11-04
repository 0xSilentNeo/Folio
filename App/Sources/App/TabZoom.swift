import SwiftUI

/// "Zoom between tabs" (Settings → General; 1.22.4, an experiment): the
/// page you switch to grows into place from a little smaller as it fades
/// in. A tab view swaps its pages at once, so only the new page can move,
/// and only once it's on screen (started from the tab's selection, the
/// animation ran while the page was still hidden: simulator recording).
/// With Reduce Motion it only fades. Not on the app's first page at launch.
struct TabZoom: ViewModifier {
    @AppStorage(SettingsKey.tabZoom) private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = true
    @State private var shownBefore = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(on && !settled && !reduceMotion ? 0.92 : 1)
            .opacity(on && !settled ? 0 : 1)
            .onAppear {
                defer { shownBefore = true }
                guard on, shownBefore else { return }
                settled = false
                DispatchQueue.main.async {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.85)) { settled = true }
                }
            }
    }
}

extension View {
    func tabZoom() -> some View { modifier(TabZoom()) }
}
