import SwiftUI

/// Startup animation. iOS shows a still launch screen first (the leaf alone,
/// centred, on the palette background: `LaunchMark` / `LaunchBackground`);
/// this view starts from exactly that picture, so the hand-off is invisible:
///
/// 1. the page slides in under the leaf and a band of light crosses it,
/// 2. the mark rises and FOLIO gathers in beneath it, letter by letter,
///    with the tagline after it,
/// 3. everything eases forward and fades, revealing Home (already loaded
///    underneath).
struct LaunchSplash: View {
    let done: () -> Void
    @State private var phase = 0          // 0 launch screen · 1 page + sheen · 2 wordmark · 3 out
    @State private var sheen: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    /// Same size as the launch screen's image (96 pt).
    private let mark: CGFloat = 96
    private let letters = Array("FOLIO")

    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
                .opacity(phase == 3 ? 0 : 1)
            ZStack {
                logo
                    .offset(y: phase >= 2 ? -30 : 0)
                VStack(spacing: 10) {
                    HStack(spacing: phase >= 2 ? 9 : 22) {
                        ForEach(letters.indices, id: \.self) { i in
                            Text(String(letters[i]))
                                .font(.custom(Theme.wordmarkFont, size: 26))
                                .opacity(phase >= 2 ? 1 : 0)
                                .animation(.easeOut(duration: 0.35).delay(Double(i) * 0.045), value: phase)
                        }
                    }
                    Text("All your media, together.")
                        .font(.custom(Theme.wordmarkFont, size: 14))
                        .foregroundStyle(.secondary)
                        .opacity(phase >= 2 ? 1 : 0)
                        .offset(y: phase >= 2 ? 0 : 6)
                        .animation(.easeOut(duration: 0.4).delay(0.18), value: phase)
                }
                .offset(y: 62)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Folio")
            }
            .scaleEffect(phase == 3 ? 1.06 : 1)
            .opacity(phase == 3 ? 0 : 1)
        }
        .allowsHitTesting(false)
        .task {
            dlog("app", "launch splash shown")
            await run()
        }
    }

    /// The page with the leaf resting on it, as on the app icon.
    private var logo: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: mark * 0.095, style: .continuous)
                .fill(LinearGradient(colors: scheme == .dark
                                     ? [Color(uiColor: UIColor(hex: 0x24262A)), Color(uiColor: UIColor(hex: 0x17181B))]
                                     : [Color(uiColor: UIColor(hex: 0xF8F5F0)), Color(uiColor: UIColor(hex: 0xE4DDD3))],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: Theme.shadow.opacity(0.7), radius: 5, x: 1, y: 2)
                .frame(width: mark * 0.51, height: mark * 0.548)
                .scaleEffect(phase >= 1 ? 1 : 0.82)          // around the page's own centre
                .opacity(phase >= 1 ? 1 : 0)
                .offset(x: mark * 0.29 - (phase >= 1 ? 0 : mark * 0.08), y: mark * 0.226)
            FolioLeaf()
                .frame(width: mark, height: mark)
                .overlay {
                    // A band of light crossing the leaf, clipped to its shape.
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, .white.opacity(scheme == .dark ? 0.55 : 0.35), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width * 0.35, height: g.size.height * 1.6)
                            .rotationEffect(.degrees(28))
                            .offset(x: sheen * g.size.width * 0.9 + g.size.width * 0.32, y: -g.size.height * 0.3)
                    }
                    .mask(LeafShape())
                }
                .shadow(color: Theme.shadow.opacity(phase >= 1 ? 0.8 : 0), radius: 4, x: 1.5, y: 2)
                .rotationEffect(.degrees(phase >= 1 ? 0 : -5), anchor: UnitPoint(x: 0.27, y: 0.83))
        }
        .frame(width: mark, height: mark)
    }

    private func run() async {
        if reduceMotion {
            phase = 2
            try? await Task.sleep(nanoseconds: 450_000_000)
            withAnimation(.easeOut(duration: 0.25)) { phase = 3 }
            try? await Task.sleep(nanoseconds: 260_000_000)
            done(); return
        }
        try? await Task.sleep(nanoseconds: 60_000_000)
        withAnimation(.spring(duration: 0.55, bounce: 0.25)) { phase = 1 }
        withAnimation(.easeInOut(duration: 0.75)) { sheen = 1 }
        try? await Task.sleep(nanoseconds: 260_000_000)
        withAnimation(.spring(duration: 0.6, bounce: 0.18)) { phase = 2 }
        try? await Task.sleep(nanoseconds: 720_000_000)
        withAnimation(.easeIn(duration: 0.3)) { phase = 3 }
        try? await Task.sleep(nanoseconds: 320_000_000)
        done()
    }
}
