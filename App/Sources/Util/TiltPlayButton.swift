import SwiftUI
import CoreMotion

/// Glass play button that tilts a little toward the finger (and, more
/// gently, with the device), with a light sweep that crosses it every few
/// seconds so it reads as the thing to press.
///
/// Energy: nothing animates between sweeps; the sweep itself is a single
/// 1.1 s animation every 4 s. Motion updates run at 20 Hz only while the
/// page is on screen with no video playing over it, and re-render the
/// button only when the tilt visibly changes.
struct TiltPlayButton: View {
    let title: String
    var subtitle: String? = nil
    var icon: String = "play.fill"
    var shimmer: Bool = true
    let action: () -> Void

    @State private var tilt = CGSize.zero          // -1…1
    @State private var pressed = false
    @State private var size = CGSize(width: 160, height: 56)
    @State private var sweep: CGFloat = -1         // -1 (off left) … 1 (off right)
    @State private var glow: CGFloat = 0
    @StateObject private var motion = MotionTilt()

    private let maxDegrees: CGFloat = 6            // small: the button must still read as a button
    private let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)

    var body: some View {
        let tx = tilt.width + motion.tilt.width * 0.35
        let ty = tilt.height + motion.tilt.height * 0.35
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 20, weight: .bold))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline).lineLimit(1)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1) }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 26).frame(height: 56)
        .background {
            ZStack {
                shape.fill(Theme.gradient)
                // Moving highlight = the parallax layer.
                shape.fill(LinearGradient(colors: [.white.opacity(0.42), .clear, .white.opacity(0.08)],
                                          startPoint: UnitPoint(x: 0.5 - tx * 0.5, y: 0.5 - ty * 0.6),
                                          endPoint: UnitPoint(x: 0.5 + tx * 0.5 + 0.4, y: 0.5 + ty * 0.6 + 0.6)))
                // The sweep: a soft diagonal band that crosses the face.
                if shimmer {
                    GeometryReader { g in
                        let w = g.size.width
                        Rectangle()
                            .fill(LinearGradient(colors: [.clear, .white.opacity(0.55), .white.opacity(0.9), .white.opacity(0.55), .clear],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: w * 0.45, height: g.size.height * 2.4)
                            .rotationEffect(.degrees(22))
                            .offset(x: sweep * w * 1.1 + w * 0.28, y: -g.size.height * 0.7)
                            .blendMode(.plusLighter)
                            .opacity(0.55)
                    }
                    .clipShape(shape)
                }
                shape.strokeBorder(.white.opacity(0.35), lineWidth: 1)
            }
        }
        .background {
            // Glow that breathes with the sweep (blurred once; only its opacity animates).
            shape.fill(Theme.accent).blur(radius: 18).opacity(0.25 + glow * 0.45).padding(-4)
        }
        .shadow(color: Theme.accent.opacity(0.35), radius: pressed ? 6 : 14, x: -tx * 6, y: 6 - ty * 6)
        .scaleEffect(pressed ? 0.97 : 1)
        .rotation3DEffect(.degrees(-ty * maxDegrees), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
        .rotation3DEffect(.degrees(tx * maxDegrees), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
        .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.7), value: tilt)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: pressed)
        .animation(.easeOut(duration: 0.2), value: motion.tilt)
        .contentShape(shape)
        .background(GeometryReader { g in Color.clear.onAppear { size = g.size } })
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { v in
                    pressed = true
                    tilt = CGSize(width: min(1, max(-1, (v.location.x / max(size.width, 1) - 0.5) * 2)),
                                  height: min(1, max(-1, (v.location.y / max(size.height, 1) - 0.5) * 2)))
                }
                .onEnded { v in
                    pressed = false
                    tilt = .zero
                    if hypot(v.translation.width, v.translation.height) < 12 {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        action()
                    }
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("heroPlay")
        .onAppear { motion.start() }
        .onDisappear { motion.stop() }
        .task { await runShimmer() }
    }

    private func runShimmer() async {
        guard shimmer else { return }
        try? await Task.sleep(nanoseconds: 1_200_000_000)   // let the page settle first
        while !Task.isCancelled {
            // Skip the sweep while a video plays over the page or the app is inactive:
            // nobody sees it and it would wake the display pipeline for nothing.
            if PlayerPresenter.current == nil, UIApplication.shared.applicationState == .active {
                sweep = -1
                withAnimation(.easeInOut(duration: 1.1)) { sweep = 1 }
                withAnimation(.easeInOut(duration: 0.55)) { glow = 1 }
                try? await Task.sleep(nanoseconds: 550_000_000)
                withAnimation(.easeInOut(duration: 0.7)) { glow = 0 }
                try? await Task.sleep(nanoseconds: 3_600_000_000)
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
            let dr = m.attitude.roll - (base?.roll ?? 0), dp = m.attitude.pitch - (base?.pitch ?? 0)
            let t = CGSize(width: min(1, max(-1, dr * 1.6)), height: min(1, max(-1, dp * 1.6)))
            // Only re-render for a visible change.
            if abs(t.width - tilt.width) > 0.03 || abs(t.height - tilt.height) > 0.03 { tilt = t }
        }
    }
    func stop() { wanted = false; pause(); tilt = .zero }
}
