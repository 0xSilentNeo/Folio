import SwiftUI

/// A description that shows its first two lines, the second fading out under
/// "more"; a tap anywhere on it opens the rest, and another closes it (as
/// YouTube's descriptions do). Short text shows whole and takes no taps.
///
/// 1.26.3: the whole text is always laid out and only its visible height
/// animates, so it slides open and shut. Until then More switched the
/// text's line limit, and the text jumped to its new height.
struct SettingDescription: View {
    let text: String
    var lines = 2
    @State private var expanded = false
    /// The whole text's height, and `lines` lines' (measured unseen at the same width).
    @State private var fullHeight: CGFloat = 0
    @State private var cutHeight: CGFloat = 0

    init(_ text: String, lines: Int = 2) {
        self.text = text
        self.lines = lines
    }

    private var cut: Bool { fullHeight > cutHeight + 1 }

    private var visibleHeight: CGFloat? {
        guard fullHeight > 0 else { return nil }
        return expanded || !cut ? fullHeight : cutHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The footer's own grey (another .secondary on it made it lighter than iOS's).
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: visibleHeight, alignment: .top)
                .clipped()
                .mask { fade }
                .background(alignment: .topLeading) { measures }
                .overlay(alignment: .bottomTrailing) {
                    if cut && !expanded {
                        Text("more").font(.footnote.weight(.semibold)).foregroundStyle(Theme.action)
                            .transition(.opacity)
                    }
                }
            if cut && expanded {
                Text("less").font(.footnote.weight(.semibold)).foregroundStyle(Theme.action)
                    .transition(.opacity)
            }
        }
        .contentShape(.rect)
        .onTapGesture {
            guard cut else { return }
            withAnimation(.smooth(duration: 0.35)) { expanded.toggle() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(cut ? .isButton : [])
        .accessibilityHint(cut ? (expanded ? "Shows less" : "Shows all of it") : "")
    }

    /// The last line fades out by where "more" sits, instead of an ellipsis.
    private var fade: some View {
        let line = cutHeight / CGFloat(lines)
        let fading = cut && !expanded
        return VStack(spacing: 0) {
            Rectangle().frame(height: max(0, (visibleHeight ?? 0) - line))
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(stops: [.init(color: .black, location: 0),
                                       .init(color: .black.opacity(fading ? 0 : 1), location: 0.5)],
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
