import SwiftUI
import CoreMotion

/// Pill-shaped play button with depth: it tilts toward the finger and with
/// the phone, a highlight slides across it opposite the tilt, and every few
/// seconds it rocks gently while a band of light sweeps over it.
///
/// Energy: nothing animates between sweeps (one ~1 s animation every ~4.5 s).
/// Motion updates run at 20 Hz only while the page is on screen with no video
/// over it, and re-render the button only when the tilt visibly changes.
struct TiltPlayButton: View {
    let title: String
    var subtitle: String? = nil
    var icon: String = "play.fill"
    var shimmer: Bool = true
    let action: () -> Void

    /// -1…1, where the finger is on the button. A gesture state resets itself
    /// when the touch ends or is taken by another gesture (the back swipe).
    @GestureState private var touch = CGSize.zero
    @State private var size = CGSize(width: 160, height: 56)
    @State private var sweep: CGFloat = -1         // -1 (off left) … 1 (off right)
    @State private var rock: CGFloat = 0           // -1…1, the idle rock that goes with the sweep
    @StateObject private var motion = MotionTilt()

    /// Degrees at full tilt. The finger and the idle rock use all of it; the
    /// phone's own movement up to ~70% (it is always moving a little).
    private let maxDegrees: CGFloat = 6

    /// A real Button decides what counts as a tap (1.16.1). Until 1.16.0 a
    /// drag gesture played whenever a touch on the button ended having moved
    /// under 12 pt — including a back swipe that started on it: the page went
    /// back and the title played (7 times in the device log, 1.14.1–1.15.1).
    /// The tilt only follows the finger now; it never plays anything.
    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 20, weight: .bold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Theme.onAccent.opacity(0.75)).lineLimit(1) }
                }
            }
        }
        .buttonStyle(FaceStyle { label, pressed in AnyView(face(label, pressed: pressed)) })
        .simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .updating($touch) { v, state, _ in
                    state = CGSize(width: clamp((v.location.x / max(size.width, 1) - 0.5) * 2),
                                   height: clamp((v.location.y / max(size.height, 1) - 0.5) * 2))
                }
        )
        .accessibilityIdentifier("heroPlay")
        .onAppear { motion.start() }
        .onDisappear { motion.stop() }
        .task { await runShimmer() }
    }

    private struct FaceStyle: ButtonStyle {
        let render: (ButtonStyleConfiguration.Label, Bool) -> AnyView
        func makeBody(configuration: Configuration) -> some View { render(configuration.label, configuration.isPressed) }
    }

    private func face(_ label: ButtonStyleConfiguration.Label, pressed: Bool) -> some View {
        let tx = clamp(touch.width + motion.tilt.width * 0.7 + rock)
        let ty = clamp(touch.height + motion.tilt.height * 0.7)
        let shape = Capsule(style: .continuous)
        return label
            .foregroundStyle(Theme.onAccent)
            .shadow(color: Theme.labelEmboss, radius: 1, x: -tx * 1.5, y: 1 - ty * 1.5)   // label floats above the face
            .padding(.horizontal, 26).frame(height: 56)
            .background {
                ZStack {
                    shape.fill(Theme.gradient)
                    // A soft top-edge sheen that shifts a little with the tilt (no
                    // bright spot: the 1.13.0 highlight washed out the label).
                    shape.fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.0)],
                                              startPoint: UnitPoint(x: 0.5 - tx * 0.3, y: 0),
                                              endPoint: UnitPoint(x: 0.5 + tx * 0.3, y: 0.55)))
                    // The sweep: a soft diagonal band of light crossing the face.
                    if shimmer {
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
            .animation(.easeOut(duration: 0.25), value: motion.tilt)
            .contentShape(shape)
            .background(GeometryReader { g in Color.clear.onAppear { size = g.size } })
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

/// Device attitude → small tilt offset, for the parallax on the play button.
@MainActor
final class MotionTilt: ObservableObject {
    @Published var tilt = CGSize.zero
    private let manager = CMMotionManager()
    private var base: (roll: Double, pitch: Double)?
    private var wanted = false
    private var observers: [NSObjectProtocol] = []

    init() {
        // Motion updates re-render the button: pause them while a video plays
        // (the page is still alive under the player) or the app is inactive.
        let nc = NotificationCenter.default
        for (name, on) in [(Notification.Name.playerWillShow, false), (.playerDidHide, true),
                           (UIApplication.willResignActiveNotification, false), (UIApplication.didBecomeActiveNotification, true)] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if on, self.wanted, PlayerPresenter.current == nil { self.begin() } else if !on { self.pause() }
                }
            })
        }
    }

    func start() {
        wanted = true
        guard PlayerPresenter.current == nil else { return }
        begin()
    }

    private func pause() { manager.stopDeviceMotionUpdates(); base = nil }

    private func begin() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 20
        manager.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let self, let m else { return }
            if base == nil { base = (m.attitude.roll, m.attitude.pitch) }
            // Drift the rest position toward how the phone is held now, so after
            // you settle into a new grip the button comes back level.
            if let b = base { base = (b.roll + (m.attitude.roll - b.roll) * 0.02, b.pitch + (m.attitude.pitch - b.pitch) * 0.02) }
            let dr = m.attitude.roll - (base?.roll ?? 0), dp = m.attitude.pitch - (base?.pitch ?? 0)
            let t = CGSize(width: min(1, max(-1, dr * 4.5)), height: min(1, max(-1, dp * 4.5)))   // full tilt at ~13° of phone rotation
            // Only re-render for a visible change.
            if abs(t.width - tilt.width) > 0.03 || abs(t.height - tilt.height) > 0.03 { tilt = t }
        }
    }
    func stop() { wanted = false; pause(); tilt = .zero }
}
