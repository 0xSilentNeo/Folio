import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct PlayerScreen: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: PlayerUIState
    var onClose: () -> Void = {}
    var onRotationLock: (Bool) -> Void = { _ in }

    @State private var showSubtitlePicker = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                VideoSurface(model: model, ui: ui).ignoresSafeArea()

                if model.isPiPActive {
                    VStack(spacing: 10) {
                        Image(systemName: "pip").font(.system(size: 44, weight: .light))
                        Text("Playing in Picture in Picture").font(.callout)
                    }
                    .foregroundStyle(.white.opacity(0.6))
                    .allowsHitTesting(false)
                }

                if (model.buffering || model.isLoading) && model.errorMessage == nil {
                    ProgressView().controlSize(.large).tint(.white)
                        .padding(18).glassCircle()
                        .allowsHitTesting(false)
                }

                if ui.controlsVisible && !ui.locked {
                    controls(geo)
                        .transition(.opacity)
                }

                if ui.locked && ui.controlsVisible {
                    lockedOverlay.transition(.opacity)
                }

                skipButton(geo)

                if let hud = ui.gestureHUD { GestureHUDView(hud: hud).allowsHitTesting(false) }

                if let toast = model.toast, ui.gestureHUD == nil {
                    VStack {
                        Text(toast).font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .glass(cornerRadius: 14)
                            .padding(.top, geo.safeAreaInsets.top + 64)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                if let error = model.errorMessage { errorView(error) }

                if model.ended && !model.hasNext && model.errorMessage == nil { endedView }

                if let panel = ui.panel {
                    PanelContainer(panel: panel, model: model, ui: ui, size: geo.size)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                if ui.showConsole {
                    ConsoleBar(model: model, ui: ui)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: ui.panel)
            .animation(.easeOut(duration: 0.2), value: ui.controlsVisible)
            .animation(.easeOut(duration: 0.2), value: model.toast)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { ui.scheduleHide() }
        .onChange(of: model.paused) { _, paused in
            if paused { ui.showControls(autoHide: false) } else { ui.scheduleHide() }
        }
        .fileImporter(isPresented: $showSubtitlePicker, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { model.addSubtitle(url: url) }
        }
    }

    // MARK: Controls

    @ViewBuilder
    private func controls(_ geo: GeometryProxy) -> some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom).frame(height: 140)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom).frame(height: 200)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                centerControls
                Spacer()
                bottomBar
            }
            .padding(.horizontal, max(16, min(geo.safeAreaInsets.leading, 44)))
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            CircleButton(icon: "xmark") { onClose() }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.item.displayTitle).font(.headline).lineLimit(1)
                if let sub = model.item.subtitle {
                    Text(sub).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                } else if let ch = model.chapters.first(where: { $0.id == model.currentChapter }) {
                    Text(ch.title).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                if PiPManager.isSupported && UserDefaults.standard.bool(forKey: SettingsKey.pipEnabled) {
                    BarButton(icon: model.isPiPActive ? "pip.exit" : "pip.enter") {
                        model.isPiPActive ? model.stopPiP() : model.startPiP()
                    }
                    .disabled(!model.isPiPPossible && !model.isPiPActive)
                    .opacity(model.isPiPPossible || model.isPiPActive ? 1 : 0.4)
                }
                AirPlayButton().frame(width: 40, height: 40)
                BarButton(icon: model.zoomToFill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                    model.toggleZoom()
                }
                BarButton(icon: ui.rotationLocked ? "lock.rotation" : "rotate.right") {
                    ui.rotationLocked.toggle()
                    onRotationLock(ui.rotationLocked)
                    model.showToast(ui.rotationLocked ? "Rotation locked" : "Rotation unlocked")
                }
                BarButton(icon: "lock.open") {
                    ui.locked = true
                    ui.showControls()
                }
                Menu {
                    Button { ui.panel = .info } label: { Label("Media info", systemImage: "info.circle") }
                    Button { ui.panel = .video } label: { Label("Video & aspect", systemImage: "aspectratio") }
                    Button { model.screenshot() } label: { Label("Screenshot", systemImage: "camera") }
                    Button { showSubtitlePicker = true } label: { Label("Load subtitle file…", systemImage: "captions.bubble") }
                    Button { ui.showConsole = true } label: { Label("mpv command…", systemImage: "terminal") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold))
                        .frame(width: 40, height: 40).contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 6)
            .glass(cornerRadius: 22)
        }
        .foregroundStyle(.white)
    }

    private var centerControls: some View {
        HStack(spacing: 36) {
            if model.queue.count > 1 {
                CenterButton(icon: "backward.end.fill", size: 22) { model.playPrevious() }
                    .opacity(model.hasPrevious || model.position > 10 ? 1 : 0.35)
            }
            CenterButton(icon: "gobackward.\(seekStepIcon)", size: 28) { model.seek(by: -Double(seekStep)) }
            CenterButton(icon: model.ended ? "arrow.counterclockwise" : (model.paused ? "play.fill" : "pause.fill"), size: 40, big: true) {
                model.togglePause()
                ui.showControls()
            }
            CenterButton(icon: "goforward.\(seekStepIcon)", size: 28) { model.seek(by: Double(seekStep)) }
            if model.queue.count > 1 {
                CenterButton(icon: "forward.end.fill", size: 22) { model.playNext() }
                    .opacity(model.hasNext ? 1 : 0.35)
            }
        }
        .foregroundStyle(.white)
    }

    private var seekStep: Int { max(1, UserDefaults.standard.integer(forKey: SettingsKey.seekStep)) }
    private var seekStepIcon: Int { [5, 10, 15, 30, 45, 60, 75, 90].contains(seekStep) ? seekStep : 10 }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(PlayerModel.format(ui.scrubTime ?? model.position))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .frame(minWidth: 44, alignment: .leading)
                SeekBar(model: model, ui: ui)
                Button {
                    ui.showRemaining.toggle()
                } label: {
                    Text(ui.showRemaining ? "-" + PlayerModel.format(max(0, model.duration - model.position)) : PlayerModel.format(model.duration))
                        .font(.caption.monospacedDigit().weight(.medium))
                        .frame(minWidth: 44, alignment: .trailing)
                }
            }
            HStack(spacing: 8) {
                PillButton(icon: "captions.bubble", title: "Audio & Subs") { ui.panel = .tracks }
                PillButton(icon: "speedometer", title: speedLabel) { ui.panel = .speed }
                if !model.chapters.isEmpty {
                    PillButton(icon: "list.bullet", title: "Chapters") { ui.panel = .chapters }
                }
                PillButton(icon: "wand.and.stars", title: model.activeShaders.isEmpty ? "Shaders" : "Shaders (\(model.activeShaders.count))") { ui.panel = .shaders }
                PillButton(icon: "command", title: "Commands") { ui.panel = .commands }
                Spacer(minLength: 0)
                if model.hasNext {
                    PillButton(icon: "forward.end", title: "Next") { model.playNext() }
                }
            }
        }
        .foregroundStyle(.white)
    }

    private var speedLabel: String {
        model.speed == 1 ? "Speed" : String(format: "%gx", (model.speed * 100).rounded() / 100)
    }

    // MARK: Overlays

    private var lockedOverlay: some View {
        VStack {
            Spacer()
            Button {
                ui.locked = false
                ui.showControls()
            } label: {
                Label("Tap to unlock", systemImage: "lock.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .glass(cornerRadius: 24, interactive: true)
            }
            .foregroundStyle(.white)
            .padding(.bottom, 40)
        }
    }

    @ViewBuilder
    private func skipButton(_ geo: GeometryProxy) -> some View {
        if let seg = model.activeSegment, !ui.locked {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        model.skip(seg)
                    } label: {
                        HStack(spacing: 8) {
                            Text(seg.kind.label).font(.subheadline.weight(.bold))
                            Image(systemName: "forward.fill").font(.caption)
                        }
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .glass(cornerRadius: 22, interactive: true)
                        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Theme.accent.opacity(0.8), lineWidth: 1))
                    }
                    .foregroundStyle(.white)
                }
                .padding(.trailing, max(20, geo.safeAreaInsets.trailing))
                .padding(.bottom, ui.controlsVisible ? 110 : 36)
            }
            .transition(.opacity.combined(with: .move(edge: .trailing)))
            .animation(.easeOut(duration: 0.25), value: model.activeSegment)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(Theme.accent)
            Text(message).multilineTextAlignment(.center).font(.callout)
            HStack(spacing: 12) {
                Button("Retry") { model.load(model.item) }.buttonStyle(.borderedProminent).tint(Theme.accent)
                Button("Close") { onClose() }.buttonStyle(.bordered)
            }
            Text("See Settings → mpv → Last log for details.").font(.caption).foregroundStyle(.white.opacity(0.5))
        }
        .padding(24)
        .frame(maxWidth: 420)
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
        .padding(16)
        .glass(cornerRadius: 22)
        .offset(y: 90)
    }
}

