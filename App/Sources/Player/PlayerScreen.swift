import SwiftUI
import AVKit
import UniformTypeIdentifiers

/// Player chrome: close / PiP at the top, three Liquid Glass pills at the
/// bottom (transport · progress · panels) and panels that grow out of
/// their buttons. Only `TimeBar` re-renders while a video plays.
struct PlayerScreen: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: PlayerUIState
    var onClose: () -> Void = {}
    var onRotationLock: (Bool) -> Void = { _ in }

    @State private var showSubtitlePicker = false

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 640
            ZStack {
                Color.black.ignoresSafeArea()
                VideoSurface(model: model, ui: ui).ignoresSafeArea()

                if model.isPiPActive {
                    VStack(spacing: 10) {
                        Image(systemName: "pip").font(.system(size: 40, weight: .light))
                        Text("Playing in Picture in Picture").font(.footnote)
                    }
                    .foregroundStyle(.white.opacity(0.55))
                    .allowsHitTesting(false)
                }

                if (model.buffering || model.isLoading) && model.errorMessage == nil {
                    ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
                        .offset(y: ui.controlsVisible && !ui.locked ? -10 : 0)
                }

                if ui.controlsVisible && !ui.locked {
                    controls(geo, compact: compact).transition(.opacity)
                }

                if ui.locked && ui.controlsVisible { lockedOverlay.transition(.opacity) }

                skipButton(geo)

                if model.holdSpeedActive {
                    topPill(Label(String(format: "%g×", model.holdSpeed), systemImage: "forward.fill"), top: geo.safeAreaInsets.top)
                }
                if let hud = ui.gestureHUD {
                    switch hud.kind {
                    case .brightness, .volume:
                        EdgeLevelHUD(hud: hud, size: geo.size, safe: geo.safeAreaInsets)
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    default:
                        GestureHUDView(hud: hud).allowsHitTesting(false)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                if ui.showStats { StatsOverlay(model: model).transition(.opacity) }
                if let toast = model.toast, ui.gestureHUD == nil, !model.holdSpeedActive {
                    topPill(Text(toast), top: geo.safeAreaInsets.top + (ui.controlsVisible ? 56 : 0))
                }

                if let error = model.errorMessage { errorView(error) }
                if model.ended && !model.hasNext && model.errorMessage == nil { endedView }

                if let panel = ui.panel {
                    PlayerPanel(kind: panel, model: model, ui: ui, size: geo.size, safe: geo.safeAreaInsets, compact: compact,
                                onLoadSubtitle: { showSubtitlePicker = true }, onRotationLock: onRotationLock)
                        .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
                }
                if ui.showInfo { InfoCard(model: model, ui: ui).transition(.opacity) }
                if ui.showConsole {
                    ConsoleBar(model: model, ui: ui).transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: ui.controlsVisible)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: ui.gestureHUD)
            .animation(.easeOut(duration: 0.2), value: ui.showStats)
            .animation(.easeOut(duration: 0.18), value: model.toast)
            .animation(.easeOut(duration: 0.18), value: model.holdSpeedActive)
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { ui.scheduleHide() }
        .onChange(of: model.paused) { _, paused in
            if paused { ui.showControls(autoHide: false) } else if ui.panel == nil { ui.scheduleHide() }
        }
        .fileImporter(isPresented: $showSubtitlePicker, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { model.addSubtitle(url: url) }
        }
    }

    // MARK: Controls

    @ViewBuilder
    private func controls(_ geo: GeometryProxy, compact: Bool) -> some View {
        let side = max(16, min(max(geo.safeAreaInsets.leading, geo.safeAreaInsets.trailing), 48))
        VStack(spacing: 0) {
            HStack {
                GlassIcon("xmark", size: 17) { onClose() }
                Spacer()
                if PiPManager.isSupported && UserDefaults.standard.bool(forKey: SettingsKey.pipEnabled) {
                    GlassIcon(model.isPiPActive ? "pip.exit" : "pip.enter", size: 17) {
                        model.isPiPActive ? model.stopPiP() : model.startPiP()
                    }
                    .opacity(model.isPiPPossible || model.isPiPActive ? 1 : 0.35)
                    .disabled(!model.isPiPPossible && !model.isPiPActive)
                }
            }
            .padding(.horizontal, side)
            .padding(.top, 6)
            Spacer()
            if compact {
                VStack(spacing: 10) {
                    TimeBar(model: model, ui: ui, clock: model.clock)
                    HStack {
                        transportPill
                        Spacer()
                        panelPill
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, geo.safeAreaInsets.bottom > 0 ? 4 : 12)
            } else {
                HStack(spacing: 12) {
                    transportPill
                    TimeBar(model: model, ui: ui, clock: model.clock)
                    panelPill
                }
                .padding(.horizontal, side)
                .padding(.bottom, geo.safeAreaInsets.bottom > 0 ? 2 : 12)
            }
        }
        .foregroundStyle(.white)
    }

    private var step: Int { max(1, UserDefaults.standard.integer(forKey: SettingsKey.seekStep)) }
    private var stepIcon: Int { [5, 10, 15, 30, 45, 60, 75, 90].contains(step) ? step : 10 }

    private var transportPill: some View {
        HStack(spacing: 4) {
            PillIcon("gobackward.\(stepIcon)", size: 20) { model.seek(by: -Double(step)) }
            PillIcon(model.ended ? "arrow.counterclockwise" : (model.paused ? "play.fill" : "pause.fill"), size: 24, width: 54) {
                model.togglePause()
                ui.showControls()
            }
            PillIcon("goforward.\(stepIcon)", size: 20) { model.seek(by: Double(step)) }
        }
        .padding(.horizontal, 4)
        .frame(height: 52)
        .glass(cornerRadius: 26, interactive: true)
    }

    private var panelPill: some View {
        HStack(spacing: 2) {
            PillIcon("switch.2", size: 18, active: ui.panel == .tracks) { ui.toggle(.tracks) }
            PillIcon("slider.horizontal.3", size: 18, active: ui.panel == .settings) { ui.toggle(.settings) }
            PillIcon("list.bullet", size: 18, active: ui.panel == .nowPlaying) { ui.toggle(.nowPlaying) }
        }
        .padding(.horizontal, 4)
        .frame(height: 52)
        .glass(cornerRadius: 26, interactive: true)
    }

    // MARK: Overlays

    private func topPill<V: View>(_ content: V, top: CGFloat) -> some View {
        VStack {
            content
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glass(cornerRadius: 18)
                .padding(.top, top + 14)
            Spacer()
        }
        .foregroundStyle(.white)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private var lockedOverlay: some View {
        VStack {
            Spacer()
            Button {
                ui.locked = false
                ui.showControls()
            } label: {
                Label("Unlock", systemImage: "lock.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .glass(cornerRadius: 22, interactive: true)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(.bottom, 36)
        }
    }

    @ViewBuilder
    private func skipButton(_ geo: GeometryProxy) -> some View {
        if let seg = model.activeSegment, !ui.locked, ui.panel == nil {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button { model.skip(seg) } label: {
                        HStack(spacing: 6) {
                            Text(seg.kind.label)
                            Image(systemName: "chevron.right.2")
                        }
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .glass(cornerRadius: 20, interactive: true)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                }
                .padding(.trailing, max(20, geo.safeAreaInsets.trailing + 8))
                .padding(.bottom, ui.controlsVisible ? (geo.size.width < 640 ? 136 : 76) : 30)
            }
            .transition(.opacity)
            .animation(.easeOut(duration: 0.2), value: model.activeSegment)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title).foregroundStyle(Theme.accent)
            Text(message).multilineTextAlignment(.center).font(.callout)
            HStack(spacing: 12) {
                Button("Retry") { model.load(model.item) }.buttonStyle(.borderedProminent).tint(Theme.accent)
                Button("Close") { onClose() }.buttonStyle(.bordered)
            }
            Text("Details: Settings → Advanced → Diagnostics").font(.caption).foregroundStyle(.white.opacity(0.5))
        }
        .padding(22)
        .frame(maxWidth: 400)
        .glass(cornerRadius: 24)
        .foregroundStyle(.white)
    }

    private var endedView: some View {
        HStack(spacing: 12) {
            Button { model.seek(to: 0); model.setPaused(false); model.ended = false } label: {
                Label("Replay", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent)
            Button("Close") { onClose() }.buttonStyle(.bordered)
        }
        .padding(14)
        .glass(cornerRadius: 20)
        .offset(y: 90)
    }
}

// MARK: - Progress pill

struct TimeBar: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: PlayerUIState
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        HStack(spacing: 12) {
            Text(PlayerModel.format(ui.scrubTime ?? clock.position))
                .font(.footnote.monospacedDigit().weight(.semibold))
                .frame(minWidth: 40, alignment: .leading)
            SeekTrack(model: model, ui: ui, clock: clock)
            Button { ui.showRemaining.toggle() } label: {
                Text(ui.showRemaining ? "-" + PlayerModel.format(max(0, clock.duration - (ui.scrubTime ?? clock.position))) : PlayerModel.format(clock.duration))
                    .font(.footnote.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 40, alignment: .trailing)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .glass(cornerRadius: 26, interactive: true)
    }
}

struct SeekTrack: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: PlayerUIState
    @ObservedObject var clock: PlaybackClock
    @ObservedObject private var prefs = SeekBarPrefs.shared
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let d = max(clock.duration, 0.001)
            let shown = ui.scrubTime ?? clock.position
            let frac = min(1, max(0, shown / d))
            let cacheFrac = min(1, max(0, (clock.position + clock.cacheAhead) / d))
            let h: CGFloat = dragging ? 8 : 5
            let chapterTimes = model.chapters.dropFirst().map(\.time).filter { $0 > 0 && $0 < d }

            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.22))
                    Rectangle().fill(.white.opacity(0.30)).frame(width: w * cacheFrac)
                    if prefs.showSkipSegments {
                        ForEach(model.segments) { s in
                            Rectangle().fill(Theme.accent.opacity(0.55))
                                .frame(width: max(2, w * (s.end - s.start) / d))
                                .offset(x: w * s.start / d)
                        }
                    }
                    Rectangle().fill(.white).frame(width: w * frac)
                }
                .frame(height: h)
                .mask {
                    if prefs.markerStyle == "segments" && !chapterTimes.isEmpty {
                        SegmentMask(times: chapterTimes, duration: d, gap: 3)
                    } else {
                        Capsule()
                    }
                }

                if prefs.markerStyle == "ticks" {
                    ForEach(chapterTimes, id: \.self) { t in
                        Capsule().fill(prefs.color.opacity(0.9)).frame(width: 2, height: h + 8).offset(x: w * t / d - 1)
                    }
                } else if prefs.markerStyle == "dots" {
                    ForEach(chapterTimes, id: \.self) { t in
                        Circle().fill(prefs.color).frame(width: 5, height: 5).offset(x: w * t / d - 2.5, y: -(h / 2 + 6))
                    }
                }
                ForEach(model.userMarkers) { m in
                    Rectangle().fill(Color.yellow).frame(width: 7, height: 7).rotationEffect(.degrees(45))
                        .offset(x: w * min(1, m.time / d) - 3.5, y: -(h / 2 + 7))
                }
                Circle().fill(.white)
                    .frame(width: dragging ? 18 : 12, height: dragging ? 18 : 12)
                    .offset(x: w * frac - (dragging ? 9 : 6))
                if dragging {
                    ScrubBubble(time: shown, chapter: prefs.showChapterTitle ? chapterTitle(at: shown) : nil)
                        .fixedSize()
                        .offset(x: min(max(w * frac - 60, -10), w - 110), y: -54)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 52)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard clock.duration > 0 else { return }
                        if !dragging { dragging = true; ui.scrubbing = true }
                        let t = min(1, max(0, v.location.x / w)) * clock.duration
                        ui.scrubTime = t
                        model.scrub(to: t)
                    }
                    .onEnded { v in
                        if clock.duration > 0 { model.seek(to: min(1, max(0, v.location.x / w)) * clock.duration) }
                        dragging = false
                        ui.scrubbing = false
                        ui.scrubTime = nil
                        ui.scheduleHide()
                    }
            )
            .animation(.easeOut(duration: 0.12), value: dragging)
        }
        .frame(height: 52)
    }

    private func chapterTitle(at t: Double) -> String? {
        if let m = model.userMarkers.last(where: { abs($0.time - t) < 3 }) { return m.title }
        return model.chapters.last(where: { $0.time <= t + 0.01 })?.title
    }
}

