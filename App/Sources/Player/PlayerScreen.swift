import SwiftUI
import AVKit
import UniformTypeIdentifiers

/// Minimal Outplayer-style player chrome: plain white glyphs over soft
/// gradients, native menus for everything else.
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
                        Image(systemName: "pip").font(.system(size: 40, weight: .light))
                        Text("Playing in Picture in Picture").font(.footnote)
                    }
                    .foregroundStyle(.white.opacity(0.55))
                    .allowsHitTesting(false)
                }

                if (model.buffering || model.isLoading) && model.errorMessage == nil && !(ui.controlsVisible && !ui.locked) {
                    ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
                }

                if ui.controlsVisible && !ui.locked {
                    PlayerControls(model: model, ui: ui, clock: model.clock, safe: geo.safeAreaInsets,
                                   onClose: onClose, onRotationLock: onRotationLock,
                                   onLoadSubtitle: { showSubtitlePicker = true })
                        .transition(.opacity)
                }

                if ui.locked && ui.controlsVisible { lockedOverlay.transition(.opacity) }

                skipButton(geo)

                if model.holdSpeedActive {
                    VStack {
                        Label(String(format: "%g×", model.holdSpeed), systemImage: "forward.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(.top, geo.safeAreaInsets.top + 18)
                        Spacer()
                    }
                    .foregroundStyle(.white)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                if let hud = ui.gestureHUD { GestureHUDView(hud: hud).allowsHitTesting(false) }

                if let toast = model.toast, ui.gestureHUD == nil, !model.holdSpeedActive {
                    VStack {
                        Text(toast).font(.footnote.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(.black.opacity(0.6), in: Capsule())
                            .padding(.top, geo.safeAreaInsets.top + (ui.controlsVisible ? 64 : 18))
                        Spacer()
                    }
                    .foregroundStyle(.white)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                if let error = model.errorMessage { errorView(error) }
                if model.ended && !model.hasNext && model.errorMessage == nil { endedView }
                if ui.showInfo { InfoCard(model: model, ui: ui).transition(.opacity) }
                if ui.showConsole {
                    ConsoleBar(model: model, ui: ui).transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: ui.controlsVisible)
            .animation(.easeOut(duration: 0.18), value: model.toast)
            .animation(.easeOut(duration: 0.18), value: model.holdSpeedActive)
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

    private var lockedOverlay: some View {
        VStack {
            Spacer()
            Button {
                ui.locked = false
                ui.showControls()
            } label: {
                Label("Unlock", systemImage: "lock.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .background(.black.opacity(0.55), in: Capsule())
            }
            .foregroundStyle(.white)
            .padding(.bottom, 36)
        }
    }

    @ViewBuilder
    private func skipButton(_ geo: GeometryProxy) -> some View {
        if let seg = model.activeSegment, !ui.locked {
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
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                    }
                }
                .padding(.trailing, max(20, geo.safeAreaInsets.trailing + 8))
                .padding(.bottom, ui.controlsVisible ? 108 : 30)
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
            Text("Details: Settings → mpv → Last playback log").font(.caption).foregroundStyle(.white.opacity(0.5))
        }
        .padding(22)
        .frame(maxWidth: 400)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 20))
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
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 18))
        .offset(y: 90)
    }
}

// MARK: - Controls

