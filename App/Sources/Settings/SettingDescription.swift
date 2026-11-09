import SwiftUI

/// A setting's text under its group (SettingGroup). Collapsed, a long one shows
/// two lines, the second fading out under "more"; expanded, all of it and
/// "less". A tap anywhere on it switches (as YouTube's descriptions do); short
/// text shows whole and takes no taps. SettingGroup swaps the two as separate
/// rows, so the List slides what's below.
struct SettingDescription: View {
    let text: String
    let expanded: Bool
    let toggle: () -> Void
    private let lines = 2
    /// The whole text's height, and two lines' (measured unseen at the same width).
    @State private var fullHeight: CGFloat = 0
    @State private var cutHeight: CGFloat = 0
    /// Tapped: "more" or "less" goes at once, so only the same words cross-fade
    /// while SettingGroup swaps the rows (it lingered over the text).
    @State private var leaving = false

    init(_ text: String, expanded: Bool, toggle: @escaping () -> Void) {
        self.text = text
        self.expanded = expanded
        self.toggle = toggle
    }

    private var cut: Bool { fullHeight > cutHeight + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : lines)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .mask { if !expanded { fade } else { Rectangle() } }
                .background(alignment: .topLeading) { measures }
                .overlay(alignment: .bottomTrailing) {
                    if cut && !expanded { label("more").opacity(leaving ? 0 : 1) }
                }
            if expanded && cut { label("less").opacity(leaving ? 0 : 1) }
        }
        .contentShape(.rect)
        .onTapGesture {
            guard cut || expanded else { return }
            leaving = true
            DispatchQueue.main.async { toggle() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(cut || expanded ? .isButton : [])
        .accessibilityHint(cut || expanded ? (expanded ? "Shows less" : "Shows all of it") : "")
    }

    private func label(_ s: LocalizedStringKey) -> some View {
        Text(s).font(.footnote.weight(.semibold)).foregroundStyle(Theme.action)
    }

    /// The last line fades out by where "more" sits, instead of an ellipsis.
    private var fade: some View {
        let line = cutHeight / CGFloat(lines)
        return VStack(spacing: 0) {
            Rectangle().frame(height: max(0, cutHeight - line))
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(stops: [.init(color: .black, location: 0),
                                       .init(color: .black.opacity(cut ? 0 : 1), location: 0.5)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 100)
            }
            .frame(height: line)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var measures: some View {
        ZStack(alignment: .topLeading) {
            Text(text).font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
            Text(text).font(.footnote).lineLimit(lines)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cutHeight = $0 }
        }
        .hidden()
        .accessibilityHidden(true)
    }
}
