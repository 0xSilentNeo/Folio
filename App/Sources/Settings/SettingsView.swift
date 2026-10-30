import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zoomsFromTile) private var zooms
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
                    row("Downloads", "arrow.down.circle", .mint) { DownloadSettingsView() }
                }
                Section {
                    row("mpv", "slider.horizontal.3", .teal) { MPVSettings() }
                } footer: {
                    Text("The video engine, scripts, shaders and config files.")
                }
                Section {
                    row("Presets", "square.and.arrow.down.on.square", .blue) { PresetsView() }
                    row("Help & Diagnostics", "stethoscope", .gray) { AdvancedSettings() }
                }
                Section {
                    HStack {
                        HStack(spacing: 8) {
                            FolioLeaf().frame(width: 22, height: 22)
                            Wordmark(size: 15)
                        }
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Your mpv folder is in Files → On My iPhone → Folio → mpv.")
                }
            }
            .brandListBackground()
            .background(TopEdgeNoBounce().frame(width: 0, height: 0).accessibilityHidden(true))
            .pageChrome(zooms: zooms, title: "Settings", back: { dismiss() }) { EmptyView() }
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
    @AppStorage(SettingsKey.stayLandscape) private var stayLandscape = false
    @AppStorage(SettingsKey.seekStep) private var seekStep = 10
    @AppStorage(SettingsKey.defaultSpeed) private var defaultSpeed = 1.0
    @AppStorage(SettingsKey.holdToSpeed) private var holdToSpeed = true
    @AppStorage(SettingsKey.holdSpeedValue) private var holdSpeedValue = 2.0
    @AppStorage(SettingsKey.pipEnabled) private var pipEnabled = true
    @AppStorage(SettingsKey.pipAuto) private var pipAuto = true
    @AppStorage(SettingsKey.pipReturnOnOpen) private var pipReturnOnOpen = true
    @AppStorage(SettingsKey.playlistNames) private var playlistNames = "episode"
    @AppStorage(SettingsKey.controlsWidth) private var controlsWidth = 0.8
    @AppStorage(SettingsKey.nativePanelMorph) private var nativePanelMorph = true
    @AppStorage(SettingsKey.prepareNext) private var prepareNext = true
    @AppStorage(SettingsKey.upNextEnabled) private var upNext = true
    @AppStorage(SettingsKey.seekBackStep) private var seekBackStep = 10
    @AppStorage(SettingsKey.gestureControl) private var gestures = true

    var body: some View {
        Form {
            Section {
                Explained("Every video starts where you stopped it last time.") {
                    Toggle("Resume where I left off", isOn: $resume)
                }
                Explained("When an episode ends, or the Up Next countdown runs out, the next one in the list starts.") {
                    Toggle("Play next file automatically", isOn: $autoplayNext)
                }
                Explained("A card with the next episode appears when the credits start (from the file's chapters or online skip data), otherwise 30 seconds before the end. It counts down only when nothing is known to follow the credits.") {
                    Toggle("Up Next card at the credits", isOn: $upNext)
                }
                Explained("For streamed episodes (addons, WebDAV): near the end of an episode the next one is found and starts loading, so Play on the Up Next card starts it right away. For a season from an addon, the app also checks which episodes have the same release, and asks you to pick for the ones that don't. Note: this opens the next episode's link early, so your debrid service adds that episode even if you don't watch it.") {
                    Toggle("Get the next episode ready", isOn: $prepareNext)
                }
            }
            Section {
                Explained("The screen turns to landscape when a landscape video starts.") {
                    Toggle("Open in landscape", isOn: $landscapeOnOpen)
                }
                Explained("Playback stays in landscape even when you hold the phone upright (it still flips between the two landscape sides).") {
                    Toggle("Stay in landscape", isOn: $stayLandscape)
                }
                Explained("The sound keeps playing when you leave the app or lock the phone; the picture comes back when you return.") {
                    Toggle("Keep audio playing in background", isOn: $backgroundAudio)
                }
            }
            Section("Gestures") {
                Explained("How far a double-tap on the right side of the video and the forward button jump.") {
                    Picker("Forward skip", selection: $seekStep) {
                        ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) s").tag($0) }
                    }
                }
                Explained("How far a double-tap on the left side and the back button jump.") {
                    Picker("Backward skip", selection: $seekBackStep) {
                        ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) s").tag($0) }
                    }
                }
                Explained("Swipe sideways to scrub; swipe up or down along the left edge for brightness and along the right edge for volume.") {
                    Toggle("Swipe for seek, volume & brightness", isOn: $gestures)
                }
                Explained("Press and hold the video to play faster until you let go.") {
                    Toggle("Hold to speed up", isOn: $holdToSpeed)
                }
                if holdToSpeed {
                    Picker("Hold speed", selection: $holdSpeedValue) {
                        ForEach([1.5, 2.0, 2.5, 3.0, 4.0], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                    }
                }
                Explained("The speed every video starts at.") {
                    Picker("Default speed", selection: $defaultSpeed) {
                        ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                    }
                }
            }
            Section("Player") {
                Explained("How episodes are listed in the player's Now Playing menu.") {
                    Picker("Playlist names", selection: $playlistNames) {
                        Text("Episode number & title").tag("episode")
                        Text("File name").tag("filename")
                    }
                }
                if #available(iOS 26.0, *) {
                    Explained("The player's menus grow out of their button with Apple's own glass animation. Off: the app's own glass menus, which can be interrupted at any moment.") {
                        Toggle("Native menu morph", isOn: $nativePanelMorph)
                    }
                }
                Explained("How much of the screen's width the controls use in landscape.") {
                    LabeledContent("Controls width") {
                        Slider(value: $controlsWidth, in: 0.6...1.0, step: 0.05).frame(maxWidth: 170)
                        Text("\(Int(controlsWidth * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }
            Section("Progress bar") {
                Explained("How chapters show on the progress bar.") {
                    Picker("Chapter markers", selection: $bar.markerStyle) {
                        Text("Ticks").tag("ticks"); Text("Dots").tag("dots"); Text("Segments").tag("segments"); Text("Hidden").tag("none")
                    }
                }
                Picker("Marker colour", selection: $bar.markerColor) {
                    Text("White").tag("white"); Text("Pink").tag("accent"); Text("Yellow").tag("yellow"); Text("Cyan").tag("cyan")
                }
                Explained("While you drag along the progress bar, the name of the chapter under your finger shows.") {
                    Toggle("Chapter name while scrubbing", isOn: $bar.showChapterTitle)
                }
                Explained("Intros, credits, recaps and previews are marked on the progress bar.") {
                    Toggle("Show skip segments", isOn: $bar.showSkipSegments)
                }
            }
            Section("Picture in Picture") {
                Explained("The video can keep playing in a small floating window over other apps.") {
                    Toggle("Picture in Picture", isOn: $pipEnabled)
                }
                Explained("Going to the Home Screen while a video plays opens Picture in Picture by itself.") {
                    Toggle("Start automatically when leaving", isOn: $pipAuto).disabled(!pipEnabled)
                }
                Explained("Opening the app while Picture in Picture is up closes the small window and carries on in the player.") {
                    Toggle("Back to the player when you open the app", isOn: $pipReturnOnOpen).disabled(!pipEnabled)
                }
            }
        }
        .brandListBackground()
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
                Explained("Plays Dolby Digital (Plus), TrueHD, Atmos, DTS, DTS-HD MA and DTS:X tracks as 5.1/7.1 to AirPlay or HDMI, and as Spatial Audio on AirPods. Atmos and DTS:X play their surround channels; object metadata isn't used. Off: always stereo.") {
                    Toggle("Surround & Spatial Audio", isOn: $surround)
                }
                Explained(downmixNormalize
                          ? "Normalized: surround sound mixed down to stereo never distorts, but plays quieter."
                          : "Original: surround sound mixed down to stereo keeps its full loudness; very loud scenes can distort.") {
                    Picker("Downmix volume", selection: $downmixNormalize) {
                        Text("Original").tag(false); Text("Normalized").tag(true)
                    }
                }
                Explained("Mixes the subwoofer channel into stereo, for more bass when surround sound plays on headphones or two speakers.") {
                    Toggle("LFE in stereo downmix", isOn: $lfe)
                }
            } header: { Text("Audio") }
            Section {
                Explained("Whether a subtitle track is turned on when a video starts. You can always switch in the player's Tracks menu.") {
                    Picker("Show subtitles", selection: $subtitlesDefault) {
                        Text("On").tag("on"); Text("Off").tag("off")
                    }
                }
                NavigationLink {
                    LanguageListEditor(title: "Subtitle Languages",
                                       explanation: "The first language on this list that the file has subtitles in is shown. Subtitles can always be switched in the player's Tracks menu.",
                                       list: $subLangs)
                } label: {
                    LabeledContent("Preferred subtitle language", value: PlaybackLanguage.summary(subLangs))
                }
                .disabled(subtitlesDefault == "off")
            } header: { Text("Subtitles") }
            Section("Subtitle style") {
                LabeledContent("Size") {
                    Slider(value: $subScale, in: 0.5...2.5, step: 0.05).frame(maxWidth: 180)
                    Text("\(Int(subScale * 100))%").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
                Explained("100 is the normal place near the bottom; lower numbers move subtitles up, higher numbers further down.") {
                    Stepper("Position  \(subPos)", value: $subPos, in: 50...150)
                }
                Toggle("Bold", isOn: $subBold)
                Explained("A dark box behind the text keeps subtitles readable on bright scenes.") {
                    Toggle("Background box", isOn: $subBox)
                }
            }
        }
        .brandListBackground()
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
                Explained("A Skip button appears during intros, credits, recaps and previews. They come from the file's chapters; otherwise from IntroDB and TheIntroDB for TV and films (community databases looked up by IMDb id), and AniSkip / Open Anime Timestamps for anime.") {
                    Toggle("Show Skip button", isOn: $skipEnabled)
                }
            }
            if skipEnabled {
                Section {
                    Toggle("Intro", isOn: $autoIntro)
                    Toggle("Outro / credits", isOn: $autoOutro)
                    Toggle("Recap", isOn: $autoRecap)
                    Toggle("Preview", isOn: $autoPreview)
                } header: { Text("Skip automatically") } footer: {
                    Text("Skipped without a tap, once per episode. Seeking back into a part doesn't skip it again.")
                }
                Section("Sources") {
                    Explained("Files that name their chapters (Opening, Ending, Credits…) are skipped by those chapters first.") {
                        Toggle("Use file chapters", isOn: $useChapters)
                    }
                    Explained("Intros and credits found online show as chapters too: on the progress bar, in Now Playing, and to Lua scripts.") {
                        Toggle("Add found markers as chapters", isOn: $injectChapters)
                    }
                    Explained("Open Anime Timestamps only knows where a part starts, so its length is assumed.") {
                        Stepper("OAT segment length  \(Int(oatLength)) s", value: $oatLength, in: 60...150, step: 5)
                    }
                }
            }
        }
        .brandListBackground()
        .navigationTitle("Skip Intro & Credits")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A setting with a plain-language line under it (1.17.0).