struct PlayerControls: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: PlayerUIState
    let clock: PlaybackClock
    let safe: EdgeInsets
    let onClose: () -> Void
    let onRotationLock: (Bool) -> Void
    let onLoadSubtitle: () -> Void

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom).frame(height: 120)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).frame(height: 170)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                centerControls
                Spacer()
                VStack(spacing: 4) {
                    TimeBar(model: model, ui: ui, clock: clock)
                    bottomRow
                }
            }
            .padding(.horizontal, max(14, min(max(safe.leading, safe.trailing), 48)))
            .padding(.top, 4)
            .padding(.bottom, safe.bottom > 0 ? 0 : 8)
        }
        .foregroundStyle(.white)
    }

    // MARK: Top

    private var topBar: some View {
        HStack(alignment: .center, spacing: 6) {
            Glyph("xmark", size: 18) { onClose() }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.item.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                if !subtitleLine.isEmpty {
                    Text(subtitleLine).font(.caption2).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if PiPManager.isSupported && UserDefaults.standard.bool(forKey: SettingsKey.pipEnabled) {
                Glyph(model.isPiPActive ? "pip.exit" : "pip.enter") {
                    model.isPiPActive ? model.stopPiP() : model.startPiP()
                }
                .opacity(model.isPiPPossible || model.isPiPActive ? 1 : 0.35)
                .disabled(!model.isPiPPossible && !model.isPiPActive)
            }
            AirPlayButton().frame(width: 40, height: 40)
        }
    }

    private var subtitleLine: String {
        var parts: [String] = []
        if let s = model.item.subtitle, !s.isEmpty { parts.append(s) }
        else if let ch = model.chapters.first(where: { $0.id == model.currentChapter }) { parts.append(ch.title) }
        if !model.videoFormat.isEmpty, model.videoFormat != "SDR" { parts.append(model.videoFormat) }
        if let a = model.tracks.first(where: { $0.type == "audio" && $0.selected }),
           a.profile?.localizedCaseInsensitiveContains("atmos") == true {
            parts.append("Atmos")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Center

    private var centerControls: some View {
        HStack(spacing: 52) {
            Glyph("gobackward.\(stepIcon)", size: 28) { model.seek(by: -Double(step)) }
            Glyph(model.ended ? "arrow.counterclockwise" : (model.paused ? "play.fill" : "pause.fill"), size: 44, box: 72) {
                model.togglePause()
                ui.showControls()
            }
            Glyph("goforward.\(stepIcon)", size: 28) { model.seek(by: Double(step)) }
        }
    }

    private var step: Int { max(1, UserDefaults.standard.integer(forKey: SettingsKey.seekStep)) }
    private var stepIcon: Int { [5, 10, 15, 30, 45, 60, 75, 90].contains(step) ? step : 10 }

    // MARK: Bottom

    private var bottomRow: some View {
        HStack(spacing: 4) {
            Glyph("lock.open", size: 17) {
                ui.locked = true
                ui.showControls()
            }
            Glyph(ui.rotationLocked ? "lock.rotation" : "rotate.right", size: 17) {
                ui.rotationLocked.toggle()
                onRotationLock(ui.rotationLocked)
                model.showToast(ui.rotationLocked ? "Rotation locked" : "Rotation unlocked")
            }
            Glyph(model.zoomToFill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", size: 16) {
                model.toggleZoom()
            }
            Spacer()
            SubtitleMenu(model: model, onLoadSubtitle: onLoadSubtitle)
            AudioMenu(model: model)
            SpeedMenu(model: model)
            MoreMenu(model: model, ui: ui)
            if model.hasNext {
                Glyph("forward.end.fill", size: 17) { model.playNext() }
            }
        }
    }
}

/// Position-driven part of the controls; the only view that re-renders
/// while playing.
struct TimeBar: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: PlayerUIState
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        HStack(spacing: 10) {
            Text(PlayerModel.format(ui.scrubTime ?? clock.position))
                .font(.caption.monospacedDigit().weight(.medium))
                .frame(minWidth: 42, alignment: .leading)
            SeekBar(model: model, ui: ui, clock: clock)
            Button { ui.showRemaining.toggle() } label: {
                Text(ui.showRemaining ? "-" + PlayerModel.format(max(0, clock.duration - (ui.scrubTime ?? clock.position))) : PlayerModel.format(clock.duration))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .frame(minWidth: 42, alignment: .trailing)
            }
        }
    }
}

struct SeekBar: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: PlayerUIState
    @ObservedObject var clock: PlaybackClock
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let d = max(clock.duration, 0.001)
            let shown = ui.scrubTime ?? clock.position
            let frac = min(1, max(0, shown / d))
            let cacheFrac = min(1, max(0, (clock.position + clock.cacheAhead) / d))
            let h: CGFloat = dragging ? 7 : 4
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22)).frame(height: h)
                Capsule().fill(.white.opacity(0.32)).frame(width: w * cacheFrac, height: h)
                ForEach(model.segments) { s in
                    Rectangle().fill(Theme.accent.opacity(0.5))
                        .frame(width: max(2, w * (s.end - s.start) / d), height: h)
                        .offset(x: w * s.start / d)
                }
                Capsule().fill(.white).frame(width: w * frac, height: h)
                ForEach(model.chapters.dropFirst()) { ch in
                    Rectangle().fill(.black.opacity(0.6)).frame(width: 2, height: h)
                        .offset(x: w * ch.time / d - 1)
                }
                Circle().fill(.white).frame(width: dragging ? 18 : 11, height: dragging ? 18 : 11)
                    .offset(x: w * frac - (dragging ? 9 : 5.5))
            }
            .frame(height: 32)
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
                        if clock.duration > 0 {
                            model.seek(to: min(1, max(0, v.location.x / w)) * clock.duration)
                        }
                        dragging = false
                        ui.scrubbing = false
                        ui.scrubTime = nil
                        ui.scheduleHide()
                    }
            )
            .animation(.easeOut(duration: 0.12), value: dragging)
        }
        .frame(height: 32)
    }
}

