import SwiftUI

/// Pill-shaped play button with depth: it tilts toward the finger, a
/// highlight slides across it opposite the tilt, and every few seconds it
/// rocks gently while a band of light sweeps over it.
///
/// Energy: nothing animates between sweeps (one ~1 s animation every ~4.5 s).
/// 1.28.8: it no longer tilts with the phone. That kept the motion sensor
/// running at 15 Hz on every title page for as long as it was on screen.
struct TiltPlayButton: View {
    let title: String
    var subtitle: String? = nil
    var icon: String = "play.fill"
    var shimmer: Bool = true
    let action: () -> Void

    /// -1…1, where the finger is on the button. Gesture states reset themselves
    /// when the touch ends or is taken by another gesture.
    @GestureState private var touch = CGSize.zero
    @GestureState private var pressed = false
    @State private var size = CGSize(width: 160, height: 56)
    @State private var sweep: CGFloat = -1         // -1 (off left) … 1 (off right)
    @State private var rock: CGFloat = 0           // -1…1, the idle rock that goes with the sweep
    /// For the tap's haptic (1.28.8: SwiftUI's own, in place of UIKit's generator).
    @State private var taps = 0
    /// Reduce Motion (1.27.0): no tilt with the phone, no 3D turn, no sweep
    /// or rock; a plain press.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .headline) private var height: CGFloat = 56

    /// Degrees at full tilt. The finger and the idle rock use all of it; the
    /// phone's own movement up to ~70% (it is always moving a little).
    private let maxDegrees: CGFloat = 6

    var body: some View {
        face
            // The tilt follows the finger, in the button's own coordinates.
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .updating($touch) { v, state, _ in
                        state = CGSize(width: clamp((v.location.x / max(size.width, 1) - 0.5) * 2),
                                       height: clamp((v.location.y / max(size.height, 1) - 0.5) * 2))
                    }
                    .updating($pressed) { _, state, _ in state = true }
            )
            // Whether it was a tap is measured on the screen (1.16.1). Until
            // 1.16.0 it was measured in the button's own coordinates: a back swipe
            // moves the page — and this button — along with the finger, so the
            // finger hardly moved relative to the button, the swipe counted as a
            // tap, and the title played while its page went back (7 times in the
            // device log, 1.14.1–1.15.1). On the screen the finger did move.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onEnded { v in
                        guard hypot(v.translation.width, v.translation.height) < 12 else { return }
                        taps += 1
                        action()
                    }
            )
            .sensoryFeedback(.impact(weight: .medium), trigger: taps)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            // VoiceOver's activation: the button plays on a drag's end otherwise.
            .accessibilityAction { action() }
            .accessibilityIdentifier("heroPlay")
            .task(id: reduceMotion) { if !reduceMotion { await runShimmer() } }
    }

    private var face: some View {
        let tx = reduceMotion ? 0 : clamp(touch.width + rock)
        let ty = reduceMotion ? 0 : clamp(touch.height)
        let shape = Capsule(style: .continuous)
        return HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 20, weight: .bold))
            VStack(alignment: .leading, spacing: 1) {
                // Two lines at large text sizes rather than cut ("Resume / from 1:02:13").
                Text(title).font(.headline).lineLimit(2).minimumScaleFactor(0.9)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Theme.onAccent.opacity(0.75)).lineLimit(2) }
            }
        }
        .foregroundStyle(Theme.onAccent)
        .shadow(color: Theme.labelEmboss, radius: 1, x: -tx * 1.5, y: 1 - ty * 1.5)   // label floats above the face
        // At least 56 pt, growing with the text (it was a fixed 56).
        .padding(.horizontal, 26).padding(.vertical, 6).frame(minHeight: height)
        .background {
            ZStack {
                shape.fill(Theme.gradient)
                // A soft top-edge sheen that shifts a little with the tilt (no
                // bright spot: the 1.13.0 highlight washed out the label).
                shape.fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.0)],
                                          startPoint: UnitPoint(x: 0.5 - tx * 0.3, y: 0),
                                          endPoint: UnitPoint(x: 0.5 + tx * 0.3, y: 0.55)))
                // The sweep: a soft diagonal band of light crossing the face.
                if shimmer && !reduceMotion {
                    GeometryReader { g in
                        let w = g.size.width
                        Rectangle()
                            .fill(LinearGradient(colors: [.clear, .white.opacity(0.28), .clear],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: w * 0.3, height: g.size.height * 2.4)
                            .rotationEffect(.degrees(22))
                            .offset(x: sweep * w * 1.1 + w * 0.35, y: -g.size.height * 0.7)
                    }
                }
                // Rim: brighter on the edge facing the light.
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.12)],
                                                  startPoint: UnitPoint(x: 0.5 - tx, y: 0 - ty), endPoint: UnitPoint(x: 0.5 + tx, y: 1 + ty)),
                                   lineWidth: 1.2)
            }
            .clipShape(shape)
            // Depth shadow under the capsule, shifting with the tilt.
            .shadow(color: Theme.shadow.opacity(pressed ? 0.6 : 1), radius: pressed ? 4 : 9, x: -tx * 6, y: 6 - ty * 5)
        }
        .scaleEffect(pressed ? 0.96 : 1)
        .rotation3DEffect(.degrees(-ty * maxDegrees), axis: (x: 1, y: 0, z: 0), perspective: 1)
        .rotation3DEffect(.degrees(tx * maxDegrees), axis: (x: 0, y: 1, z: 0), perspective: 1)
        .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.7), value: touch)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: pressed)
        .contentShape(shape)
        // Its size now, not only the one it appeared with (1.30.2).
        .background(GeometryReader { g in Color.clear.onAppear { size = g.size }.onChange(of: g.size) { _, new in size = new } })
    }

    private func clamp(_ v: CGFloat) -> CGFloat { min(1, max(-1, v)) }

    /// Every ~4.5 s: the button rocks to one side and back while a band of
    /// light sweeps across it. Nothing runs in between,
    /// nor while a video plays over the page or the app is in the background.
    private func runShimmer() async {
        guard shimmer else { return }
        try? await Task.sleep(nanoseconds: 700_000_000)     // let the page settle first
        var side: CGFloat = 1
        while !Task.isCancelled {
            if PlayerPresenter.current == nil, UIApplication.shared.applicationState == .active {
                sweep = -1
                withAnimation(.easeInOut(duration: 1.0)) { sweep = 1 }
                withAnimation(.easeInOut(duration: 0.5)) { rock = 0.6 * side }
                try? await Task.sleep(nanoseconds: 500_000_000)
                withAnimation(.spring(response: 0.7, dampingFraction: 0.5)) { rock = 0 }
                side = -side
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            } else {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
