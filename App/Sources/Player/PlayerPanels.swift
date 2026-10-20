import SwiftUI

/// Compact media info card (codec, HDR / Dolby Vision, audio format, decoder).
struct InfoCard: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: PlayerUIState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Media Info").font(.headline)
                Spacer()
                Button { ui.showInfo = false } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.white.opacity(0.6))
                }
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
                model.run(command: "script-binding stats/display-stats-toggle")
                ui.showInfo = false
            } label: {
                Label("mpv stats overlay", systemImage: "chart.bar.xaxis")
                    .font(.subheadline.weight(.semibold))
            }
            .tint(Theme.accent)
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: 420)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 20))
        .padding(20)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.caption).foregroundStyle(.white.opacity(0.55)).frame(width: 96, alignment: .leading)
            Text(v).font(.caption).textSelection(.enabled).lineLimit(3)
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