// MARK: - Menus

struct SubtitleMenu: View {
    @ObservedObject var model: PlayerModel
    let onLoadSubtitle: () -> Void

    var body: some View {
        Menu {
            Picker("Subtitles", selection: Binding<Int>(
                get: { model.tracks("sub").first(where: \.selected)?.id ?? -1 },
                set: { model.selectTrack("sub", id: $0 < 0 ? nil : $0) }
            )) {
                Text("Off").tag(-1)
                ForEach(model.tracks("sub")) { t in
                    Text(t.label + (t.detail.isEmpty ? "" : "  ·  " + t.detail)).tag(t.id)
                }
            }
            .pickerStyle(.inline)
            Menu {
                Button("+0.1 s") { model.setSubDelay(model.subDelay + 0.1) }
                Button("−0.1 s") { model.setSubDelay(model.subDelay - 0.1) }
                Button("+1 s") { model.setSubDelay(model.subDelay + 1) }
                Button("−1 s") { model.setSubDelay(model.subDelay - 1) }
                Button("Reset") { model.setSubDelay(0) }
            } label: {
                Label(String(format: "Delay  %+.1f s", model.subDelay), systemImage: "timer")
            }
            .menuActionDismissBehavior(.disabled)
            Menu {
                ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { s in
                    Button("\(Int(s * 100))%") { model.setSubScale(s) }
                }
            } label: { Label("Size", systemImage: "textformat.size") }
            Button { onLoadSubtitle() } label: { Label("Load from Files…", systemImage: "folder") }
        } label: {
            GlyphLabel("captions.bubble", size: 18)
        }
    }
}

struct AudioMenu: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        Menu {
            Picker("Audio", selection: Binding<Int>(
                get: { model.tracks("audio").first(where: \.selected)?.id ?? -1 },
                set: { model.selectTrack("audio", id: $0 < 0 ? nil : $0) }
            )) {
                ForEach(model.tracks("audio")) { t in
                    Text(t.label + "  ·  " + t.detail).tag(t.id)
                }
                Text("Off").tag(-1)
            }
            .pickerStyle(.inline)
            Menu {
                Button("+50 ms") { model.setAudioDelay(model.audioDelay + 0.05) }
                Button("−50 ms") { model.setAudioDelay(model.audioDelay - 0.05) }
                Button("Reset") { model.setAudioDelay(0) }
            } label: {
                Label(String(format: "Delay  %+.0f ms", model.audioDelay * 1000), systemImage: "timer")
            }
            .menuActionDismissBehavior(.disabled)
            if !model.audioOut.isEmpty {
                Text("Output: \(AudioFormat.channelLayout(channels: model.audioOut, count: nil) ?? model.audioOut)")
            }
        } label: {
            GlyphLabel("waveform", size: 17)
        }
    }
}

struct SpeedMenu: View {
    @ObservedObject var model: PlayerModel
    private let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    private let holdSpeeds: [Double] = [1.5, 2.0, 2.5, 3.0, 4.0]

    var body: some View {
        Menu {
            Picker("Speed", selection: Binding<Double>(
                get: { speeds.min(by: { abs($0 - model.speed) < abs($1 - model.speed) }) ?? 1 },
                set: { model.setSpeed($0) }
            )) {
                ForEach(speeds, id: \.self) { s in Text(s == 1 ? "Normal" : String(format: "%g×", s)).tag(s) }
            }
            .pickerStyle(.inline)
            Section("Hold to speed up") {
                Toggle("Press and hold video", isOn: $model.holdEnabled)
                Picker("Hold speed", selection: $model.holdSpeed) {
                    ForEach(holdSpeeds, id: \.self) { s in Text(String(format: "%g×", s)).tag(s) }
                }
                .pickerStyle(.menu)
            }
        } label: {
            if model.speed != 1 {
                Text(String(format: "%g×", (model.speed * 100).rounded() / 100))
                    .font(.footnote.weight(.bold))
                    .frame(width: 44, height: 44)
            } else {
                GlyphLabel("gauge.with.dots.needle.67percent", size: 17)
            }
        }
    }
}

