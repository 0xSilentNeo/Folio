import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage(SettingsKey.hwdec) private var hwdec = "auto"
    @AppStorage(SettingsKey.resumePlayback) private var resume = true
    @AppStorage(SettingsKey.defaultSpeed) private var defaultSpeed = 1.0
    @AppStorage(SettingsKey.seekStep) private var seekStep = 10
    @AppStorage(SettingsKey.autoplayNext) private var autoplayNext = true
    @AppStorage(SettingsKey.backgroundAudio) private var backgroundAudio = true
    @AppStorage(SettingsKey.holdToSpeed) private var holdToSpeed = true
    @AppStorage(SettingsKey.holdSpeedValue) private var holdSpeedValue = 2.0
    @AppStorage(SettingsKey.cacheMB) private var cacheMB = 150
    @AppStorage(SettingsKey.landscapeOnOpen) private var landscapeOnOpen = true
    @AppStorage(SettingsKey.pipEnabled) private var pipEnabled = true
    @AppStorage(SettingsKey.pipAuto) private var pipAuto = true
    @AppStorage(SettingsKey.subLangs) private var subLangs = "eng,en"
    @AppStorage(SettingsKey.audioLangs) private var audioLangs = "jpn,ja,eng,en"
    @AppStorage(SettingsKey.subScale) private var subScale = 1.0
    @AppStorage(SettingsKey.subBold) private var subBold = true
    @AppStorage(SettingsKey.subBox) private var subBox = false
    @AppStorage(SettingsKey.subPos) private var subPos = 100
    @AppStorage(SettingsKey.skipEnabled) private var skipEnabled = true
    @AppStorage(SettingsKey.skipAutoIntro) private var autoIntro = false
    @AppStorage(SettingsKey.skipAutoOutro) private var autoOutro = false
    @AppStorage(SettingsKey.skipAutoRecap) private var autoRecap = false
    @AppStorage(SettingsKey.skipAutoPreview) private var autoPreview = false
    @AppStorage(SettingsKey.skipUseChapters) private var useChapters = true
    @AppStorage(SettingsKey.skipInjectChapters) private var injectChapters = true
    @AppStorage(SettingsKey.skipOATLength) private var oatLength = 90.0
    @AppStorage(SettingsKey.flipVideo) private var flipVideo = false
    @AppStorage(SettingsKey.logLevel) private var logLevel = "info"
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section("mpv") {
                    NavigationLink { ScriptsView() } label: { Label("Scripts", systemImage: "chevron.left.forwardslash.chevron.right") }
                    NavigationLink { ShadersView() } label: { Label("Shaders", systemImage: "wand.and.stars") }
                    NavigationLink { CommandsEditorView() } label: { Label("Commands", systemImage: "command") }
                    NavigationLink { ConfigEditorView(url: MPVFiles.mpvConf, title: "mpv.conf") } label: { Label("mpv.conf", systemImage: "doc.text") }
                    NavigationLink { ConfigEditorView(url: MPVFiles.inputConf, title: "input.conf") } label: { Label("input.conf", systemImage: "keyboard") }
                    NavigationLink { ScriptOptsView() } label: { Label("script-opts", systemImage: "slider.horizontal.3") }
                    NavigationLink { LogView() } label: { Label("Last playback log", systemImage: "text.alignleft") }
                }

                Section {
                    Picker("Hardware decoding", selection: $hwdec) {
                        Text("Auto (VideoToolbox)").tag("auto")
                        Text("VideoToolbox (copy)").tag("copy")
                        Text("Off (software)").tag("no")
                    }
                    Toggle("Resume where I left off", isOn: $resume)
                    Toggle("Autoplay next file", isOn: $autoplayNext)
                    Toggle("Keep playing audio in background", isOn: $backgroundAudio)
                    Toggle("Rotate to landscape on open", isOn: $landscapeOnOpen)
                    Picker("Double-tap / skip step", selection: $seekStep) {
                        ForEach([5, 10, 15, 30, 45, 60, 90], id: \.self) { Text("\($0) s").tag($0) }
                    }
                    Picker("Default speed", selection: $defaultSpeed) {
                        ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { Text(String(format: "%gx", $0)).tag($0) }
                    }
                    Toggle("Hold to speed up", isOn: $holdToSpeed)
                    if holdToSpeed {
                        Picker("Hold speed", selection: $holdSpeedValue) {
                            ForEach([1.5, 2.0, 2.5, 3.0, 4.0], id: \.self) { Text(String(format: "%gx", $0)).tag($0) }
                        }
                    }
                    Stepper("Network cache: \(cacheMB) MB", value: $cacheMB, in: 32...1024, step: 32)
                } header: { Text("Playback") } footer: {
                    Text("Options in mpv.conf override these.")
                }

                Section {
                    Toggle("Picture in Picture", isOn: $pipEnabled)
                    Toggle("Start PiP when leaving the app", isOn: $pipAuto).disabled(!pipEnabled)
                } header: { Text("Picture in Picture") } footer: {
                    Text("iOS doesn't allow GPU rendering in the background, so during PiP mpv switches to its CPU renderer (shaders pause; very high bitrates may stutter).")
                }

                Section {
                    TextField("Preferred subtitle languages", text: $subLangs).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Preferred audio languages", text: $audioLangs).textInputAutocapitalization(.never).autocorrectionDisabled()
                    VStack(alignment: .leading) {
                        Text("Subtitle size: \(Int(subScale * 100))%")
                        Slider(value: $subScale, in: 0.5...2.5, step: 0.05).tint(Theme.accent)
                    }
                    Stepper("Subtitle position: \(subPos)", value: $subPos, in: 50...150)
                    Toggle("Bold subtitles", isOn: $subBold)
                    Toggle("Background box", isOn: $subBox)
                } header: { Text("Subtitles & audio") } footer: {
                    Text("Comma-separated language codes, e.g. eng,en or jpn,ja. Put extra fonts in mpv/fonts.")
                }

                Section {
                    Toggle("Detect intro / outro", isOn: $skipEnabled)
                    if skipEnabled {
                        Toggle("Use chapters in the file", isOn: $useChapters)
                        Toggle("Add found markers as chapters", isOn: $injectChapters)
                        Toggle("Auto-skip intro", isOn: $autoIntro)
                        Toggle("Auto-skip outro / credits", isOn: $autoOutro)
                        Toggle("Auto-skip recap", isOn: $autoRecap)
                        Toggle("Auto-skip preview", isOn: $autoPreview)
                        Stepper("OAT opening/ending length: \(Int(oatLength)) s", value: $oatLength, in: 60...150, step: 5)
                    }
                } header: { Text("Skip intro") } footer: {
                    Text("Looks up anime via AniList → ids.moe, then AniSkip (exact start/end) with Open Anime Timestamps as fallback (start times only, so the length above is assumed). Added chapters are visible to your Lua scripts too.")
                }

                Section("Advanced") {
                    Picker("Log level", selection: $logLevel) {
                        ForEach(["warn", "info", "v", "debug"], id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("Flip video vertically (fix upside-down output)", isOn: $flipVideo)
                    Button("Clear watch history", role: .destructive) { confirmClear = true }
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                    LabeledContent("Engine", value: "libmpv · FFmpeg · libass · libplacebo")
                    Text("mpv folder: Files app → On My iPhone → GlassPlayer → mpv")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Clear all history and resume positions?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear", role: .destructive) { HistoryStore.shared.clear() }
            }
        }
    }
}

