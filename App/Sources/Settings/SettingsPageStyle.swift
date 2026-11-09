import SwiftUI

extension View {
    /// What every Settings page shares (1.26.1): the page colour behind the
    /// form, buttons and links in the action colour (Theme.action), and a
    /// readable width on a wide window (an iPad, or a phone on its side),
    /// where footers ran 120+ characters to a line.
    func settingsPage() -> some View { modifier(SettingsPageStyle()) }
}

struct SettingsPageStyle: ViewModifier {
    /// The widest a form's rows get.
    static let maxWidth: CGFloat = 680
    @State private var inset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            // Only past the readable width: a margin of 0 would replace the
            // grouped list's own and run the rows edge to edge.
            .contentMargins(.horizontal, inset > 0 ? inset : nil, for: .scrollContent)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                let next = max(0, (width - Self.maxWidth) / 2)
                if abs(next - inset) > 0.5 { inset = next }
            }
            .brandListBackground()
            .tint(Theme.action)
            // A setting's text under its group is a row as tall as the text
            // (SettingGroup), not the 44 pt rows are at least.
            .environment(\.defaultMinListRowHeight, 1)
    }
}
