import SwiftUI

/// Panel timing, from the Player Controls mockup (claude.ai artifact
/// "Player Controls"): springs as SwiftUI defines them (duration + bounce).
enum PanelMotion {
    static let openDuration = 0.5
    static let openBounce = 0.2
    /// The content fades in once the glass is this far through opening.
    static let contentShowsAt = 0.35
    static let closeDuration = 0.38
    static let closeBounce = 0.05
    /// Panel corner radius when fully open.
    static let radius: CGFloat = 30

    static var open: Animation { .spring(duration: openDuration, bounce: openBounce) }
    static var close: Animation { .spring(duration: closeDuration, bounce: closeBounce) }
}

/// The panels (Tracks, Settings, Now Playing), drawn by the app instead of
/// iOS. Until 1.14 they were system popovers: iOS ran their morph, so its
/// timing couldn't be set, taps were refused until it finished, and the video
/// was frozen during it (a still under the glass) because the glass dropped
/// every frame over moving video.
///
/// Here one glass shape springs from the tapped button's frame to the
/// panel's frame (x, y, width, height and corner radius, as in the mockup)
/// and back. SwiftUI springs can be retargeted at any moment and keep their
/// velocity, so a tap while a panel is moving takes effect at once: it
/// reverses a close, switches panels, or closes an opening one.
struct PanelLayer: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: PlayerUIState
    /// Size of the player's coordinate space ("player").
    let area: CGSize
    let compact: Bool
    let onLoadSubtitle: () -> Void
    let onRotationLock: (Bool) -> Void
    @ObservedObject private var tune = UITune.shared

    /// The panel on screen: stays set through its closing animation.
    @State private var shown: PlayerUIState.Panel?
    @State private var glass = CGRect.zero
    @State private var radius: CGFloat = 23
    @State private var glassOpacity = 0.0
    @State private var contentOpacity = 0.0
    /// Each panel's content height, measured on its first layout.
    @State private var natural: [PlayerUIState.Panel: CGFloat] = [:]
    @State private var waitingForSize = false
    @State private var generation = 0
    /// This layer's origin in the "player" space the pill reports in.
    @State private var origin = CGPoint.zero

    var body: some View {
        ZStack {
            if let k = shown {
                let t = target(k)
                MorphGlass(cornerRadius: radius)
                    .frame(width: max(0, glass.width), height: max(0, glass.height))
                    .position(x: glass.midX, y: glass.midY)
                    .opacity(glassOpacity)
                    .allowsHitTesting(false)
                PlayerPanel(kind: k, model: model, ui: ui, width: t.width, maxHeight: maxHeight,
                            onLoadSubtitle: onLoadSubtitle, onRotationLock: onRotationLock, bare: true,
                            onNaturalHeight: { sizeReady(k, $0) })
                    .frame(width: t.width, height: t.height)
                    .position(x: t.midX, y: t.midY)
                    .opacity(contentOpacity)
                    .mask {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .frame(width: max(0, glass.width), height: max(0, glass.height))
                            .position(x: glass.midX, y: glass.midY)
                    }
                    .allowsHitTesting(ui.panel == k)
                    .id(k)
            }
        }
        .frame(width: area.width, height: area.height)
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .named("player")).origin } action: { origin = $0 }
        .onChange(of: ui.panel) { _, new in
            if let new { open(new) } else { close() }
        }
        .onChange(of: area) { _, _ in
            // Rotation: the open panel follows its new place without animating.
            if let k = shown, ui.panel == k { glass = target(k) }
        }
        .onAppear { if let p = ui.panel { open(p) } }
    }

    // MARK: Geometry

    private var panelWidth: CGFloat {
        compact ? max(240, area.width - 32) : min(tune.panelMax, max(280, area.width * tune.panelWidth))
    }

    /// The whole pill (the three buttons), in the player's coordinate space.
    private var pill: CGRect? {
        let frames = ui.pillFrames.values.filter { $0.width > 0 }.map(local)
        guard var r = frames.first else { return nil }
        for f in frames.dropFirst() { r = r.union(f) }
        return r
    }

    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -origin.x, dy: -origin.y) }

    /// Clear of the close / lock / PiP buttons at the top.
    private var topLimit: CGFloat { 58 }

    private var maxHeight: CGFloat {
        let bottom = (pill?.minY ?? area.height - 60) - 10
        return max(160, bottom - topLimit)
    }

    private func button(_ k: PlayerUIState.Panel) -> CGRect {
        if let f = ui.pillFrames[k], f.width > 0 { return local(f) }
        return CGRect(x: area.width - 60, y: area.height - 60, width: 46, height: 46)
    }

    /// Where the open panel sits: its right edge on the pill's, just above it.
    private func target(_ k: PlayerUIState.Panel) -> CGRect {
        let p = pill ?? button(k)
        let w = min(panelWidth, area.width - 16)
        let h = k == .nowPlaying ? maxHeight : min(natural[k] ?? maxHeight, maxHeight)
        let x = max(8, min(area.width - 8, p.maxX) - w)
        let bottom = p.minY - 10
        return CGRect(x: x, y: max(topLimit, bottom - h), width: w, height: min(h, bottom - topLimit))
    }

    // MARK: Motion

    private func open(_ k: PlayerUIState.Panel) {
        generation += 1
        if shown == nil {
            // From the button: start there, glass and content invisible.
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) {
                let b = button(k)
                glass = b; radius = b.height / 2; glassOpacity = 0; contentOpacity = 0
                shown = k
            }
        } else if shown != k {
            // Switching: the glass moves on from wherever it is now.
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { contentOpacity = 0; shown = k }
        }
        dlog("ui", "panel \(k.rawValue): open")
        if natural[k] != nil || k == .nowPlaying { animateOpen(k) } else { waitingForSize = true }
    }

    private func animateOpen(_ k: PlayerUIState.Panel) {
        waitingForSize = false
        let gen = generation
        // Next turn of the run loop, so the start state above is on screen first.
        DispatchQueue.main.async {
            guard gen == generation, ui.panel == k else { return }
            withAnimation(.easeOut(duration: 0.08)) { glassOpacity = 1 }
            withAnimation(PanelMotion.open) { glass = target(k); radius = PanelMotion.radius }
            withAnimation(.easeOut(duration: 0.2).delay(PanelMotion.openDuration * PanelMotion.contentShowsAt)) { contentOpacity = 1 }
        }
    }

    private func close() {
        guard let k = shown else { return }
        generation += 1
        let gen = generation
        waitingForSize = false
        dlog("ui", "panel \(k.rawValue): close")
        let b = button(k)
        withAnimation(.easeOut(duration: 0.12)) { contentOpacity = 0 }
        withAnimation(PanelMotion.close, completionCriteria: .logicallyComplete) {
            glass = b; radius = b.height / 2
        } completion: {
            if gen == generation, ui.panel == nil { shown = nil }
        }
        // The glass melts into the button over the last part of the close.
        withAnimation(.easeIn(duration: 0.12).delay(PanelMotion.closeDuration * 0.6)) { glassOpacity = 0 }
    }

    private func sizeReady(_ k: PlayerUIState.Panel, _ h: CGFloat) {
        let old = natural[k]
        guard old == nil || abs((old ?? 0) - h) > 0.5 else { return }
        natural[k] = h
        if waitingForSize, shown == k, ui.panel == k {
            animateOpen(k)
        } else if old != nil, shown == k, ui.panel == k {
            // Content changed height while open (a track list arriving).
            withAnimation(.spring(duration: 0.35, bounce: 0.1)) { glass = target(k) }
        }
    }
}