struct SegmentMask: View {
    let times: [Double]
    let duration: Double
    let gap: CGFloat
    var body: some View {
        GeometryReader { g in
            let edges = [0.0] + times.map { $0 / duration } + [1.0]
            ZStack(alignment: .leading) {
                ForEach(0..<(edges.count - 1), id: \.self) { i in
                    let x0 = g.size.width * edges[i] + (i == 0 ? 0 : gap / 2)
                    let x1 = g.size.width * edges[i + 1] - (i == edges.count - 2 ? 0 : gap / 2)
                    Capsule().frame(width: max(1, x1 - x0)).offset(x: x0)
                }
            }
        }
    }
}

struct ScrubBubble: View {
    let time: Double
    let chapter: String?
    var body: some View {
        VStack(spacing: 2) {
            if let chapter { Text(chapter).font(.caption2.weight(.semibold)).lineLimit(1) }
            Text(PlayerModel.format(time)).font(.caption.monospacedDigit().weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: 220)
        .glass(cornerRadius: 14)
    }
}

// MARK: - Buttons

/// Press feedback shared by every control in the player: a quick spring
/// scale with a slight dim, like the system's glass buttons.
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.9
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct GlassIcon: View {
    let icon: String
    var size: CGFloat = 18
    let action: () -> Void
    init(_ icon: String, size: CGFloat = 18, action: @escaping () -> Void) { self.icon = icon; self.size = size; self.action = action }
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size, weight: .semibold))
                .frame(width: 44, height: 44)
                .glassCircle()
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .foregroundStyle(.white)
    }
}