struct Explained<Content: View>: View {
    let text: String
    @ViewBuilder var content: Content
    init(_ text: String, @ViewBuilder content: () -> Content) { self.text = text; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Everything mpv in one place (1.17.0): the video engine, scripts, shaders,
/// config files and logs.
struct MPVSettings: View {
    @AppStorage(SettingsKey.renderer) private var renderer = "gl"
    @AppStorage(SettingsKey.hdrOutput) private var hdr = true
    @AppStorage(SettingsKey.hwdec) private var hwdec = "auto"
    @AppStorage(SettingsKey.cacheMB) private var cacheMB = 150
    @AppStorage(SettingsKey.logLevel) private var logLevel = "info"
    @AppStorage(SettingsKey.flipVideo) private var flipVideo = false
    @State private var picture = PictureMode.current

    private var rendererText: String {
        renderer == "gl"
            ? "OpenGL (recommended): every frame goes straight into the picture Picture in Picture shows, as in Outplayer, so PiP starts and ends without a pause. HDR and Dolby Vision show at normal brightness (SDR); no compute shaders."
            : "Metal: mpv's newer renderer, with HDR, Dolby Vision and every shader. Picture in Picture switches renderer as it starts and ends, with a short pause in picture and sound."
    }
    private var pictureText: String {
        switch picture {
        case .efficient: "Efficient: simple scaling with no extra passes. Coolest phone, longest battery; the right choice for most videos."
        case .balanced: "Balanced: a sharper scaler when the video is enlarged. A little more power."
        case .enhanced: "Enhanced: the best scaling plus banding removal, several extra passes on every frame. Noticeably more power and heat."
        }
    }
    private var hwdecText: String {
        switch hwdec {
        case "copy": "Copy-back: the video chip decodes, then each frame is copied back to memory so filters that work on the processor can use it. More heat and battery; only if something looks wrong with Auto."
        case "no": "Off: the processor decodes everything. Most heat and battery; only for a file the video chip can't play correctly."
        default: "Auto (recommended): the iPhone's video chip decodes. Coolest and best for battery; falls back to the processor for formats the chip can't decode."
        }
    }

    var body: some View {
        Form {
            Section {
                Explained(rendererText) {
                    Picker("Renderer", selection: $renderer) {
                        Text("OpenGL").tag("gl")
                        Text("Metal").tag("metal")
                    }
                }
                Explained(pictureText) {
                    Picker("Picture", selection: $picture) {
                        ForEach(PictureMode.allCases) { Text($0.title).tag($0) }
                    }
                    .onChange(of: picture) { _, m in PictureMode.current = m }
                }
                Explained("HDR and Dolby Vision videos play with real HDR brightness on screens that support it. Off: they are converted to normal brightness (SDR).") {
                    Toggle("HDR output", isOn: $hdr).disabled(renderer != "metal")
                }
                Explained(hwdecText) {
                    Picker("Hardware decoding", selection: $hwdec) {
                        Text("Auto").tag("auto")
                        Text("Copy-back").tag("copy")
                        Text("Off").tag("no")
                    }
                }
                if renderer == "gl" {
                    Explained("Turns the picture upside down, for devices where OpenGL shows it flipped.") {
                        Toggle("Flip video", isOn: $flipVideo)
                    }
                }
            } header: { Text("Video") } footer: { Text("Changes apply to the next video you open.") }
            Section("Streaming") {
                Explained("How much of a stream is kept in memory, ahead of where you are (and a third of that behind). More means fewer pauses on a slow connection and quicker jumps back, but uses more memory.") {
                    Stepper("Cache  \(cacheMB) MB", value: $cacheMB, in: 32...1024, step: 32)
                }
            }
            Section {
                NavigationLink { ScriptsView() } label: { Label("Scripts", systemImage: "chevron.left.forwardslash.chevron.right") }
                NavigationLink { ShadersView() } label: { Label("Shaders", systemImage: "wand.and.stars") }
                NavigationLink { ConfigEditorView(url: MPVFiles.mpvConf, title: "mpv.conf") } label: { Label("mpv.conf", systemImage: "doc.text") }
                NavigationLink { ConfigEditorView(url: MPVFiles.inputConf, title: "input.conf") } label: { Label("input.conf", systemImage: "keyboard") }
                NavigationLink { ScriptOptsView() } label: { Label("script-opts", systemImage: "slider.horizontal.below.square.filled.and.square") }
                NavigationLink { CommandsEditorView() } label: { Label("Player commands", systemImage: "command") }
            } header: { Text("Customise") } footer: {
                Text("Scripts and shaders load with every video. mpv.conf holds mpv options, input.conf keyboard shortcuts, script-opts each script's options; player commands appear in the player's Commands menu. Your mpv folder is in Files → On My iPhone → Folio → mpv.")
            }
            Section("Logs") {
                Explained("How much detail the playback log keeps. \"v\" and \"debug\" are for tracking down a problem and make the log much larger.") {
                    Picker("Log level", selection: $logLevel) {
                        ForEach(["warn", "info", "v", "debug"], id: \.self) { Text($0).tag($0) }
                    }
                }
                NavigationLink { LogView() } label: { Label("Last playback log", systemImage: "text.alignleft") }
            }
        }
        .brandListBackground()
        .navigationTitle("mpv")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AdvancedSettings: View {
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                NavigationLink { DiagnosticsView() } label: { Label("Diagnostics & report", systemImage: "stethoscope") }
            } footer: { Text("A report bundles the logs and your settings (passwords removed) to send when something goes wrong.") }
            Section {
                Button("Clear watch history", role: .destructive) { confirmClear = true }
                    .confirmationDialog("Clear all history and resume positions?", isPresented: $confirmClear, titleVisibility: .visible) {
                        Button("Clear", role: .destructive) { HistoryStore.shared.clear() }
                    }
            } footer: { Text("Forgets where you stopped every video, what you've watched, and empties Continue Watching.") }
        }
        .brandListBackground()
        .navigationTitle("Help & Diagnostics")
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
        .brandListBackground()
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
        .brandListBackground()
        .navigationTitle("script-opts")
        .onAppear { files = MPVFiles.scriptOptFiles() }
        .toolbar {
            Button { showNew = true } label: { ToolbarGlyph("plus") }
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
                                Text("#\(idx + 1)").font(.caption.weight(.bold)).foregroundStyle(Theme.onAccent)
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
                Text("Active shaders apply to every video and can be switched per video from the player's Shaders menu. Compute shaders need the Metal renderer.")
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
        .brandListBackground()
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
        .brandListBackground()
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
            .brandListBackground()
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
            .brandListBackground()
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
        .brandListBackground()
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
    @AppStorage(SettingsKey.pipTrace) private var pipTrace = false
    @AppStorage(SettingsKey.netTrace) private var netTrace = false
    @AppStorage(SettingsKey.libTrace) private var libTrace = false

    var body: some View {
        List {
            Section {
                Toggle("Trace Picture in Picture", isOn: $pipTrace)
            } footer: {
                Text("Records each step of going into and coming back from Picture in Picture in the app log: the system's PiP events, when the video output switches, which picture is in front, every frame the video shows for a few seconds, and what the app's windows look like when it goes to the background. Turn it on, reproduce the problem, then share a report. Leave it off otherwise.")
            }
            Section {
                Toggle("Trace network requests", isOn: $netTrace)
            } footer: {
                Text("Times every addon request in the app log: how long it waited to go out, the connection, and the wait for the server's answer. Requests that fail or take over 5 seconds are always logged. Addon settings and keys in the addresses are left out.")
            }
            Section {
                Toggle("Trace library and images", isOn: $libTrace)
            } footer: {
                Text("Records in the app log how pictures load (from memory, disk or the network), where each title's tile is while a page opens and closes, Discover's provider pages and their requests, and which row the player's lists open on. Turn it on, reproduce the problem, then share a report.")
            }
            HistoryLinkSection()
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
        .brandListBackground()
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
                Text("Optional alternative source. Free for personal use with your own key; leave empty to use IMDb.")
            }
            Section {
                Button("Streaming services…") { showPlatforms = true }
                NavigationLink("Addons") { AddonsManagerView() }
            }
        }
        .brandListBackground()
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
    @AppStorage(SettingsKey.episodeTitleLanguage) private var episodeTitles = "english"
    @AppStorage(SettingsKey.appearance) private var appearance = AppearanceMode.system.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                AppIconPicker()
            } header: { Text("Appearance") } footer: {
                Text("Automatic follows your iPhone's Light or Dark setting. The player is always dark.")
            }
            Section {
                Explained("The tab the app opens on.") {
                    Picker("Startup page", selection: $startupTab) {
                        Label("Home", systemImage: "play.rectangle.fill").tag(0)
                        Label("Discover", systemImage: "sparkles.tv").tag(1)
                        Label("Network", systemImage: "externaldrive.connected.to.line.below").tag(2)
                    }
                }
                Explained("Tapping a film opens its page first. Off: a tap plays it straight away (shows always open their page).") {
                    Toggle("Open title page on tap", isOn: $openTitlePage)
                }
            }
            Section {
                Explained("Blurs the pictures and hides the description of episodes you haven't finished.") {
                    Toggle("Hide spoilers", isOn: $hideSpoilers)
                }
                Explained("Shows the IMDb rating on title pages.") {
                    Toggle("Show IMDb ratings", isOn: $showRatings)
                }
                Picker("Cast on title pages", selection: $castPosition) {
                    Text("Above the episodes").tag("top")
                    Text("At the bottom").tag("bottom")
                }
                Explained("English titles come from TVmaze (tvmaze.com, CC BY-SA) when IMDb only has the original-language one. Original: the title in the show's own language.") {
                    Picker("Episode titles", selection: $episodeTitles) {
                        Text("English").tag("english")
                        Text("Original language").tag("original")
                    }
                }
            }
        }
        .brandListBackground()
        .navigationTitle("General")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LibrarySettings: View {
    @ObservedObject private var store = LocalMediaStore.shared
    @AppStorage(SettingsKey.metadataFetching) private var fetching = true
    @AppStorage(SettingsKey.tileArtwork) private var tileArtwork = "poster"
    @AppStorage(SettingsKey.titlePageStyle) private var titlePageStyle = "full"
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
                Picker("Title pages", selection: $titlePageStyle) {
                    Text("Full").tag("full")
                    Text("Files only").tag("files")
                }
            } footer: {
                Text("Full: backdrop, poster, description, Play, episodes and cast. Files only: just the title and its files; tap a file to play it.")
            }
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
        .brandListBackground()
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

/// Home Screen icon: Folio (adapts to Light, Dark and Tinted), Monochrome
/// or Alternative (UIApplication.setAlternateIconName; iOS confirms with
/// its own alert).
struct AppIconPicker: View {
    struct Option: Identifiable { let id: String?; let title: String; let preview: String }
    static let options: [Option] = [
        Option(id: nil, title: "Folio", preview: "IconPreview-primary"),
        Option(id: "AppIconMono", title: "Monochrome", preview: "IconPreview-mono"),
        Option(id: "AppIconAlt", title: "Alternative", preview: "IconPreview-alt"),
    ]
    @State private var current: String? = UIApplication.shared.alternateIconName

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.options) { o in
                Button {
                    guard UIApplication.shared.supportsAlternateIcons, o.id != current else { return }
                    UIApplication.shared.setAlternateIconName(o.id) { error in
                        if let error { dlog("ui/error", "app icon: \(error.localizedDescription)") }
                        else { DispatchQueue.main.async { current = o.id } }
                    }
                } label: {
                    VStack(spacing: 6) {
                        Image(o.preview).resizable().frame(width: 58, height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.hairline))
                            .padding(3)
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(current == o.id ? Theme.accent : .clear, lineWidth: 2))
                        Text(o.title).font(.caption).foregroundStyle(current == o.id ? Color.primary : Color.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(o.title) icon")
                .accessibilityAddTraits(current == o.id ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
    }
}


/// Settings closes with a pull down (the zoom transition's swipe back into its
/// button). 1.14.1: hit or miss — a pull at the top was often taken by the
/// list itself (its rubber-band bounce, or a flick still bouncing off the top),
/// so the page stayed. Near the top the list doesn't bounce: per UIScrollView's
/// `bounces` docs, scrolling then "stops immediately at the content boundary",
/// so a pull at the top is left to the page's swipe-down every time. Further
/// down (the bottom edge) the list bounces as usual.
private struct TopEdgeNoBounce: UIViewRepresentable {
    final class Probe: UIView {
        private var observation: NSKeyValueObservation?
        private weak var scrollView: UIScrollView?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, scrollView == nil else { return }
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        private func attach() {
            var r: UIResponder? = self
            while let n = r, !(n is UIViewController) { r = n.next }
            guard let root = (r as? UIViewController)?.view, let sv = Self.firstScrollView(in: root) else {
                dlog("ui", "settings: no list to tune for swipe-down")
                return
            }
            scrollView = sv
            update(sv)
            observation = sv.observe(\.contentOffset, options: [.new]) { [weak self] sv, _ in
                MainActor.assumeIsolated { self?.update(sv) }
            }
        }

        private func update(_ sv: UIScrollView) {
            let nearTop = sv.contentOffset.y <= -sv.adjustedContentInset.top + 60
            if sv.bounces == nearTop { sv.bounces = !nearTop }
        }

        private static func firstScrollView(in v: UIView) -> UIScrollView? {
            if let s = v as? UIScrollView { return s }
            for sub in v.subviews { if let s = firstScrollView(in: sub) { return s } }
            return nil
        }
    }
    func makeUIView(context: Context) -> Probe { let p = Probe(); p.isUserInteractionEnabled = false; return p }
    func updateUIView(_ uiView: Probe, context: Context) {}
}

/// Settings → Help & Diagnostics → Diagnostics: the watch history linking
/// check (HistoryLinkCheck), read only.
private struct HistoryLinkSection: View {
    @State private var result: String?
    @State private var running = false

    var body: some View {
        Section {
            Button {
                running = true
                Task {
                    result = await HistoryLinkCheck.run().summary
                    running = false
                }
            } label: {
                HStack {
                    Text("Check watch history linking")
                    Spacer()
                    if running { ProgressView() }
                }
            }
            .disabled(running)
            if let result {
                Text(result).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            }
        } footer: {
            Text("Counts how many of your watch history entries could be linked across Real-Debrid, your library and addons, using only what's already saved on this phone. It changes nothing. The result is also in the app log.")
        }
    }
}