/// The panel's glass. Corner radius interpolated frame by frame (Animatable),
/// so the circle-to-card change is smooth rather than a jump.
struct MorphGlass: View, Animatable {
    var cornerRadius: CGFloat
    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }

    private var fallback: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}

/// The three panel buttons on one glass capsule. Each reports its frame in
/// the player's coordinate space: the panel grows out of it, and a tap there
/// while a panel is open switches to that panel.
struct PanelPill: View {
    @ObservedObject var ui: PlayerUIState
    let ns: Namespace.ID

    struct Item: Identifiable { let id: PlayerUIState.Panel; let icon: String; let title: String }
    static let items: [Item] = [
        Item(id: .tracks, icon: "switch.2", title: "Tracks"),
        Item(id: .settings, icon: "slider.horizontal.3", title: "Settings"),
        Item(id: .nowPlaying, icon: "list.bullet", title: "Now Playing"),
    ]

    var body: some View {
        GlassGroup(unionID: "panels", ns: ns) {
            ForEach(Self.items) { item in
                PillIcon(item.icon, size: 17, active: ui.panel == item.id, unionID: "panels", ns: ns) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    ui.toggle(item.id)
                }
                .accessibilityLabel(item.title)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("player")) } action: { ui.pillFrames[item.id] = $0 }
            }
        }
    }
}
