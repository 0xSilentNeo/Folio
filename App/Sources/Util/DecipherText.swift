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
