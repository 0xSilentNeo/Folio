import SwiftUI

/// Right-side glass panel (Outplayer style) hosting the player's menus.
struct PanelContainer: View {
    let panel: PlayerUIState.Panel
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: PlayerUIState
    let size: CGSize

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Button { ui.panel = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                            .frame(width: 30, height: 30).glassCircle()
                    }
                }
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)
                ScrollView {
                    content.padding(.horizontal, 12).padding(.bottom, 16)
                }
            }
            .frame(width: min(380, size.width * (size.width > size.height ? 0.42 : 0.92)))
            .frame(maxHeight: .infinity)
            .glass(cornerRadius: 26)
            .padding(.vertical, 10)
            .padding(.trailing, 10)
        }
        .foregroundStyle(.white)
    }

    private var title: String {
        switch panel {
        case .tracks: return "Audio & Subtitles"
        case .speed: return "Playback Speed"
        case .chapters: return "Chapters"
        case .shaders: return "Shaders"
        case .commands: return "Commands"
        case .video: return "Video"
        case .info: return "Media Info"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch panel {
        case .tracks: TracksPanel(model: model)
        case .speed: SpeedPanel(model: model)
        case .chapters: ChaptersPanel(model: model, ui: ui)
        case .shaders: ShadersPanel(model: model)
        case .commands: CommandsPanel(model: model, ui: ui)
        case .video: VideoPanel(model: model)
        case .info: InfoPanel(model: model)
        }
    }
}

struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 6).padding(.top, 12)
            VStack(spacing: 2) { content }
        }
    }
}

struct PanelRow: View {
    let title: String
    var detail: String? = nil
    var selected = false
    var icon: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon { Image(systemName: icon).frame(width: 20) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(selected ? .semibold : .regular)).lineLimit(2)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Theme.accent) }
            }
            .padding(.horizontal, 10).padding(.vertical, 10)
            .background(selected ? Theme.accentSoft : Color.white.opacity(0.0001), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct TracksPanel: View {
    @ObservedObject var model: PlayerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PanelSection(title: "Audio") {
                ForEach(model.tracks("audio")) { t in
                    PanelRow(title: t.label, detail: t.detail, selected: t.selected) { model.selectTrack("audio", id: t.id) }
                }
                if model.tracks("audio").isEmpty { emptyRow("No audio tracks") }
            }
            PanelSection(title: "Subtitles") {
                PanelRow(title: "Off", selected: model.sid == "no" || model.sid == "false") { model.selectTrack("sub", id: nil) }
                ForEach(model.tracks("sub")) { t in
                    PanelRow(title: t.label, detail: t.detail, selected: t.selected) { model.selectTrack("sub", id: t.id) }
                }
            }
            PanelSection(title: "Subtitle delay") {
                Stepper(value: Binding(get: { model.subDelay }, set: { model.setSubDelay($0) }), in: -30...30, step: 0.1) {
                    Text(String(format: "%+.1f s", model.subDelay)).font(.subheadline.monospacedDigit())
                }
                .padding(.horizontal, 10)
            }
            PanelSection(title: "Audio delay") {
                Stepper(value: Binding(get: { model.audioDelay }, set: { model.setAudioDelay($0) }), in: -10...10, step: 0.05) {
                    Text(String(format: "%+.2f s", model.audioDelay)).font(.subheadline.monospacedDigit())
                }
                .padding(.horizontal, 10)
            }
            if model.tracks("video").count > 1 {
                PanelSection(title: "Video") {
                    ForEach(model.tracks("video")) { t in
                        PanelRow(title: t.label, detail: t.detail, selected: t.selected) { model.selectTrack("video", id: t.id) }
                    }
                }
            }
        }
    }

    private func emptyRow(_ s: String) -> some View {
        Text(s).font(.subheadline).foregroundStyle(.white.opacity(0.5)).padding(10)
    }
}

