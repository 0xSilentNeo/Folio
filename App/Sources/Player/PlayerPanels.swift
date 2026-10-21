import SwiftUI

/// Compact media info card (codec, HDR / Dolby Vision, audio format, decoder).
struct InfoCard: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: PlayerUIState
    var ns: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Media info").font(.headline)
                Spacer()
                CloseDot { ui.showInfo = false }
            }
            if let v = model.tracks.first(where: { $0.type == "video" && $0.selected }) {
                row("Video", v.detail)
            }
            row("Picture", model.videoFormat.isEmpty ? "–" : model.videoFormat)
            row("Decoder", model.hwdecCurrent.isEmpty || model.hwdecCurrent == "no" ? "Software" : "Hardware (\(model.hwdecCurrent))")
            if let a = model.tracks.first(where: { $0.type == "audio" && $0.selected }) {
                row("Audio", a.detail)
            }
            if !model.audioOut.isEmpty { row("Audio output", model.audioOut) }
            row("Renderer", model.renderer == .metal ? "Metal (libplacebo)" : "OpenGL ES")
            row("Source", model.item.url)
            Button {
                // The card morphs into the live stats card (matched geometry).
                withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                    ui.showInfo = false
                    ui.showStats = true
                }
            } label: {
                Label("Show live stats", systemImage: "waveform.path.ecg")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).frame(height: 38)
                    .background(.white.opacity(0.12), in: Capsule())
            }
            .buttonStyle(PressStyle(scale: 0.96))
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: 480)
        .glass(cornerRadius: 24)
        .matchedGeometryEffect(id: "statcard", in: ns)
        .padding(.leading, 20).padding(.top, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.55)).frame(width: 82, alignment: .leading)
            Text(v).font(.system(size: 11, weight: .medium, design: .monospaced)).textSelection(.enabled).lineLimit(2)
            Spacer(minLength: 0)
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
            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 18))
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
            model.showToast("Ran: \(cmd)")
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

/// Compact live stats card (our own, instead of mpv's stats.lua overlay):
/// polled once a second off the main thread.
@MainActor
final class StatsModel: ObservableObject {
    struct Line: Identifiable { let id: String; let value: String }
    @Published var lines: [Line] = []
    private var timer: Timer?

    func start(_ client: MPVClient?) {
        stop()
        tick(client)
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick(client) } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick(_ client: MPVClient?) {
        guard let client else { return }
        client.query({ c -> [Line] in
            func s(_ k: String) -> String { c.string(k) ?? "–" }
            var out: [Line] = []
            let w = c.int("video-params/w") ?? 0, h = c.int("video-params/h") ?? 0
            let dw = c.int("dwidth") ?? 0, dh = c.int("dheight") ?? 0
            out.append(Line(id: "Video", value: "\(s("video-codec").split(separator: " ").first.map(String.init) ?? "–") \(w)×\(h)" + (dw != w ? " → \(dw)×\(dh)" : "")))
            let fps = c.double("container-fps") ?? 0, efps = c.double("estimated-vf-fps") ?? 0
            out.append(Line(id: "Frame rate", value: String(format: "%.3f fps (display %.1f)", fps, efps)))
            out.append(Line(id: "Decoder", value: s("hwdec-current") == "no" ? "software" : s("hwdec-current")))
            out.append(Line(id: "Pixel format", value: "\(s("video-params/pixelformat")) · \(s("video-params/primaries")) · \(s("video-params/gamma"))"))
            let drops = c.int("frame-drop-count") ?? 0, vo = c.int("vo-delayed-frame-count") ?? 0
            out.append(Line(id: "Dropped", value: "\(drops) decoder · \(vo) output"))
            let av = c.double("avsync") ?? 0
            out.append(Line(id: "A/V sync", value: String(format: "%+.3f s", av)))
            let br = (c.double("video-bitrate") ?? 0) / 1_000_000
            out.append(Line(id: "Bitrate", value: String(format: "%.1f Mb/s", br)))
            out.append(Line(id: "Audio", value: "\(s("audio-codec-name")) \(s("audio-params/channels")) \(s("audio-params/samplerate")) Hz → \(s("audio-out-params/channels"))"))
            let cache = c.double("demuxer-cache-duration") ?? 0, speed = (c.double("cache-speed") ?? 0) / 1_000_000
            out.append(Line(id: "Cache", value: String(format: "%.0f s ahead · %.1f MB/s", cache, speed)))
            out.append(Line(id: "Shaders", value: (c.string("glsl-shaders") ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).lastPathComponent }.joined(separator: ", ").isEmpty ? "none" : "\((c.string("glsl-shaders") ?? "").split(separator: ":").count) active"))
            return out
        }) { [weak self] lines in self?.lines = lines }
    }
}

/// Small round close button used by the in-player cards.
struct CloseDot: View {
    let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                .frame(width: 28, height: 28).background(.white.opacity(0.15), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .foregroundStyle(.white)
    }
}

struct StatsOverlay: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: PlayerUIState
    var ns: Namespace.ID
    @StateObject private var stats = StatsModel()

    var body: some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Live stats").font(.headline)
                        Spacer()
                        CloseDot { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { ui.showStats = false } }
                    }
                    .padding(.bottom, 4)
                    ForEach(stats.lines) { l in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(l.id).foregroundStyle(.white.opacity(0.55)).frame(width: 82, alignment: .leading)
                            Text(l.value).lineLimit(1)
                        }
                    }
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .padding(16)
                .frame(maxWidth: 480)
                .glass(cornerRadius: 24)
                .matchedGeometryEffect(id: "statcard", in: ns)
                .padding(.leading, 20).padding(.top, 60)
                Spacer()
            }
            Spacer()
        }
        .onAppear { stats.start(model.client) }
        .onDisappear { stats.stop() }
    }
}