struct MoreMenu: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: PlayerUIState
    private let aspects: [(String, String)] = [("Auto", "no"), ("16:9", "16:9"), ("4:3", "4:3"), ("2.35:1", "2.35:1"), ("1:1", "1:1")]

    var body: some View {
        Menu {
            if !model.chapters.isEmpty {
                Menu {
                    ForEach(model.chapters) { ch in
                        Button { model.jump(to: ch) } label: {
                            Text(ch.title + "  " + PlayerModel.format(ch.time))
                            if ch.id == model.currentChapter { Image(systemName: "checkmark") }
                        }
                    }
                } label: { Label("Chapters", systemImage: "list.bullet") }
            }
            Menu {
                Picker("Aspect", selection: Binding(get: { model.aspectOverride }, set: { model.setAspect($0) })) {
                    ForEach(aspects, id: \.1) { a in Text(a.0).tag(a.1) }
                }
                Divider()
                Button("Deband on/off") { model.run(command: "cycle deband") }
                Button("Deinterlace on/off") { model.run(command: "cycle deinterlace") }
                Button("Rotate 90°") { model.run(command: "cycle-values video-rotate 90 180 270 0") }
            } label: { Label("Video", systemImage: "aspectratio") }
            shadersMenu
            commandsMenu
            Button { model.screenshot() } label: { Label("Screenshot", systemImage: "camera") }
            Button { ui.showInfo = true } label: { Label("Media info", systemImage: "info.circle") }
        } label: {
            GlyphLabel("ellipsis.circle", size: 18)
        }
    }

    private var shadersMenu: some View {
        let files = MPVFiles.shaders()
        return Menu {
            Button { model.setShaders([]) } label: {
                Text("Off")
                if model.activeShaders.isEmpty { Image(systemName: "checkmark") }
            }
            ForEach(ShaderPresets.available(files: files), id: \.name) { p in
                Button { model.setShaders(p.shaders) } label: {
                    Text(p.name)
                    if model.activeShaders == p.shaders { Image(systemName: "checkmark") }
                }
            }
            if !files.isEmpty {
                Section("Individual") {
                    ForEach(files, id: \.self) { f in
                        let name = f.lastPathComponent
                        Toggle(name, isOn: Binding(
                            get: { model.activeShaders.contains(name) },
                            set: { on in
                                var list = model.activeShaders
                                if on { list.append(name) } else { list.removeAll { $0 == name } }
                                model.setShaders(list)
                            }
                        ))
                    }
                }
            } else {
                Text("Add shaders in Settings → mpv")
            }
        } label: { Label("Shaders", systemImage: "wand.and.stars") }
    }

    private var commandsMenu: some View {
        Menu {
            ForEach(ScriptCommandStore.all) { c in
                Button(c.name) { model.run(command: c.command) }
            }
            Divider()
            Button { ui.showConsole = true } label: { Label("Run mpv command…", systemImage: "terminal") }
        } label: { Label("Commands", systemImage: "command") }
    }
}

// MARK: - Glyphs

struct Glyph: View {
    let icon: String
    var size: CGFloat = 20
    var box: CGFloat = 44
    let action: () -> Void

    init(_ icon: String, size: CGFloat = 20, box: CGFloat = 44, action: @escaping () -> Void) {
        self.icon = icon; self.size = size; self.box = box; self.action = action
    }

    var body: some View {
        Button(action: action) { GlyphLabel(icon, size: size, box: box) }
            .buttonStyle(.plain)
    }
}

struct GlyphLabel: View {
    let icon: String
    var size: CGFloat
    var box: CGFloat

    init(_ icon: String, size: CGFloat = 20, box: CGFloat = 44) {
        self.icon = icon; self.size = size; self.box = box
    }

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.45), radius: 3)
            .frame(width: box, height: box)
            .contentShape(Rectangle())
    }
}

struct GestureHUDView: View {
    let hud: PlayerUIState.GestureHUD
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: hud.icon).font(.system(size: 24, weight: .semibold))
            Text(hud.text).font(.subheadline.monospacedDigit().weight(.semibold))
            if let p = hud.progress {
                ProgressView(value: min(1, max(0, p))).tint(.white).frame(width: 120)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
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
