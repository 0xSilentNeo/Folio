import SwiftUI

/// Title text that "deciphers" into place: each character starts as a random
/// glyph and settles to the real one, left to right, over ~0.6 s. Runs once
/// per `text` value; honours Reduce Motion (plain text).
struct DecipherText: View {
    let text: String
    var font: Font = .system(size: 30, weight: .bold, design: .rounded)
    var duration: Double = 0.65
    @State private var shown = ""
    @State private var running = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let glyphs = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789#%&@*+=?")

    var body: some View {
        Text(shown.isEmpty ? text : shown)
            .font(font)
            .monospacedDigit()
            .opacity(shown.isEmpty && !reduceMotion ? 0 : 1)
            .task(id: text) { await run() }
    }

    private func run() async {
        if reduceMotion { shown = text; return }
        let chars = Array(text)
        guard !chars.isEmpty else { shown = text; return }
        running = true
        let steps = 14
        let stepTime = duration / Double(steps)
        for step in 0...steps {
            guard !Task.isCancelled else { return }
            let settled = Int(Double(chars.count) * Double(step) / Double(steps))
            var out: [Character] = []
            out.reserveCapacity(chars.count)
            for (i, c) in chars.enumerated() {
                if i < settled || c == " " || !c.isLetter && !c.isNumber { out.append(c) }
                else { out.append(Self.glyphs.randomElement()!) }
            }
            shown = String(out)
            try? await Task.sleep(nanoseconds: UInt64(stepTime * 1_000_000_000))
        }
        shown = text
        running = false
    }
}

/// Description with a "more" / "less" toggle; collapsed to `lines` lines.
struct ExpandableText: View {
    let text: String
    var lines = 3
    @State private var expanded = false
    @State private var truncatable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.callout).foregroundStyle(.white.opacity(0.85)).lineSpacing(2)
                .lineLimit(expanded ? nil : lines)
                .background(
                    // Measures whether the full text is taller than the limit.
                    Text(text).font(.callout).lineSpacing(2).lineLimit(lines)
                        .background(GeometryReader { limited in
                            Text(text).font(.callout).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                                .background(GeometryReader { full in
                                    Color.clear.onAppear { truncatable = full.size.height > limited.size.height + 1 }
                                        .onChange(of: text) { _, _ in truncatable = full.size.height > limited.size.height + 1 }
                                })
                                .hidden()
                        })
                        .hidden()
                )
            if truncatable {
                Button(expanded ? "less" : "+ more") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { expanded.toggle() }
                }
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
            }
        }
    }
}

/// Lays children out left to right and wraps to a new line when the row is
/// full (chips under a title: never squeezes "1080p" onto two lines).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let sz = v.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > maxW { y += lineH + lineSpacing; x = 0; lineH = 0 }
            x += (x > 0 ? spacing : 0) + sz.width
            lineH = max(lineH, sz.height)
            widest = max(widest, x)
        }
        return CGSize(width: min(widest, maxW), height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for v in subviews {
            let sz = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + sz.width > bounds.maxX { y += lineH + lineSpacing; x = bounds.minX; lineH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
        }
    }
}