// MARK: - Scripts

struct ScriptsView: View {
    @State private var scripts: [MPVFiles.Script] = []
    @State private var importing = false
    @State private var showURL = false
    @State private var remoteURL = ""
    @State private var message: String?

    var body: some View {
        List {
            Section {
                ForEach(scripts) { s in
                    HStack {
                        Image(systemName: s.isDirectory ? "folder" : "doc.text").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading) {
                            Text(s.name).font(.body.monospaced())
                            if !s.enabled { Text("Disabled").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { s.enabled }, set: { on in
                            try? MPVFiles.setEnabled(s, on)
                            reload()
                        }))
                        .labelsHidden()
                    }
                    .contextMenu {
                        if !s.isDirectory {
                            NavigationLink { ConfigEditorView(url: s.url, title: s.name, monospaced: true) } label: { Label("Edit", systemImage: "pencil") }
                        }
                    }
                }
                .onDelete { idx in
                    for i in idx { try? FileManager.default.removeItem(at: scripts[i].url) }
                    reload()
                }
                if scripts.isEmpty {
                    Text("No scripts yet.").foregroundStyle(.secondary)
                }
            } header: { Text("Installed") } footer: {
                Text("Scripts load at the start of every playback. Changes apply to the next file you open.")
            }

            Section {
                Button { importing = true } label: { Label("Import .lua files…", systemImage: "square.and.arrow.down") }
                Button { showURL = true } label: { Label("Install from URL…", systemImage: "link") }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("Add") } footer: {
                Text("""
                Works: mp.* API, observers, timers, OSD/overlays, script-message, key bindings (hardware keyboard or Settings → Commands).
                Doesn't work on iOS: mp.utils.subprocess, io.popen, os.execute (no curl/yt-dlp), JavaScript scripts, mouse-only UIs.
                You can also drop scripts into Files → GlassPlayer → mpv → scripts.
                """)
            }
        }
        .navigationTitle("Scripts")
        .onAppear(perform: reload)
        .toolbar { EditButton() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            var n = 0
            for u in urls {
                let dir = u.pathExtension.lowercased() == "conf" ? MPVFiles.scriptOptsDir : MPVFiles.scriptsDir
                if (try? MPVFiles.importItem(from: u, into: dir)) != nil { n += 1 }
            }
            message = "Imported \(n) file\(n == 1 ? "" : "s")."
            reload()
        }
        .alert("Install script from URL", isPresented: $showURL) {
            TextField("https://raw.githubusercontent.com/…/script.lua", text: $remoteURL)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Install") {
                guard let u = URL(string: remoteURL) else { return }
                Task {
                    do {
                        let dest = try await MPVFiles.download(u, into: MPVFiles.scriptsDir)
                        message = "Installed \(dest.lastPathComponent)"
                    } catch {
                        message = "Download failed: \(error.localizedDescription)"
                    }
                    remoteURL = ""
                    reload()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("GitHub file links are converted to raw links automatically.")
        }
    }

