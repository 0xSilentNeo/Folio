import SwiftUI

/// Startup animation (like YouTube's): the app icon's glass tile springs in,
/// the pink play triangle pops onto it with a glow, then the tile zooms past
/// the viewer and fades, revealing Home — which is already loading underneath.
/// iOS only allows a still launch screen, so this runs on the first frame,
/// on the same background colour, so the hand-off is invisible.
struct LaunchSplash: View {
    let done: () -> Void
    @State private var phase = 0          // 0 start · 1 tile in · 2 play in · 3 out
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
            RadialGradient(colors: [Theme.accent.opacity(phase >= 2 ? 0.28 : 0), .clear], center: .center, startRadius: 10, endRadius: 260)
                .ignoresSafeArea()
            ZStack {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(.white.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center)))
                    .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).strokeBorder(.white.opacity(0.28), lineWidth: 1.2))
                    .frame(width: 128, height: 128)
                Image(systemName: "play.fill")
                    .font(.system(size: 54, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .shadow(color: Theme.accent.opacity(0.8), radius: phase >= 2 ? 18 : 0)
                    .offset(x: 4)
                    .scaleEffect(phase >= 2 ? 1 : 0.2)
                    .opacity(phase >= 2 ? 1 : 0)
                    .rotationEffect(.degrees(phase >= 2 ? 0 : -25))
            }
            .scaleEffect(phase == 0 ? 0.55 : (phase == 3 ? 7 : 1))
            .opacity(phase == 0 ? 0 : (phase == 3 ? 0 : 1))
            .blur(radius: phase == 3 ? 6 : 0)
        }
        .opacity(phase == 3 ? 0 : 1)
        .allowsHitTesting(false)
        .task {
            if reduceMotion {
                phase = 2
                try? await Task.sleep(nanoseconds: 350_000_000)
                withAnimation(.easeOut(duration: 0.25)) { phase = 3 }
                try? await Task.sleep(nanoseconds: 260_000_000)
                done(); return
            }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.66)) { phase = 1 }
            try? await Task.sleep(nanoseconds: 220_000_000)
            withAnimation(.spring(response: 0.38, dampingFraction: 0.55)) { phase = 2 }
            try? await Task.sleep(nanoseconds: 520_000_000)
            withAnimation(.easeIn(duration: 0.32)) { phase = 3 }
            try? await Task.sleep(nanoseconds: 340_000_000)
            done()
        }
    }
}
