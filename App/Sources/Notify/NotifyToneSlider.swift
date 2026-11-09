import SwiftUI

/// Settings → Notifications → Personality (1.26.3): one slider from Subtle to
/// Unhinged over a notification worded in the tone it's on, so a stop shows
/// what it changes. It was three rows of a checkmark list.
struct NotifyToneSlider: View {
    @Binding var tone: String
    @State private var position = 1.0

    private static let tones = NotifyTone.allCases
    private var current: NotifyTone { NotifyTone(rawValue: tone) ?? .balanced }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NotifyPreviewBanner(tone: current)

            VStack(spacing: 8) {
                Slider(value: $position, in: 0...Double(Self.tones.count - 1), step: 1) {
                    Text("Personality")
                }
                .accessibilityValue("\(current.title): \(current.subtitle)")
                .accessibilityIdentifier("notifyTone")

                // The stops by name, each a shortcut to itself (VoiceOver has the slider).
                HStack(spacing: 0) {
                    ForEach(Self.tones) { t in
                        Button {
                            withAnimation(.snappy) { position = Double(Self.index(t)) }
                        } label: {
                            Text(t.title)
                                .font(.footnote.weight(t == current ? .semibold : .regular))
                                // Absolute colours: .secondary inside a button is the tint's.
                                .foregroundStyle(t == current ? Theme.action : Color.secondary)
                                .frame(maxWidth: .infinity, alignment: Self.alignment(t))
                                .contentShape(.rect)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 8)
        .onAppear { position = Double(Self.index(current)) }
        .onChange(of: position) { _, p in
            let t = Self.tones[min(Self.tones.count - 1, max(0, Int(p.rounded())))]
            if t.rawValue != tone { tone = t.rawValue }
        }
        .onChange(of: tone) { position = Double(Self.index(current)) }
        .sensoryFeedback(.selection, trigger: tone)
    }

    private static func index(_ t: NotifyTone) -> Int { tones.firstIndex(of: t) ?? 1 }

    private static func alignment(_ t: NotifyTone) -> Alignment {
        switch index(t) {
        case 0: .leading
        case tones.count - 1: .trailing
        default: .center
        }
    }
}