struct SpeedPanel: View {
    @ObservedObject var model: PlayerModel
    private let presets: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(format: "%.2fx", model.speed)).font(.largeTitle.monospacedDigit().weight(.semibold))
                .frame(maxWidth: .infinity)
            Slider(value: Binding(get: { model.speed }, set: { model.setSpeed(($0 * 20).rounded() / 20) }), in: 0.25...4)
                .tint(Theme.accent)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70))], spacing: 8) {
                ForEach(presets, id: \.self) { s in
                    Button { model.setSpeed(s) } label: {
                        Text(String(format: "%gx", s)).font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(abs(model.speed - s) < 0.01 ? Theme.accent : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 8)
    }
}

struct ChaptersPanel: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: PlayerUIState
    var body: some View {
        VStack(spacing: 2) {
            ForEach(model.chapters) { ch in
                PanelRow(title: ch.title, detail: PlayerModel.format(ch.time), selected: ch.id == model.currentChapter) {
                    model.jump(to: ch)
                }
            }
            if !model.segments.isEmpty {
                PanelSection(title: "Skip markers") {
                    ForEach(model.segments) { s in
                        PanelRow(title: s.kind.chapterTitle, detail: "\(PlayerModel.format(s.start)) – \(PlayerModel.format(s.end)) · \(s.source)", icon: "forward") {
                            model.seek(to: s.start)
                        }
                    }
                }
            }
        }
    }
}

struct ShadersPanel: View {
    @ObservedObject var model: PlayerModel
    @State private var files: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if files.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No shaders installed.").font(.subheadline.weight(.semibold))
                    Text("Add .glsl files in Settings → Shaders (one-tap Anime4K / FSRCNNX downloads), or drop them into the mpv/shaders folder in the Files app.")
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                .padding(10)
            } else {
                PanelRow(title: "All off", selected: model.activeShaders.isEmpty, icon: "circle.slash") { model.setShaders([]) }
                ForEach(ShaderPresets.available(files: files), id: \.name) { preset in
                    PanelRow(title: preset.name, detail: "Preset", selected: model.activeShaders == preset.shaders, icon: "sparkles") {
                        model.setShaders(preset.shaders)
                    }
                }
                PanelSection(title: "Shaders (tap order = apply order)") {
                    ForEach(files, id: \.self) { f in
                        let name = f.lastPathComponent
                        let idx = model.activeShaders.firstIndex(of: name)
                        PanelRow(title: name, detail: idx.map { "#\($0 + 1)" }, selected: idx != nil) {
                            var list = model.activeShaders
                            if let idx { list.remove(at: idx) } else { list.append(name) }
                            model.setShaders(list)
                        }
                    }
                }
                if model.isPiPActive {
                    Text("Shaders pause during Picture in Picture.").font(.caption).foregroundStyle(.white.opacity(0.5)).padding(10)
                }
            }
        }
        .onAppear { files = MPVFiles.shaders() }
    }
}

struct CommandsPanel: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: PlayerUIState
    @State private var commands = ScriptCommandStore.all
    @State private var scripts: [MPVFiles.Script] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PanelRow(title: "Run mpv command…", detail: "Same syntax as input.conf", icon: "terminal") {
                ui.panel = nil
                ui.showConsole = true
            }
            PanelSection(title: "Your commands") {
                ForEach(commands) { c in
                    PanelRow(title: c.name, detail: c.command, icon: "play.circle") { model.run(command: c.command) }
                }
                Text("Edit these in Settings → Commands.").font(.caption).foregroundStyle(.white.opacity(0.45)).padding(.horizontal, 10)
            }
            PanelSection(title: "Loaded scripts") {
                let enabled = scripts.filter(\.enabled)
                if enabled.isEmpty {
                    Text("No scripts in mpv/scripts.").font(.caption).foregroundStyle(.white.opacity(0.5)).padding(10)
                }
                ForEach(enabled) { s in
                    HStack {
                        Image(systemName: "chevron.left.forwardslash.chevron.right").frame(width: 20)
                        Text(s.name).font(.subheadline)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                }
            }
        }
        .onAppear {
            commands = ScriptCommandStore.all
            scripts = MPVFiles.scripts()
        }
    }
}

struct VideoPanel: View {
    @ObservedObject var model: PlayerModel
    private let aspects: [(String, String)] = [("Auto", "no"), ("16:9", "16:9"), ("4:3", "4:3"), ("21:9", "2.35:1"), ("1:1", "1:1")]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PanelSection(title: "Aspect ratio") {
                ForEach(aspects, id: \.1) { a in
                    PanelRow(title: a.0, selected: model.aspectOverride == a.1) { model.setAspect(a.1) }
                }
            }
            PanelSection(title: "Scaling") {
                PanelRow(title: "Fit", selected: !model.zoomToFill) { if model.zoomToFill { model.toggleZoom() } }
                PanelRow(title: "Fill (crop)", selected: model.zoomToFill) { if !model.zoomToFill { model.toggleZoom() } }
            }
            PanelSection(title: "Quick toggles") {
                PanelRow(title: "Deband", icon: "slider.horizontal.3") { model.run(command: "cycle deband") }
                PanelRow(title: "Deinterlace", icon: "rectangle.split.3x1") { model.run(command: "cycle deinterlace") }
                PanelRow(title: "Rotate 90°", icon: "rotate.right") { model.run(command: "cycle-values video-rotate 90 180 270 0") }
                PanelRow(title: "Flip horizontally", icon: "arrow.left.and.right.righttriangle.left.righttriangle.right") { model.run(command: "vf toggle hflip") }
            }
        }
    }
}