struct PillIcon: View {
    let icon: String
    var size: CGFloat = 20
    var width: CGFloat = 50
    var active = false
    let action: () -> Void
    init(_ icon: String, size: CGFloat = 20, width: CGFloat = 50, active: Bool = false, action: @escaping () -> Void) {
        self.icon = icon; self.size = size; self.width = width; self.active = active; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: width, height: 44)
                .background(active ? Color.white.opacity(0.18) : Color.clear, in: Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.85))
        .foregroundStyle(.white)
    }
}

/// iOS-style level indicator: a slim vertical glass capsule at the screen
/// edge (left = brightness, right = volume) that fills with the level.
struct EdgeLevelHUD: View {
    let hud: PlayerUIState.GestureHUD
    let size: CGSize
    let safe: EdgeInsets

    var body: some View {
        let level = min(1, max(0, hud.progress ?? 0))
        let h = min(180, size.height * 0.4)
        HStack {
            if hud.kind == .volume { Spacer() }
            VStack(spacing: 8) {
                GeometryReader { g in
                    ZStack(alignment: .bottom) {
                        Capsule().fill(.white.opacity(0.18))
                        Capsule().fill(.white).frame(height: g.size.height * level)
                    }
                }
                .frame(width: 8, height: h)
                .animation(.spring(response: 0.25, dampingFraction: 0.9), value: level)
                Image(systemName: hud.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.vertical, 14).padding(.horizontal, 12)
            .glass(cornerRadius: 22)
            .padding(.horizontal, max(18, (hud.kind == .volume ? safe.trailing : safe.leading) + 8))
            if hud.kind == .brightness { Spacer() }
        }
        .foregroundStyle(.white)
        .allowsHitTesting(false)
    }
}

struct GestureHUDView: View {
    let hud: PlayerUIState.GestureHUD
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: hud.icon).font(.system(size: 24, weight: .semibold))
            Text(hud.text).font(.subheadline.monospacedDigit().weight(.semibold))
            if let p = hud.progress { ProgressView(value: min(1, max(0, p))).tint(.white).frame(width: 120) }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20).padding(.vertical, 14)
        .glass(cornerRadius: 18)
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = UIColor(Theme.accent)
        v.prioritizesVideoDevices = true
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