// MARK: - Seek bar

struct SeekBar: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: PlayerUIState
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let d = max(model.duration, 0.001)
            let shown = ui.scrubTime ?? model.position
            let frac = min(1, max(0, shown / d))
            let cacheFrac = min(1, max(0, (model.position + model.cacheAhead) / d))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2)).frame(height: dragging ? 8 : 5)
                Capsule().fill(.white.opacity(0.28)).frame(width: w * cacheFrac, height: dragging ? 8 : 5)
                ForEach(model.segments) { s in
                    Rectangle().fill(Theme.accent.opacity(0.55))
                        .frame(width: max(2, w * (s.end - s.start) / d), height: dragging ? 8 : 5)
                        .offset(x: w * s.start / d)
                }
                Capsule().fill(Theme.accent).frame(width: w * frac, height: dragging ? 8 : 5)
                ForEach(model.chapters.dropFirst()) { ch in
                    Rectangle().fill(.black.opacity(0.7)).frame(width: 2, height: dragging ? 8 : 5)
                        .offset(x: w * ch.time / d - 1)
                }
                Circle().fill(.white).frame(width: dragging ? 18 : 12, height: dragging ? 18 : 12)
                    .shadow(radius: 3)
                    .offset(x: w * frac - (dragging ? 9 : 6))
            }
            .frame(height: 30)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard model.duration > 0 else { return }
                        dragging = true
                        ui.scrubbing = true
                        ui.scrubTime = min(1, max(0, v.location.x / w)) * model.duration
                    }
                    .onEnded { v in
                        if model.duration > 0 {
                            model.seek(to: min(1, max(0, v.location.x / w)) * model.duration)
                        }
                        dragging = false
                        ui.scrubbing = false
                        ui.scrubTime = nil
                        ui.scheduleHide()
                    }
            )
            .animation(.easeOut(duration: 0.15), value: dragging)
        }
        .frame(height: 30)
    }
}

// MARK: - Small components

struct CircleButton: View {
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold))
                .frame(width: 42, height: 42)
                .glassCircle()
        }
        .foregroundStyle(.white)
    }
}

struct BarButton: View {
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40).contentShape(Rectangle())
        }
        .foregroundStyle(.white)
    }
}

struct CenterButton: View {
    let icon: String
    var size: CGFloat = 28
    var big = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: big ? 84 : 60, height: big ? 84 : 60)
                .glassCircle()
        }
        .foregroundStyle(.white)
    }
}

struct PillButton: View {
    let icon: String
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(title).font(.caption.weight(.semibold)).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .glass(cornerRadius: 16, interactive: true)
        }
        .foregroundStyle(.white)
    }
}

struct GestureHUDView: View {
    let hud: PlayerUIState.GestureHUD
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: hud.icon).font(.system(size: 26, weight: .semibold))
            Text(hud.text).font(.headline.monospacedDigit())
            if let p = hud.progress {
                ProgressView(value: min(1, max(0, p))).tint(Theme.accent).frame(width: 140)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22).padding(.vertical, 16)
        .glass(cornerRadius: 22)
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