struct InfoPanel: View {
    @ObservedObject var model: PlayerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            info("Title", model.mediaTitle)
            info("Resolution", model.videoSize == .zero ? "–" : "\(Int(model.videoSize.width))×\(Int(model.videoSize.height))")
            info("Hardware decoding", model.hwdecCurrent.isEmpty || model.hwdecCurrent == "no" ? "Off (software)" : model.hwdecCurrent)
            info("Video codec", model.tracks("video").first { $0.selected }?.codec ?? "–")
            info("Audio", model.tracks("audio").first { $0.selected }.map { "\($0.codec ?? "") \($0.channels ?? "")" } ?? "–")
            info("Buffered ahead", String(format: "%.0f s", model.cacheAhead))
            info("Source", model.item.url)
            Button {
                model.run(command: "script-binding stats/display-stats-toggle")
            } label: {
                Label("Toggle mpv stats overlay", systemImage: "chart.bar.xaxis")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6).padding(.top, 8)
    }

    private func info(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.caption).foregroundStyle(.white.opacity(0.5))
            Text(v).font(.subheadline).textSelection(.enabled).lineLimit(3)
        }
    }
}

struct ConsoleBar: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: PlayerUIState
    @State private var text = ""
    @FocusState private var focused: Bool
    @AppStorage("consoleHistory") private var historyRaw = ""

    var body: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                let history = historyRaw.split(separator: "\n").map(String.init)
                if !history.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(history.prefix(8), id: \.self) { h in
                                Button(h) { text = h }
                                    .font(.caption.monospaced())
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Color.white.opacity(0.1), in: Capsule())
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
                HStack {
                    Image(systemName: "chevron.right").foregroundStyle(Theme.accent)
                    TextField("e.g. set sub-scale 1.2  ·  script-binding stats/display-stats-toggle", text: $text)
                        .font(.system(.subheadline, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit(run)
                    Button("Run", action: run).fontWeight(.semibold).tint(Theme.accent)
                    Button { ui.showConsole = false } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(14)
            .glass(cornerRadius: 20)
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
        .onAppear { focused = true }
    }

    private func run() {
        let cmd = text.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return }
        if model.run(command: cmd) {
            var h = historyRaw.split(separator: "\n").map(String.init).filter { $0 != cmd }
            h.insert(cmd, at: 0)
            historyRaw = h.prefix(20).joined(separator: "\n")
            model.showToast("✓ \(cmd)")
            text = ""
        }
    }
}

/// Named shader chains, offered when all their files are installed.
enum ShaderPresets {
    struct Preset { let name: String; let shaders: [String] }

    static let all: [Preset] = [
        Preset(name: "Anime4K Mode A (Fast)", shaders: ["Anime4K_Clamp_Highlights.glsl", "Anime4K_Restore_CNN_M.glsl", "Anime4K_Upscale_CNN_x2_M.glsl", "Anime4K_AutoDownscalePre_x2.glsl", "Anime4K_AutoDownscalePre_x4.glsl", "Anime4K_Upscale_CNN_x2_S.glsl"]),
        Preset(name: "Anime4K Mode B (Fast)", shaders: ["Anime4K_Clamp_Highlights.glsl", "Anime4K_Restore_CNN_Soft_M.glsl", "Anime4K_Upscale_CNN_x2_M.glsl", "Anime4K_AutoDownscalePre_x2.glsl", "Anime4K_AutoDownscalePre_x4.glsl", "Anime4K_Upscale_CNN_x2_S.glsl"]),
        Preset(name: "Anime4K Mode C (Fast)", shaders: ["Anime4K_Clamp_Highlights.glsl", "Anime4K_Upscale_Denoise_CNN_x2_M.glsl", "Anime4K_AutoDownscalePre_x2.glsl", "Anime4K_AutoDownscalePre_x4.glsl", "Anime4K_Upscale_CNN_x2_S.glsl"]),
        Preset(name: "FSRCNNX x2", shaders: ["FSRCNNX_x2_8-0-4-1.glsl"]),
    ]

    static func available(files: [URL]) -> [Preset] {
        let names = Set(files.map(\.lastPathComponent))
        return all.filter { $0.shaders.allSatisfy(names.contains) }
    }
}
