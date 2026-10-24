import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        Group {
            List {
                Section {
                    row("General", "gearshape", .gray) { GeneralSettings() }
                    row("Library", "film.stack", .green) { LibrarySettings() }
                }
                Section {
                    row("Playback", "play.rectangle", .pink) { PlaybackSettings() }
                    row("Audio & Subtitles", "captions.bubble", .orange) { SubtitleAudioSettings() }
                    row("Skip Intro & Credits", "forward.end", .purple) { SkipSettings() }
                    row("Discover", "sparkles.tv", .cyan) { DiscoverSettings() }
                }
                Section {
                    row("Scripts", "chevron.left.forwardslash.chevron.right", .blue) { ScriptsView() }
                    row("Shaders", "wand.and.stars", .indigo) { ShadersView() }
                    row("mpv Config", "slider.horizontal.3", .teal) { MPVConfigSettings() }
                }
                Section {
                    row("Advanced", "gearshape.2", .gray) { AdvancedSettings() }
                }
                Section {
                    HStack {
                        Text("GlassPlayer")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Your mpv folder is in Files → On My iPhone → GlassPlayer → mpv.")
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func row<D: View>(_ title: String, _ icon: String, _ color: Color, @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink(destination: destination) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
    }
}

struct PlaybackSettings: View {
    @ObservedObject private var bar = SeekBarPrefs.shared
    @AppStorage(SettingsKey.resumePlayback) private var resume = true
    @AppStorage(SettingsKey.openTitlePage) private var openTitlePage = true
    @AppStorage(SettingsKey.autoplayNext) private var autoplayNext = true
    @AppStorage(SettingsKey.backgroundAudio) private var backgroundAudio = true
    @AppStorage(SettingsKey.landscapeOnOpen) private var landscapeOnOpen = true
    @AppStorage(SettingsKey.seekStep) private var seekStep = 10
    @AppStorage(SettingsKey.defaultSpeed) private var defaultSpeed = 1.0
    @AppStorage(SettingsKey.holdToSpeed) private var holdToSpeed = true
    @AppStorage(SettingsKey.holdSpeedValue) private var holdSpeedValue = 2.0
    @AppStorage(SettingsKey.pipEnabled) private var pipEnabled = true
    @AppStorage(SettingsKey.pipAuto) private var pipAuto = true
    @AppStorage(SettingsKey.playlistNames) private var playlistNames = "episode"
    @AppStorage(SettingsKey.controlsWidth) private var controlsWidth = 0.8
    @AppStorage(SettingsKey.panelTransition) private var panelTransition = "quick"
    @AppStorage(SettingsKey.upNextEnabled) private var upNext = true
    @AppStorage(SettingsKey.seekBackStep) private var seekBackStep = 10
    @AppStorage(SettingsKey.gestureControl) private var gestures = true

    var body: some View {
        Form {
            Section {
                Toggle("Resume where I left off", isOn: $resume)
                Toggle("Play next file automatically", isOn: $autoplayNext)
                Toggle("Up Next card at the credits", isOn: $upNext)
                Toggle("Open in landscape", isOn: $landscapeOnOpen)
                Toggle("Keep audio playing in background", isOn: $backgroundAudio)
            }
            Section("Gestures") {
                Picker("Forward skip", selection: $seekStep) {
                    ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) s").tag($0) }
                }
                Picker("Backward skip", selection: $seekBackStep) {
                    ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) s").tag($0) }
                }
                Toggle("Swipe for seek, volume & brightness", isOn: $gestures)
                Toggle("Hold to speed up", isOn: $holdToSpeed)
                if holdToSpeed {
                    Picker("Hold speed", selection: $holdSpeedValue) {
                        ForEach([1.5, 2.0, 2.5, 3.0, 4.0], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                    }
                }
                Picker("Default speed", selection: $defaultSpeed) {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                }
            }
            Section {
                Picker("Playlist names", selection: $playlistNames) {
                    Text("Episode number & title").tag("episode")
                    Text("File name").tag("filename")
                }
                Picker("Menu animation", selection: $panelTransition) {
                    Text("Quick").tag("quick")
                    Text("Liquid Glass morph").tag("morphFrozen")
                }
                LabeledContent("Controls width") {
                    Slider(value: $controlsWidth, in: 0.6...1.0, step: 0.05).frame(maxWidth: 170)
                    Text("\(Int(controlsWidth * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            } header: { Text("Player") } footer: {
                Text("Menu animation: Quick opens a panel in a quarter of a second and closes it in less; the Liquid Glass morph is the system's own animation and takes about a second each way. Controls width: how much of the screen the player controls span in landscape. Up Next appears when the credits start (from the file's chapters, IntroDB / TheIntroDB, or AniSkip for anime), otherwise 30 seconds before the end; it counts down only when nothing is known to follow the credits.")
            }
            Section("Progress bar") {
                Picker("Chapter markers", selection: $bar.markerStyle) {
                    Text("Ticks").tag("ticks"); Text("Dots").tag("dots"); Text("Segments").tag("segments"); Text("Hidden").tag("none")
                }
                Picker("Marker colour", selection: $bar.markerColor) {
                    Text("White").tag("white"); Text("Pink").tag("accent"); Text("Yellow").tag("yellow"); Text("Cyan").tag("cyan")
                }
                Toggle("Chapter name while scrubbing", isOn: $bar.showChapterTitle)
                Toggle("Show skip segments", isOn: $bar.showSkipSegments)
            }
            Section {
                Toggle("Picture in Picture", isOn: $pipEnabled)
                Toggle("Start automatically when leaving", isOn: $pipAuto).disabled(!pipEnabled)
            } header: { Text("Picture in Picture") }
        }
        .navigationTitle("Playback")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SubtitleAudioSettings: View {
    @AppStorage(SettingsKey.subLangs) private var subLangs = "eng,en"
    @AppStorage(SettingsKey.audioLangs) private var audioLangs = "jpn,ja,eng,en"
    @AppStorage(SettingsKey.subScale) private var subScale = 1.0
    @AppStorage(SettingsKey.subBold) private var subBold = true
    @AppStorage(SettingsKey.subBox) private var subBox = false
    @AppStorage(SettingsKey.subPos) private var subPos = 100
    @AppStorage(SettingsKey.surroundAudio) private var surround = true
    @AppStorage(SettingsKey.subtitlesDefault) private var subtitlesDefault = "on"
    @AppStorage(SettingsKey.downmixNormalize) private var downmixNormalize = false
    @AppStorage(SettingsKey.lfeInDownmix) private var lfe = false

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    LanguageListEditor(title: "Audio Languages",
                                       explanation: "When a file has several audio tracks, the first language on this list that the file has is played. With none of them, the file's default track plays.",
                                       list: $audioLangs)
                } label: {
                    LabeledContent("Preferred audio language", value: PlaybackLanguage.summary(audioLangs))
                }
                Toggle("Surround & Spatial Audio", isOn: $surround)
                Picker("Downmix volume", selection: $downmixNormalize) {
                    Text("Original").tag(false); Text("Normalized").tag(true)
                }
                Toggle("LFE in stereo downmix", isOn: $lfe)
            } header: { Text("Audio") } footer: {
                Text("Surround: plays Dolby Digital (Plus), TrueHD, Atmos, DTS, DTS-HD MA and DTS:X tracks as 5.1/7.1 to AirPlay or HDMI, and as Spatial Audio on AirPods. Atmos and DTS:X play their surround channels; object metadata isn't rendered.")
            }
            Section {
                Picker("Show subtitles", selection: $subtitlesDefault) {
                    Text("On").tag("on"); Text("Off").tag("off")
                }
                NavigationLink {
                    LanguageListEditor(title: "Subtitle Languages",
                                       explanation: "The first language on this list that the file has subtitles in is shown. Subtitles can always be switched in the player's Tracks menu.",
                                       list: $subLangs)
                } label: {
                    LabeledContent("Preferred subtitle language", value: PlaybackLanguage.summary(subLangs))
                }
                .disabled(subtitlesDefault == "off")
            } header: { Text("Subtitles") } footer: {
                Text("Show subtitles: whether a subtitle track is turned on when a video starts.")
            }
            Section("Subtitle style") {
                LabeledContent("Size") {
                    Slider(value: $subScale, in: 0.5...2.5, step: 0.05).frame(maxWidth: 180)
                    Text("\(Int(subScale * 100))%").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
                Stepper("Position  \(subPos)", value: $subPos, in: 50...150)
                Toggle("Bold", isOn: $subBold)
                Toggle("Background box", isOn: $subBox)
            }
        }
        .navigationTitle("Audio & Subtitles")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SkipSettings: View {
    @AppStorage(SettingsKey.skipEnabled) private var skipEnabled = true
    @AppStorage(SettingsKey.skipAutoIntro) private var autoIntro = false
    @AppStorage(SettingsKey.skipAutoOutro) private var autoOutro = false
    @AppStorage(SettingsKey.skipAutoRecap) private var autoRecap = false
    @AppStorage(SettingsKey.skipAutoPreview) private var autoPreview = false
    @AppStorage(SettingsKey.skipUseChapters) private var useChapters = true
    @AppStorage(SettingsKey.skipInjectChapters) private var injectChapters = true
    @AppStorage(SettingsKey.skipOATLength) private var oatLength = 90.0

    var body: some View {
        Form {
            Section {
                Toggle("Show Skip button", isOn: $skipEnabled)
            } footer: {
                Text("Uses chapters in the file; otherwise IntroDB and TheIntroDB for TV and films (community databases looked up by IMDb id, the ones Infuse uses), and AniSkip / Open Anime Timestamps for anime only.")
            }
            if skipEnabled {
                Section("Skip automatically") {
                    Toggle("Intro", isOn: $autoIntro)
                    Toggle("Outro / credits", isOn: $autoOutro)
                    Toggle("Recap", isOn: $autoRecap)
                    Toggle("Preview", isOn: $autoPreview)
                }
                Section {
                    Toggle("Use file chapters", isOn: $useChapters)
                    Toggle("Add found markers as chapters", isOn: $injectChapters)
                    Stepper("OAT segment length  \(Int(oatLength)) s", value: $oatLength, in: 60...150, step: 5)
                } header: { Text("Sources") } footer: {
                    Text("Added chapters are visible to Lua scripts. Open Anime Timestamps only has start times, so the length is assumed.")
                }
            }
        }
        .navigationTitle("Skip Intro & Credits")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MPVConfigSettings: View {
    var body: some View {
        List {
            NavigationLink { ConfigEditorView(url: MPVFiles.mpvConf, title: "mpv.conf") } label: { Label("mpv.conf", systemImage: "doc.text") }
            NavigationLink { ConfigEditorView(url: MPVFiles.inputConf, title: "input.conf") } label: { Label("input.conf", systemImage: "keyboard") }
            NavigationLink { ScriptOptsView() } label: { Label("script-opts", systemImage: "slider.horizontal.below.square.filled.and.square") }
            NavigationLink { CommandsEditorView() } label: { Label("Player commands", systemImage: "command") }
            NavigationLink { LogView() } label: { Label("Last playback log", systemImage: "text.alignleft") }
        }
        .navigationTitle("mpv Config")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AdvancedSettings: View {
    @AppStorage(SettingsKey.renderer) private var renderer = "metal"
    @AppStorage(SettingsKey.hdrOutput) private var hdr = true
    @AppStorage(SettingsKey.hwdec) private var hwdec = "auto"
    @AppStorage(SettingsKey.cacheMB) private var cacheMB = 150
    @AppStorage(SettingsKey.logLevel) private var logLevel = "info"
    @AppStorage(SettingsKey.flipVideo) private var flipVideo = false
    @State private var picture = PictureMode.current
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Picker("Renderer", selection: $renderer) {
                    Text("Metal").tag("metal")
                    Text("OpenGL ES (compatibility)").tag("gl")
                }
                Picker("Picture", selection: $picture) {
                    ForEach(PictureMode.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: picture) { _, m in PictureMode.current = m }
                Toggle("HDR output", isOn: $hdr).disabled(renderer != "metal")
                Picker("Hardware decoding", selection: $hwdec) {
                    Text("Auto").tag("auto")
                    Text("Copy-back").tag("copy")
                    Text("Off").tag("no")
                }
            } header: { Text("Video") } footer: {
                Text("Picture: Efficient keeps the phone cool (simple scaling, no extra passes). Enhanced runs several extra full-screen passes per frame and uses noticeably more power. Metal uses libplacebo: Dolby Vision, HDR tone mapping and compute shaders. OpenGL ES is the fallback if a device has trouble.")
            }
            Section("Network") {
                Stepper("Cache  \(cacheMB) MB", value: $cacheMB, in: 32...1024, step: 32)
            }
            Section("Troubleshooting") {
                NavigationLink { DiagnosticsView() } label: { Label("Diagnostics & report", systemImage: "stethoscope") }
                Picker("mpv log level", selection: $logLevel) {
                    ForEach(["warn", "info", "v", "debug"], id: \.self) { Text($0).tag($0) }
                }
                if renderer == "gl" { Toggle("Flip video (OpenGL)", isOn: $flipVideo) }
                Button("Clear watch history", role: .destructive) { confirmClear = true }
                    .confirmationDialog("Clear all history and resume positions?", isPresented: $confirmClear, titleVisibility: .visible) {
                        Button("Clear", role: .destructive) { HistoryStore.shared.clear() }
                    }
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
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
                Text("Active shaders apply to every video and can be switched per video from the player's Shaders menu. Compute shaders need the Metal renderer (default).")
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


struct DiagnosticsView: View {
    @State private var tail = ""
    @State private var report: URL?
    @State private var making = false

    var body: some View {
        List {
            Section {
                if let report {
                    ShareLink(item: report) { Label("Share report (.zip)", systemImage: "square.and.arrow.up") }
                } else {
                    Button {
                        making = true
                        DispatchQueue.global(qos: .userInitiated).async {
                            let r = Diagnostics.shared.makeReport()
                            DispatchQueue.main.async { report = r; making = false }
                        }
                    } label: {
                        HStack { Label("Prepare report", systemImage: "doc.zipper"); Spacer(); if making { ProgressView() } }
                    }
                }
            } footer: {
                Text("The report bundles the app log, the last mpv log, crash and hang records and your settings. Passwords, tokens and WebDAV links are removed before anything is written.")
            }
            Section("Recent app log") {
                Text(tail.isEmpty ? "No entries yet." : tail)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
            Section {
                Button("Clear logs", role: .destructive) {
                    for f in [Diagnostics.shared.appLog, Diagnostics.shared.crashLog, Diagnostics.shared.hangLog, Diagnostics.shared.metricLog] {
                        try? FileManager.default.removeItem(at: f)
                    }
                    tail = ""
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let s = (try? String(contentsOf: Diagnostics.shared.appLog, encoding: .utf8)) ?? ""
            tail = s.split(separator: "\n").suffix(80).joined(separator: "\n")
        }
    }
}


struct DiscoverSettings: View {
    @AppStorage("tmdbApiKey") private var tmdbKey = ""
    @AppStorage(IMDbSource.Key.language) private var language = "en-US"
    @AppStorage(IMDbSource.Key.minVotes) private var minVotes = 25000
    @AppStorage(IMDbSource.Key.animeJapan) private var animeJapan = true
    @State private var showPlatforms = false
    @State private var cleared = false

    var body: some View {
        Form {
            Section {
                TextField("Language (e.g. en-US, de-DE, ja-JP)", text: $language)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("Top Rated: minimum votes", selection: $minVotes) {
                    ForEach([1000, 5000, 10000, 25000, 50000, 100000], id: \.self) { Text($0.formatted()).tag($0) }
                }
                Toggle("Anime = animation from Japan", isOn: $animeJapan)
                Button(cleared ? "Cache cleared" : "Clear IMDb cache") { IMDbSource.clearCache(); cleared = true }.disabled(cleared)
            } header: { Text("IMDb (built in)") } footer: {
                Text("Titles, posters, synopses, ratings, charts and episode lists are read from IMDb's own pages — the same numbers you see on imdb.com. Trending is IMDb's Most Popular list; Top Rated is the Top 250 (with a genre: IMDb's user-rating ranking with at least the chosen number of votes). Language changes titles and synopses where IMDb has translations.")
            }
            Section {
                SecureField("TMDB API key (v3)", text: $tmdbKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if !tmdbKey.isEmpty {
                    Label("Discover uses TMDB instead of IMDb", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.footnote)
                }
            } header: { Text("TMDB (optional)") } footer: {
                Text("Optional alternative source (the database Infuse uses). Free for personal use with your own key; leave empty to use IMDb.")
            }
            Section {
                Button("Streaming services…") { showPlatforms = true }
                NavigationLink("Addons") { AddonsManagerView() }
            }
        }
        .navigationTitle("Discover")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPlatforms) { PlatformSettingsView() }
    }
}


struct GeneralSettings: View {
    @AppStorage(SettingsKey.startupTab) private var startupTab = 0
    @AppStorage(SettingsKey.openTitlePage) private var openTitlePage = true
    @AppStorage(SettingsKey.hideSpoilers) private var hideSpoilers = false
    @AppStorage(SettingsKey.showRatings) private var showRatings = true
    @AppStorage(SettingsKey.castPosition) private var castPosition = "bottom"

    var body: some View {
        Form {
            Section {
                Picker("Startup page", selection: $startupTab) {
                    Label("Home", systemImage: "play.rectangle.fill").tag(0)
                    Label("Discover", systemImage: "sparkles.tv").tag(1)
                    Label("Network", systemImage: "externaldrive.connected.to.line.below").tag(2)
                }
                Toggle("Open title page on tap", isOn: $openTitlePage)
            }
            Section {
                Toggle("Hide spoilers", isOn: $hideSpoilers)
                Toggle("Show IMDb ratings", isOn: $showRatings)
                Picker("Cast on title pages", selection: $castPosition) {
                    Text("Above the episodes").tag("top")
                    Text("At the bottom").tag("bottom")
                }
            } footer: {
                Text("Hide spoilers blurs the pictures and hides the synopsis of episodes you haven't finished.")
            }
        }
        .navigationTitle("General")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LibrarySettings: View {
    @ObservedObject private var store = LocalMediaStore.shared
    @AppStorage(SettingsKey.metadataFetching) private var fetching = true
    @AppStorage(SettingsKey.tileArtwork) private var tileArtwork = "poster"
    @State private var cacheBytes: Int64 = 0
    @State private var working = false

    private var counts: (movies: Int, episodes: Int, other: Int) {
        var m = 0, e = 0, o = 0
        let audio: Set<String> = ["mp3", "flac", "m4a", "aac", "ogg", "opus", "wav", "alac", "wma", "ape", "mka"]
        for f in store.files {
            if audio.contains(f.pathExtension.lowercased()) { o += 1 }
            else if TitleParser.parse(f.lastPathComponent).episode != nil { e += 1 }
            else { m += 1 }
        }
        return (m, e, o)
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    stat(counts.movies, "Movies")
                    stat(counts.episodes, "TV Episodes")
                    stat(counts.other, "Other")
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            Section {
                Button("Scan for changes") { store.refresh() }
                Button("Refresh metadata") {
                    working = true
                    Task {
                        await MetadataService.shared.clear()
                        ImageCache.shared.clear()
                        store.refresh()
                        await measure()
                        working = false
                    }
                }
                .disabled(!fetching || working)
            } footer: { Text("Refresh metadata looks every title up again (posters, synopsis, ratings, episode names).") }
            Section {
                Toggle("Metadata fetching", isOn: $fetching)
                Picker("Tile artwork", selection: $tileArtwork) {
                    Text("Poster").tag("poster")
                    Text("Episode still").tag("still")
                    Text("Last frame watched").tag("frame")
                }
                HStack {
                    Text("Library cache")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file)).foregroundStyle(.secondary)
                    Button(role: .destructive) {
                        ImageCache.shared.clear()
                        Task { await measure() }
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                }
            } header: { Text("Metadata & artwork") } footer: {
                Text("Titles, posters and episode names come from IMDb, looked up from the file names and kept on this device. The cache holds downloaded artwork; it refills as you browse.")
            }
        }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .task { await measure() }
    }

    private func stat(_ n: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(n)").font(.title.weight(.bold)).monospacedDigit()
            Text(label).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func measure() async {
        let art = await Task.detached { ImageCache.shared.diskSize() }.value
        let meta = await MetadataService.shared.fileSize
        cacheBytes = art + meta
    }
}