    private func reload() { scripts = MPVFiles.scripts() }
}

struct ScriptOptsView: View {
    @State private var files: [URL] = []
    @State private var newName = ""
    @State private var showNew = false

    var body: some View {
        List {
            ForEach(files, id: \.self) { f in
                NavigationLink { ConfigEditorView(url: f, title: f.lastPathComponent) } label: {
                    Text(f.lastPathComponent).font(.body.monospaced())
                }
            }
            .onDelete { idx in
                for i in idx { try? FileManager.default.removeItem(at: files[i]) }
                files = MPVFiles.scriptOptFiles()
            }
            if files.isEmpty { Text("No option files. Create one named after the script, e.g. stats.conf.").foregroundStyle(.secondary) }
        }
        .navigationTitle("script-opts")
        .onAppear { files = MPVFiles.scriptOptFiles() }
        .toolbar {
            Button { showNew = true } label: { Image(systemName: "plus") }
        }
        .alert("New option file", isPresented: $showNew) {
            TextField("scriptname", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Create") {
                let name = newName.hasSuffix(".conf") ? newName : newName + ".conf"
                let url = MPVFiles.scriptOptsDir.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: url.path) { try? MPVFiles.writeText("# \(name)\n", to: url) }
                newName = ""
                files = MPVFiles.scriptOptFiles()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Shaders

struct ShaderCatalog {
    struct Entry: Identifiable { var id: String { file }; let file: String; let url: String; let group: String }
    static let base = "https://raw.githubusercontent.com/bloc97/Anime4K/master/glsl/"
    static let entries: [Entry] = [
        Entry(file: "Anime4K_Clamp_Highlights.glsl", url: base + "Restore/Anime4K_Clamp_Highlights.glsl", group: "Anime4K"),
        Entry(file: "Anime4K_Restore_CNN_M.glsl", url: base + "Restore/Anime4K_Restore_CNN_M.glsl", group: "Anime4K"),
        Entry(file: "Anime4K_Restore_CNN_Soft_M.glsl", url: base + "Restore/Anime4K_Restore_CNN_Soft_M.glsl", group: "Anime4K"),
        Entry(file: "Anime4K_Upscale_CNN_x2_M.glsl", url: base + "Upscale/Anime4K_Upscale_CNN_x2_M.glsl", group: "Anime4K"),
        Entry(file: "Anime4K_Upscale_CNN_x2_S.glsl", url: base + "Upscale/Anime4K_Upscale_CNN_x2_S.glsl", group: "Anime4K"),
        Entry(file: "Anime4K_Upscale_Denoise_CNN_x2_M.glsl", url: base + "Upscale+Denoise/Anime4K_Upscale_Denoise_CNN_x2_M.glsl", group: "Anime4K"),
        Entry(file: "Anime4K_AutoDownscalePre_x2.glsl", url: base + "Upscale/Anime4K_AutoDownscalePre_x2.glsl", group: "Anime4K"),
        Entry(file: "Anime4K_AutoDownscalePre_x4.glsl", url: base + "Upscale/Anime4K_AutoDownscalePre_x4.glsl", group: "Anime4K"),
        Entry(file: "FSRCNNX_x2_8-0-4-1.glsl", url: "https://github.com/igv/FSRCNN-TensorFlow/releases/download/1.1/FSRCNNX_x2_8-0-4-1.glsl", group: "FSRCNNX"),
    ]
}

struct ShadersView: View {
    @State private var files: [URL] = []
    @State private var active: [String] = MPVFiles.activeShaderNames
    @State private var importing = false
    @State private var downloading: Set<String> = []
    @State private var showURL = false
    @State private var remoteURL = ""
    @State private var message: String?

    var body: some View {
        List {
            Section {
                ForEach(files, id: \.self) { f in
                    let name = f.lastPathComponent
                    let idx = active.firstIndex(of: name)
                    Button {
                        if let idx { active.remove(at: idx) } else { active.append(name) }
                        MPVFiles.activeShaderNames = active
                    } label: {
                        HStack {
                            Text(name).font(.footnote.monospaced()).foregroundStyle(.primary)
                            Spacer()
                            if let idx {
                                Text("#\(idx + 1)").font(.caption.weight(.bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 8).padding(.vertical, 3).background(Theme.accent, in: Capsule())
                            }
                        }
                    }
                }
                .onDelete { idx in
                    for i in idx {
                        try? FileManager.default.removeItem(at: files[i])
                        active.removeAll { $0 == files[i].lastPathComponent }
                    }
                    MPVFiles.activeShaderNames = active
                    reload()
                }
                if files.isEmpty { Text("No shaders installed.").foregroundStyle(.secondary) }
                if !active.isEmpty {
                    Button("Turn all off", role: .destructive) { active = []; MPVFiles.activeShaderNames = [] }
                }
            } header: { Text("Installed — tap to toggle, order = apply order") } footer: {
                Text("Active shaders apply to every video and can be switched per video from the player's Shaders menu. Compute shaders are not supported (OpenGL ES 3.0).")
            }

            Section("Download") {
                ForEach(ShaderCatalog.entries) { e in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(e.file).font(.footnote.monospaced())
                            Text(e.group).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if files.contains(where: { $0.lastPathComponent == e.file }) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                        } else if downloading.contains(e.file) {
                            ProgressView()
                        } else {
                            Button { download(e) } label: { Image(systemName: "arrow.down.circle") }
                        }
                    }
                }
                Button("Download all Anime4K + FSRCNNX") {
                    for e in ShaderCatalog.entries where !files.contains(where: { $0.lastPathComponent == e.file }) { download(e) }
                }
            }

            Section {
                Button { importing = true } label: { Label("Import shader files…", systemImage: "square.and.arrow.down") }
                Button { showURL = true } label: { Label("Install from URL…", systemImage: "link") }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Shaders")
        .onAppear(perform: reload)
        .toolbar { EditButton() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for u in urls { _ = try? MPVFiles.importItem(from: u, into: MPVFiles.shadersDir) }
            reload()
        }
        .alert("Install shader from URL", isPresented: $showURL) {
            TextField("https://…/shader.glsl", text: $remoteURL).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Install") {
                guard let u = URL(string: remoteURL) else { return }
                Task {
                    do { let d = try await MPVFiles.download(u, into: MPVFiles.shadersDir); message = "Installed \(d.lastPathComponent)" }
                    catch { message = "Download failed: \(error.localizedDescription)" }
                    remoteURL = ""
                    reload()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func download(_ e: ShaderCatalog.Entry) {
        guard let u = URL(string: e.url) else { return }
        downloading.insert(e.file)
        Task {
            _ = try? await MPVFiles.download(u, into: MPVFiles.shadersDir, filename: e.file)
            downloading.remove(e.file)
            reload()
        }
    }

    private func reload() {
        files = MPVFiles.shaders()
        active = MPVFiles.activeShaderNames
    }
}

// MARK: - Commands

struct CommandsEditorView: View {
    @State private var commands = ScriptCommandStore.all
    @State private var editing: ScriptCommand?

    var body: some View {
        List {
            Section {
                ForEach(commands) { c in
                    Button { editing = c } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name).foregroundStyle(.primary)
                            Text(c.command).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { commands.remove(atOffsets: $0); save() }
                .onMove { commands.move(fromOffsets: $0, toOffset: $1); save() }
                Button { editing = ScriptCommand(name: "", command: "") } label: { Label("Add command", systemImage: "plus") }
            } footer: {
                Text("Shown in the player's Commands menu. Use input.conf syntax, e.g. script-binding uosc/menu, script-message-to myscript action, cycle-values sub-scale 1 1.3 1.6, or several separated by ;")
            }
            Section {
                Button("Restore defaults") { commands = ScriptCommandStore.defaults; save() }
            }
        }
        .navigationTitle("Commands")
        .toolbar { EditButton() }
        .sheet(item: $editing) { c in
            CommandEditSheet(command: c) { updated in
                if let i = commands.firstIndex(where: { $0.id == updated.id }) { commands[i] = updated } else { commands.append(updated) }
                save()
            }
        }
    }

    private func save() { ScriptCommandStore.all = commands }
}

struct CommandEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var command: ScriptCommand
    let onSave: (ScriptCommand) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $command.name)
                TextField("mpv command", text: $command.command, axis: .vertical)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            .navigationTitle(command.name.isEmpty ? "New Command" : command.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(command); dismiss() }.disabled(command.name.isEmpty || command.command.isEmpty)
                }
            }
        }
    }
}

// MARK: - Text editors

struct ConfigEditorView: View {
    let url: URL
    let title: String
    var monospaced = true
    @State private var text = ""
    @State private var saved = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TextEditor(text: $text)
            .font(monospaced ? .system(.footnote, design: .monospaced) : .body)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { text = MPVFiles.readText(url) }
            .onChange(of: text) { _, _ in saved = false }
            .toolbar {
                Button(saved ? "Saved" : "Save") {
                    try? MPVFiles.writeText(text, to: url)
                    saved = true
                }
                .disabled(saved)
            }
            .onDisappear { if !saved { try? MPVFiles.writeText(text, to: url) } }
    }
}

struct LogView: View {
    @State private var text = ""
    @State private var errorsOnly = false

    var body: some View {
        ScrollView {
            Text(shown.isEmpty ? "No log yet — play something first." : shown)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(Theme.background)
        .navigationTitle("Last log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle(isOn: $errorsOnly) { Image(systemName: "exclamationmark.triangle") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: MPVFiles.logFile) { Image(systemName: "square.and.arrow.up") }
            }
        }
        .onAppear {
            let full = MPVFiles.readText(MPVFiles.logFile)
            // Keep the view responsive on huge logs.
            text = full.count > 400_000 ? String(full.suffix(400_000)) : full
        }
    }

    private var shown: String {
        guard errorsOnly else { return text }
        return text.split(separator: "\n").filter {
            let l = $0.lowercased()
            return l.contains("[e]") || l.contains("[w]") || l.contains("error") || l.contains("fail") || l.contains("lua")
        }.joined(separator: "\n")
    }
}
