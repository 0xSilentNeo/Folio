import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zoomsFromTile) private var zooms
    @ObservedObject private var kids = KidsProfile.shared
    /// When the passcode (or Face ID) opened Settings on this visit (1.22.1).
    /// Never kept for another visit, and no good once the profile is turned
    /// on again or Folio has been in the background (KidsProfile.relockedAt).
    /// Until 1.22.1 Settings opened with the profile off stayed open after it
    /// was turned on, and Turn Off asked for nothing (reported on 1.22.0).
    @State private var unlockedAt: Date?
    /// What's typed in the search field (1.26.1).
    @State private var query = ""
    private var locked: Bool { kids.isOn && !(unlockedAt.map { $0 > kids.relockedAt } ?? false) }

    /// The lock goes over the list rather than in its place: swapping the
    /// list out while Kids Profile was pushed from it left the page unable
    /// to go back (simulator run: Back started the pop, the page stayed).
    var body: some View {
        list
            .opacity(locked ? 0 : 1)
            .allowsHitTesting(!locked)
            .accessibilityHidden(locked)
            .pageChrome(zooms: zooms, title: "Settings", back: { dismiss() }) { EmptyView() }
            .overlay {
                if locked {
                    SettingsLocked(cancel: { dismiss() }) { withAnimation(.smooth(duration: 0.3)) { unlockedAt = Date() } }
                        .transition(.opacity)
                }
            }
    }

    /// 1.26.1: five sections, every row opens a page (eight sections, four
    /// of them a single row, and an inline picker until then: almost two
    /// screens on a 17 Pro). The version is under About.
    private var list: some View {
        List {
            Section {
                SettingsSearchField(text: $query)
            }
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                pages
            } else {
                results
            }
        }
        .settingsPage()
        .scrollDismissesKeyboard(.immediately)
        .background { TopEdgeNoBounce().frame(width: 0, height: 0).accessibilityHidden(true) }
    }

    /// What the search found: each setting with its page's tile and name.
    @ViewBuilder
    private var results: some View {
        let found = SettingsIndex.search(query)
        if found.isEmpty {
            Section {
                ContentUnavailableView.search(text: query)
                    .listRowBackground(Color.clear)
            }
        } else {
            Section {
                ForEach(found) { r in
                    NavigationLink(value: r.route) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.title)
                                if r.title != r.location {
                                    Text(r.location).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            SettingsIcon(r.page)
                        }
                    }
                }
            } header: {
                Text(found.count == 1 ? "1 Result" : "\(found.count) Results")
            }
        }
    }

    @ViewBuilder
    private var pages: some View {
            Section {
                SettingsRow(.general)
                SettingsRow(.notifications)
                SettingsRow(.kids) { Text(kids.isOn ? "On" : "Off") }
            }
            Section {
                SettingsRow(.playback)
                SettingsRow(.audioSubtitles)
                SettingsRow(.skip)
                SettingsRow(.engine)
            }
            Section {
                SettingsRow(.library)
                SettingsRow(.discover)
                SettingsRow(.downloads)
                TrackedShowsRow()
                SettingsRow(.sync)
            }
            Section {
                SettingsRow(.importExport)
                SettingsRow(.help)
            }
            Section {
                SettingsRow(.about) {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                }
            }
    }
}

/// The root's Tracked Shows row, with how many shows are tracked.
private struct TrackedShowsRow: View {
    @ObservedObject private var store = TrackingStore.shared
    var body: some View {
        SettingsRow(.trackedShows) {
            if !store.shows.isEmpty { Text("\(store.shows.count)") }
        }
    }
}

struct PlaybackSettings: View {
    @ObservedObject private var bar = SeekBarPrefs.shared
    @AppStorage(SettingsKey.resumePlayback) private var resume = true
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
    @AppStorage(SettingsKey.prepareNext) private var prepareNext = true
    @AppStorage(SettingsKey.upNextEnabled) private var upNext = true
    @AppStorage(SettingsKey.seekBackStep) private var seekBackStep = 10
    @AppStorage(SettingsKey.gestureControl) private var gestures = true
    @AppStorage(SettingsKey.rememberPerShow) private var rememberPerShow = true

    var body: some View {
        Form {
            SettingGroup(footer: "Every video starts where you stopped it last time.") {
                Toggle("Resume where I left off", isOn: $resume)
            }
            SettingGroup(footer: "The audio and subtitle tracks, subtitle and audio delay, Fill and Anime4K you choose in the player are used again for the next episode of that show (or the next time you watch that film). Tracks are found by language and name, so it works when episodes number their tracks differently.") {
                Toggle("Remember per show", isOn: $rememberPerShow)
                if rememberPerShow {
                    NavigationLink(value: LibraryRoute.settingsSubpage(.rememberedShows)) { Text("Remembered Shows") }
                }
            }
            SettingGroup(footer: "When an episode ends, or the Up Next countdown runs out, the next one in the list starts.") {
                Toggle("Play next file automatically", isOn: $autoplayNext)
            }
            SettingGroup(footer: "A card with the next episode appears when the credits start (from the file's chapters or online skip data), otherwise 30 seconds before the end. It counts down only when nothing is known to follow the credits.") {
                Toggle("Up Next card at the credits", isOn: $upNext)
            }
            SettingGroup(footer: "For streamed episodes (addons, WebDAV): near the end of an episode the next one is found and starts loading, so Play on the Up Next card starts it right away. For a season from an addon, the app also checks which episodes have the same release, and asks you to pick for the ones that don't. Note: this opens the next episode's link early, so your debrid service adds that episode even if you don't watch it.") {
                Toggle("Get the next episode ready", isOn: $prepareNext)
            }
            SettingGroup(footer: "The screen turns to landscape when a landscape video starts.") {
                Toggle("Open in landscape", isOn: $landscapeOnOpen)
            }
            SettingGroup(footer: "Playback stays in landscape even when you hold the phone upright (it still flips between the two landscape sides).") {
                Toggle("Stay in landscape", isOn: $stayLandscape)
            }
            SettingGroup(footer: "The sound keeps playing when you leave the app or lock the phone; the picture comes back when you return.") {
                Toggle("Keep audio playing in background", isOn: $backgroundAudio)
            }
            SettingGroup("Gestures", footer: "How far a double-tap on the right side of the video and the forward button jump.") {
                Picker("Forward skip", selection: $seekStep) {
                    ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) s").tag($0) }
                }
            }
            SettingGroup(footer: "How far a double-tap on the left side and the back button jump.") {
                Picker("Backward skip", selection: $seekBackStep) {
                    ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) s").tag($0) }
                }
            }
            SettingGroup(footer: "Swipe sideways to scrub; swipe up or down along the left edge for brightness and along the right edge for volume.") {
                Toggle("Swipe for seek, volume & brightness", isOn: $gestures)
            }
            SettingGroup(footer: "Press and hold the video to play faster until you let go.") {
                Toggle("Hold to speed up", isOn: $holdToSpeed)
                if holdToSpeed {
                    Picker("Hold speed", selection: $holdSpeedValue) {
                        ForEach([1.5, 2.0, 2.5, 3.0, 4.0], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                    }
                }
            }
            SettingGroup(footer: "The speed every video starts at.") {
                Picker("Default speed", selection: $defaultSpeed) {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                }
            }
            SettingGroup("Player", footer: "How episodes are listed in the player's Now Playing menu.") {
                Picker("Playlist names", selection: $playlistNames) {
                    Text("Episode number & title").tag("episode")
                    Text("File name").tag("filename")
                }
            }
            SettingGroup(footer: "How much of the screen's width the controls use in landscape.") {
                SliderRow("Controls width", value: $controlsWidth, in: 0.6...1.0, step: 0.05)
            }
            SettingGroup("Progress bar", footer: "How chapters show on the progress bar.") {
                Picker("Chapter markers", selection: $bar.markerStyle) {
                    Text("Segments").tag("segments"); Text("Ticks").tag("ticks"); Text("Dots").tag("dots"); Text("Hidden").tag("none")
                }
                Picker("Marker colour", selection: $bar.markerColor) {
                    Text("White").tag("white"); Text("Pink").tag("accent"); Text("Yellow").tag("yellow"); Text("Cyan").tag("cyan")
                }
            }
            SettingGroup(footer: "While you drag along the progress bar, the name of the chapter under your finger shows.") {
                Toggle("Chapter name while scrubbing", isOn: $bar.showChapterTitle)
            }
            SettingGroup(footer: "Intros, credits, recaps and previews are marked on the progress bar.") {
                Toggle("Show skip segments", isOn: $bar.showSkipSegments)
            }
            SettingGroup("Picture in Picture", footer: "The video can keep playing in a small floating window over other apps.") {
                Toggle("Picture in Picture", isOn: $pipEnabled)
            }
            // 1.26.1: shown only while Picture in Picture is on (they were greyed out).
            if pipEnabled {
                SettingGroup(footer: "Going to the Home Screen while a video plays opens Picture in Picture by itself.") {
                    Toggle("Start automatically when leaving", isOn: $pipAuto)
                }
                SettingGroup(footer: "Opening the app while Picture in Picture is up closes the small window and carries on in the player.") {
                    Toggle("Back to the player when you open the app", isOn: $pipReturnOnOpen)
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
    @AppStorage(SettingsKey.nightMode) private var nightMode = false
    @AppStorage(SettingsKey.dialogueBoost) private var dialogueBoost = false
    @AppStorage(SettingsKey.subStyle) private var subStyle = SubtitleStyle.standard.rawValue
    @AppStorage(SettingsKey.subFollowZoom) private var subFollowZoom = "auto"

    var body: some View {
        Form {
            Section("Audio") {
                NavigationLink(value: LibraryRoute.settingsSubpage(.audioLanguages)) {
                    LabeledContent("Audio Languages", value: PlaybackLanguage.summary(audioLangs))
                }
            }
            SettingGroup(footer: "Plays Dolby Digital (Plus), TrueHD, Atmos, DTS, DTS-HD MA and DTS:X tracks as 5.1/7.1 to AirPlay or HDMI, and as Spatial Audio on AirPods. Atmos and DTS:X play their surround channels; object metadata isn't used. Off: always stereo.") {
                Toggle("Surround & Spatial Audio", isOn: $surround)
            }
            SettingGroup(footer: downmixNormalize
                         ? "Normalized: surround sound mixed down to stereo never distorts, but plays quieter."
                         : "Original: surround sound mixed down to stereo keeps its full loudness; very loud scenes can distort.") {
                Picker("Downmix volume", selection: $downmixNormalize) {
                    Text("Original").tag(false); Text("Normalized").tag(true)
                }
            }
            SettingGroup(footer: "Mixes the subwoofer channel into stereo, for more bass when surround sound plays on headphones or two speakers.") {
                Toggle("LFE in stereo downmix", isOn: $lfe)
            }
            SettingGroup(footer: "Softens loud scenes for late-night listening: less bass and LFE, where most of a film's loudness is, and Dolby Digital (Plus) tracks use their own range compression. What every video starts with; the player's Settings menu changes it while you watch.") {
                Toggle("Night mode", isOn: $nightMode)
            }
            SettingGroup(footer: "Makes voices easier to follow: on 5.1 and 7.1 the centre channel, where the dialogue is, gets louder and the rest quieter; on stereo the voice frequencies are raised. What every video starts with; the player's Settings menu changes it while you watch.") {
                Toggle("Dialogue boost", isOn: $dialogueBoost)
            }
            SettingGroup("Subtitles", footer: "Whether a subtitle track is turned on when a video starts. You can always switch in the player's Tracks menu.") {
                Picker("Show subtitles", selection: $subtitlesDefault) {
                    Text("On").tag("on"); Text("Off").tag("off")
                }
                NavigationLink(value: LibraryRoute.settingsSubpage(.subtitleLanguages)) {
                    LabeledContent("Subtitle Languages", value: PlaybackLanguage.summary(subLangs))
                }
                .disabled(subtitlesDefault == "off")
            }
            SettingGroup("Subtitle style", footer: "\(SubtitleStyle(rawValue: subStyle)?.hint ?? ""). Plain-text subtitles (SRT, WebVTT) take the style; styled ASS subtitles keep their own look. Large makes your size a third bigger; Background box adds the box to any style.") {
                Picker("Style", selection: $subStyle) {
                    ForEach(SubtitleStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                SliderRow("Size", value: $subScale, in: 0.5...2.5, step: 0.05)
                Toggle("Bold", isOn: $subBold)
            }
            SettingGroup(footer: "A dark box behind the text keeps subtitles readable on bright scenes.") {
                Toggle("Background box", isOn: $subBox)
            }
            SettingGroup(footer: "100 is the normal place near the bottom; lower numbers move subtitles up, higher numbers further down.") {
                Stepper(value: $subPos, in: 50...150) { LabeledContent("Position", value: "\(subPos)") }
            }
            SettingGroup(footer: subFollowZoom == "manual"
                         ? "Subtitles stay where Position puts them on the video. When you zoom in or fill the screen, a subtitle near the bottom can go past the screen's edge: move it up with Position."
                         : "When you zoom in or fill the screen, subtitles move and resize so they keep their place on what you can see.") {
                Picker("When the picture is zoomed", selection: $subFollowZoom) {
                    Text("Adjust automatically").tag("auto")
                    Text("Stay as set").tag("manual")
                }
            }
        }
        .brandListBackground()
        .navigationTitle("Audio & Subtitles")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings → Playback → Remembered shows (1.20.3): what the player
/// remembers per show (ShowMemory), to forget one or all.
struct RememberedShowsView: View {
    @ObservedObject private var store = ShowMemoryStore.shared
    @State private var confirmAll = false

    var body: some View {
        let shows = store.entries.sorted { $0.updated > $1.updated }
        List {
            Section {
                ForEach(shows) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.name)
                        Text(Self.summary(e)).font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Forget", role: .destructive) { store.forget(e.id) }
                    }
                }
            } footer: {
                if !shows.isEmpty {
                    Text("Swipe a show to forget its settings; it then plays with your defaults again. Up to 500 shows are kept; the ones not watched for longest go first.")
                }
            }
            if !shows.isEmpty {
                Section {
                    Button("Forget All", role: .destructive) { confirmAll = true }
                        .confirmationDialog("Forget the settings of every show?", isPresented: $confirmAll, titleVisibility: .visible) {
                            Button("Forget All", role: .destructive) { store.forgetAll() }
                        }
                }
            }
        }
        .overlay {
            if shows.isEmpty {
                ContentUnavailableView("Nothing Remembered Yet", systemImage: "rectangle.stack.badge.person.crop",
                                       description: Text("The tracks, delays, Fill and Anime4K you pick in the player are kept here for each show."))
            }
        }
        .brandListBackground()
        .navigationTitle("Remembered Shows")
        .navigationBarTitleDisplayMode(.inline)
    }

    static func summary(_ e: ShowMemoryStore.Entry) -> String {
        let s = e.settings
        var parts: [String] = []
        func lang(_ code: String?) -> String {
            guard let n = TrackMatch.language(code) else { return "untagged" }
            return SubtitleSearch.languageName(n)
        }
        if let a = s.audio { parts.append("Audio \(lang(a.lang))") }
        if let t = s.subtitle { parts.append(t.off ? "Subtitles off" : "Subtitles \(lang(t.lang))\(t.forced ? " (forced)" : t.sdh ? " (SDH)" : "")") }
        if let d = s.subDelay, abs(d) > 0.0005 { parts.append(String(format: "subtitle delay %+.1f s", d)) }
        if let d = s.audioDelay, abs(d) > 0.0005 { parts.append(String(format: "audio delay %+.0f ms", d * 1000)) }
        if let p = s.panscan { parts.append(p > 0.5 ? "Fill" : "Fit") }
        if let m = s.anime4k.flatMap(Anime4KMode.init(rawValue:)) { parts.append("Anime4K \(m.title)") }
        return parts.isEmpty ? "Nothing changed yet" : parts.joined(separator: " · ")
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
    @AppStorage(SettingsKey.skipLearnIntros) private var learnIntros = true
    @ObservedObject private var memory = ShowMemoryStore.shared

    var body: some View {
        Form {
            SettingGroup(footer: "A Skip button appears during intros, credits, recaps and previews. They come from the file's chapters; otherwise from IntroDB and TheIntroDB for TV and films (community databases looked up by IMDb id), and AniSkip / Open Anime Timestamps for anime.") {
                Toggle("Show Skip button", isOn: $skipEnabled)
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
                SettingGroup("Sources", footer: "Files that name their chapters (Opening, Ending, Credits…) are skipped by those chapters first.") {
                    Toggle("Use file chapters", isOn: $useChapters)
                }
                SettingGroup(footer: "Intros and credits found online show as chapters too: on the progress bar, in Now Playing, and to Lua scripts.") {
                    Toggle("Add found markers as chapters", isOn: $injectChapters)
                }
                SettingGroup(footer: "Open Anime Timestamps only knows where a part starts, so its length is assumed.") {
                    Stepper(value: $oatLength, in: 60...150, step: 5) {
                        LabeledContent("OAT segment length", value: Duration.seconds(oatLength).formatted(.units(allowed: [.seconds], width: .abbreviated)))
                    }
                }
                SettingGroup("Intros you watch", footer: "Watch an intro to its end in \(PlayerModel.introEpisodesToHide) episodes of a show without skipping it, and its Skip button stops showing for that show. Some releases call the episode's first scene the intro.") {
                    Toggle("Hide intros I watch", isOn: $learnIntros)
                }
                Section {
                    ForEach(memory.hiddenIntroShows) { e in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.name)
                                Text((e.settings.introHidden ?? []).map { "Skip " + $0.capitalized }.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Show Again") { memory.showIntrosAgain(e.id) }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("introShowAgain:" + e.name)
                        }
                    }
                } footer: {
                    if learnIntros, memory.hiddenIntroShows.isEmpty { Text("No show has its intro hidden yet.") }
                }
            }
        }
        .brandListBackground()
        .navigationTitle("Skip Intro & Credits")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Everything mpv in one place (1.17.0): the video engine, scripts, shaders,
/// config files and logs.
struct MPVSettings: View {
    @AppStorage(SettingsKey.renderer) private var renderer = "metal"
    @AppStorage(SettingsKey.hdrOutput) private var hdr = true
    @AppStorage(SettingsKey.hwdec) private var hwdec = "auto"
    @AppStorage(SettingsKey.cacheMB) private var cacheMB = 150
    @AppStorage(SettingsKey.flipVideo) private var flipVideo = false
    @State private var picture = PictureMode.current

    private var rendererText: String {
        renderer == "gl"
            ? "OpenGL: one picture for the screen and Picture in Picture, so PiP and leaving the app never pause the video. HDR shows with HDR brightness; compute shaders don't run, and some files may not play."
            : "Metal (recommended): plays every file, with real HDR and Dolby Vision brightness and every shader. Picture in Picture and leaving the app pause the picture for a moment."
    }
    private var pictureText: String {
        switch picture {
        case .efficient: "Efficient: simple scaling with no extra passes, and with OpenGL, HDR drawn straight from the video chip. Coolest phone, longest battery: the one for long watching."
        case .balanced: "Balanced: a sharper scaler when the video is enlarged, and with OpenGL, smoother HDR gradients (each frame copied out at full 10 bits). A little more power."
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
            SettingGroup("Video", footer: rendererText) {
                Picker("Renderer", selection: $renderer) {
                    Text("Metal").tag("metal")
                    Text("OpenGL").tag("gl")
                }
            }
            SettingGroup(footer: pictureText) {
                Picker("Picture", selection: $picture) {
                    ForEach(PictureMode.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: picture) { _, m in PictureMode.current = m }
            }
            SettingGroup(footer: "HDR and Dolby Vision videos play with real HDR brightness on screens that support it. Off: they are converted to normal brightness (SDR).") {
                Toggle("HDR output", isOn: $hdr)
            }
            SettingGroup(footer: hwdecText) {
                Picker("Hardware decoding", selection: $hwdec) {
                    Text("Auto").tag("auto")
                    Text("Copy-back").tag("copy")
                    Text("Off").tag("no")
                }
            }
            if renderer == "gl" {
                SettingGroup(footer: "Turns the picture upside down, for devices where OpenGL shows it flipped.") {
                    Toggle("Flip video", isOn: $flipVideo)
                }
            }
            SettingGroup("Streaming", footer: "How much of a stream is kept in memory, ahead of where you are (and a third of that behind). More means fewer pauses on a slow connection and quicker jumps back, but uses more memory. Video settings apply to the next video you open.") {
                Stepper(value: $cacheMB, in: 32...1024, step: 32) {
                    LabeledContent("Cache", value: Measurement(value: Double(cacheMB), unit: UnitInformationStorage.megabytes).formatted(.measurement(width: .abbreviated, usage: .asProvided)))
                }
            }
            Section {
                NavigationLink(value: LibraryRoute.settingsSubpage(.scripts)) { Label("Scripts", systemImage: "chevron.left.forwardslash.chevron.right") }
                NavigationLink(value: LibraryRoute.settingsSubpage(.shaders)) { Label("Shaders", systemImage: "wand.and.stars") }
                NavigationLink(value: LibraryRoute.settingsSubpage(.config(MPVFiles.mpvConf, "mpv.conf", true))) { Label("mpv.conf", systemImage: "doc.text") }
                NavigationLink(value: LibraryRoute.settingsSubpage(.config(MPVFiles.inputConf, "input.conf", true))) { Label("input.conf", systemImage: "keyboard") }
                NavigationLink(value: LibraryRoute.settingsSubpage(.scriptOptions)) { Label("script-opts", systemImage: "slider.horizontal.below.square.filled.and.square") }
                NavigationLink(value: LibraryRoute.settingsSubpage(.commands)) { Label("Player Commands", systemImage: "command") }
            } header: { Text("Customise") } footer: {
                Text("Scripts and shaders load with every video. mpv.conf holds mpv options, input.conf keyboard shortcuts, script-opts each script's options; player commands appear in the player's Commands menu. Your mpv folder is in Files → On My iPhone → Folio → mpv.")
            }
            // No Log level any more (1.23.0): mpv writes its log file at debug
            // detail whatever it's set to, so all four choices did nothing (review).
            Section("Logs") {
                NavigationLink(value: LibraryRoute.settingsSubpage(.playbackLog)) { Label("Last Playback Log", systemImage: "text.alignleft") }
            }
        }
        .brandListBackground()
        .navigationTitle("Video Engine")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AdvancedSettings: View {
    @AppStorage(SettingsKey.notifyTest) private var notifyTest = true
    @AppStorage(SettingsKey.nativePanelMorph) private var nativePanelMorph = true

    var body: some View {
        Form {
            Section {
                NavigationLink(value: LibraryRoute.settingsSubpage(.diagnostics)) { Label("Diagnostics & Report", systemImage: "stethoscope") }
                // 1.26.1: Test, from Notifications.
                NavigationLink(value: LibraryRoute.settingsSubpage(.notifyTest)) {
                    LabeledContent {
                        Text(notifyTest ? "On" : "Off")
                    } label: {
                        Label("Notification Test", systemImage: "testtube.2")
                    }
                }
            } footer: { Text("A report bundles the logs and your settings (passwords removed) to send when something goes wrong.") }
            // 1.26.1: the experiments, from General and Playback.
            Section {
                if #available(iOS 26.0, *) {
                    Toggle("Native menu morph", isOn: $nativePanelMorph)
                }
            } header: { Text("Experimental") } footer: {
                Text("Native menu morph: the player's menus grow out of their button with Apple's own glass animation; off, Folio's own glass menus.")
            }
        }
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
    @State private var editing: MPVFiles.Script?

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
                        Toggle(s.name, isOn: Binding(get: { s.enabled }, set: { on in
                            try? MPVFiles.setEnabled(s, on)
                            reload()
                        }))
                        .labelsHidden()
                    }
                    .contextMenu {
                        if !s.isDirectory { Button("Edit", systemImage: "pencil") { editing = s } }
                    }
                    .swipeActions(edge: .leading) {
                        if !s.isDirectory { Button("Edit", systemImage: "pencil") { editing = s }.tint(Theme.action) }
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
                Button { importing = true } label: { Label("Import .lua Files…", systemImage: "square.and.arrow.down") }
                Button { showURL = true } label: { Label("Install from URL…", systemImage: "link") }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("Add") } footer: {
                Text("""
                Works: mp.* API, observers, timers, OSD/overlays, script-message, key bindings (hardware keyboard or Settings → Commands).
                Doesn't work on iOS: mp.utils.subprocess, io.popen, os.execute (no curl/yt-dlp), JavaScript scripts, mouse-only UIs.
                You can also drop scripts into Files → Folio → mpv → scripts.
                """)
            }
        }
        .brandListBackground()
        .navigationTitle("Scripts")
        .navigationDestination(item: $editing) { s in
            ConfigEditorView(url: s.url, title: s.name, monospaced: true).settingsPage()
        }
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
                NavigationLink(value: LibraryRoute.settingsSubpage(.config(f, f.lastPathComponent, true))) {
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
                .accessibilityLabel("Add")
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
                    .accessibilityValue(idx.map { "On, applied \($0 + 1) of \(active.count)" } ?? "Off")
                    .accessibilityAddTraits(idx != nil ? .isSelected : [])
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
                    Button("Turn All Off") { active = []; MPVFiles.activeShaderNames = [] }
                }
            } header: { Text("Installed") } footer: {
                Text("Tap a shader to turn it on or off; they apply in the order you turn them on (the number). Active shaders apply to every video and can be switched per video from the player's Shaders menu. Compute shaders need the Metal renderer.")
            }

            Section("Download") {
                ForEach(ShaderCatalog.entries) { e in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(e.file).font(.footnote.monospaced())
                            Text(e.group).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if files.contains(where: { $0.lastPathComponent == e.file }) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                                .accessibilityLabel("Installed")
                        } else if downloading.contains(e.file) {
                            FolioSpinner(size: .small)
                        } else {
                            Button { download(e) } label: {
                                Image(systemName: "arrow.down.circle").frame(minWidth: 44, minHeight: 44).contentShape(.rect)
                            }
                            .accessibilityLabel("Download \(e.file)")
                        }
                    }
                }
                Button("Download All (Anime4K & FSRCNNX)") {
                    for e in ShaderCatalog.entries where !files.contains(where: { $0.lastPathComponent == e.file }) { download(e) }
                }
            }

            Section {
                Button { importing = true } label: { Label("Import Shader Files…", systemImage: "square.and.arrow.down") }
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
    @State private var confirmRestore = false

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
                Button("Restore Defaults", role: .destructive) { confirmRestore = true }
                    .confirmationDialog("Restore the default commands?", isPresented: $confirmRestore, titleVisibility: .visible) {
                        Button("Restore Defaults", role: .destructive) { commands = ScriptCommandStore.defaults; save() }
                    } message: {
                        Text("Your own commands are replaced by Folio's.")
                    }
            }
        }
        .brandListBackground()
        .navigationTitle("Player Commands")
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
                Section("Name") {
                    TextField("Name", text: $command.name, prompt: Text("Next Chapter"))
                }
                Section {
                    TextField("mpv Command", text: $command.command, prompt: Text("add chapter 1"), axis: .vertical)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("mpv Command") } footer: {
                    Text("Any input.conf command; separate several with a semicolon.")
                }
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
    /// The file as last read or saved: Save, and the save on leaving, only
    /// when the text differs. Until 1.20.3 setting the text on appear counted
    /// as an edit, so every visit rewrote the file.
    @State private var original = ""
    /// The file isn't UTF-8 text: shown read-only, never saved over.
    @State private var unreadable = false
    @Environment(\.dismiss) private var dismiss

    private var changed: Bool { !unreadable && text != original }

    var body: some View {
        TextEditor(text: $text)
            .font(monospaced ? .system(.footnote, design: .monospaced) : .body)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .brandListBackground()
            .disabled(unreadable)
            .overlay {
                if unreadable {
                    ContentUnavailableView("Can't edit this file here", systemImage: "doc.badge.ellipsis",
                                           description: Text("It isn't plain UTF-8 text, and saving it here would damage it. Edit it in another app from Files → Folio → mpv."))
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let t = MPVFiles.readEditableText(url) { text = t; original = t } else { unreadable = true }
            }
            .toolbar {
                Button(changed ? "Save" : "Saved") {
                    if (try? MPVFiles.writeText(text, to: url)) != nil { original = text }
                }
                .disabled(!changed)
            }
            .onDisappear { if changed { try? MPVFiles.writeText(text, to: url) } }
    }
}

struct LogView: View {
    @State private var text = ""
    @State private var errorsOnly = false
    @State private var shareCopy: URL?
    /// The lines shown, worked out once when the log or the filter changes
    /// (1.24.1). Until then one Text held up to 400 000 characters and every
    /// redraw split and lowercased all of them: the screen froze on open.
    @State private var lines: [String] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines.indices, id: \.self) { i in
                    Text(lines[i]).textSelection(.enabled)
                }
            }
            .font(.caption2.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .overlay {
            if lines.isEmpty {
                if text.isEmpty {
                    ContentUnavailableView("No Log Yet", systemImage: "text.alignleft", description: Text("Play something first."))
                } else {
                    ContentUnavailableView("No Errors", systemImage: "checkmark.circle", description: Text("The last playback logged no errors or warnings."))
                }
            }
        }
        .onChange(of: errorsOnly) { _, _ in lines = Self.lines(text, errorsOnly: errorsOnly) }
        .background(Theme.background)
        .brandListBackground()
        .navigationTitle("Last Playback Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle("Errors Only", systemImage: "exclamationmark.triangle", isOn: $errorsOnly)
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let shareCopy { ShareLink(item: shareCopy) }
            }
        }
        .task {
            // Shown and shared without passwords or keys, as in the report:
            // until 1.20.2 the share button sent mpv's log as it was (review,
            // 31 Oct). The last 400 000 characters keep the view responsive.
            let (shown, copy) = await Task.detached(priority: .userInitiated) { () -> (String, URL?) in
                let full = MPVFiles.readText(MPVFiles.logFile)
                let s = Diagnostics.redact(Diagnostics.tail(full, limit: 400_000))
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("mpv-last.log")
                return (s, (try? s.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil)
            }.value
            text = shown
            lines = Self.lines(shown, errorsOnly: errorsOnly)
            shareCopy = copy
        }
    }

    static func lines(_ text: String, errorsOnly: Bool) -> [String] {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard errorsOnly else { return text.isEmpty ? [] : all }
        return all.filter {
            let l = $0.lowercased()
            return l.contains("[e]") || l.contains("[w]") || l.contains("error") || l.contains("fail") || l.contains("lua")
        }
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
                        HStack { Label("Prepare report", systemImage: "doc.zipper"); Spacer(); if making { FolioSpinner(size: .small) } }
                    }
                }
            } footer: {
                Text("The report bundles the app log, the last mpv log, crash and hang records and your settings. Passwords, keys and tokens are removed; server addresses stay. With Trace Picture in Picture on, it also includes screenshots of the player and app-switcher pictures.")
            }
            Section("Recent app log") {
                Text(tail.isEmpty ? "No entries yet." : tail)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }
            Section {
                Button("Clear Logs", role: .destructive) {
                    // Through the logger itself, which closes its open file
                    // first: deleting app.log under it left later lines going
                    // to a file that was gone (1.20.3, 2 Nov).
                    Diagnostics.shared.clearLogs()
                    tail = ""
                }
            }
        }
        .brandListBackground()
        .navigationTitle("Diagnostics & Report")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Off the main thread, and only the end of the file (1.24.1): the
            // whole app.log (up to 2 MB) was read and split on main to show 80 lines.
            let url = Diagnostics.shared.appLog
            tail = await Task.detached(priority: .userInitiated) { () -> String in
                guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
                defer { try? h.close() }
                let end = (try? h.seekToEnd()) ?? 0
                try? h.seek(toOffset: end > 65_536 ? end - 65_536 : 0)
                let s = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
                return s.split(separator: "\n").suffix(80).joined(separator: "\n")
            }.value
        }
    }
}


struct DiscoverSettings: View {
    @AppStorage(IMDbSource.Key.language) private var language = "en-US"
    @AppStorage(IMDbSource.Key.minVotes) private var minVotes = 25000
    @AppStorage(IMDbSource.Key.animeJapan) private var animeJapan = true
    @AppStorage(SettingsKey.discoverAiring) private var airing = true
    @AppStorage(SettingsKey.discoverAiringKind) private var airingKind = AiringCatalog.Kind.series.rawValue
    @State private var showPlatforms = false
    @State private var cleared = false

    var body: some View {
        Form {
            Section {
                Toggle("Airing now", isOn: $airing)
                if airing {
                    Picker("Show", selection: $airingKind) {
                        ForEach(AiringCatalog.Kind.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }
            } header: { Text("Rows") } footer: {
                Text("A row at the top of Discover with series that have new episodes this week (from TVmaze) or anime airing this season (from AniList). The pill on the row switches between them.")
            }
            Section {
                LabeledContent("Language") {
                    TextField("Language", text: $language, prompt: Text("en-US"))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Picker("Top Rated: minimum votes", selection: $minVotes) {
                    ForEach([1000, 5000, 10000, 25000, 50000, 100000], id: \.self) { Text($0.formatted()).tag($0) }
                }
                Toggle("Anime = animation from Japan", isOn: $animeJapan)
                Button(cleared ? "Cache cleared" : "Clear IMDb cache") { IMDbSource.clearCache(); cleared = true }.disabled(cleared)
            } header: { Text("IMDb (built in)") } footer: {
                Text("Titles, posters, synopses, ratings, charts and episode lists are read from IMDb's own pages — the same numbers you see on imdb.com. Trending is IMDb's Most Popular list; Top Rated is the Top 250 (with a genre: IMDb's user-rating ranking with at least the chosen number of votes). Language changes titles and synopses where IMDb has translations.")
            }
            Section {
                Button("Streaming Services…") { showPlatforms = true }
                NavigationLink("Addons", value: LibraryRoute.settingsSubpage(.addons))
            } footer: {
                // 1.27.1: the TMDB key and Cinemeta moved to Addons, with their order.
                Text("Cinemeta, your TMDB key and which one Discover uses first are in Addons.")
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
                Picker("Startup page", selection: $startupTab) {
                    Label("Home", systemImage: "play.rectangle.fill").tag(0)
                    Label("Discover", systemImage: "sparkles.tv").tag(1)
                    Label("Network", systemImage: "externaldrive.connected.to.line.below").tag(2)
                }
            }
            SettingGroup(footer: "Tapping a film opens its page first. Off: a tap plays it straight away (shows always open their page).") {
                Toggle("Open title page on tap", isOn: $openTitlePage)
            }
            SettingGroup("Title Pages", footer: "Blurs the pictures and hides the description of episodes you haven't finished.") {
                Toggle("Hide spoilers", isOn: $hideSpoilers)
            }
            Section {
                Toggle("Show IMDb ratings", isOn: $showRatings)
                Picker("Cast on title pages", selection: $castPosition) {
                    Text("Above the episodes").tag("top")
                    Text("At the bottom").tag("bottom")
                }
            }
            SettingGroup(footer: "English titles come from TVmaze (tvmaze.com, CC BY-SA) when IMDb only has the original-language one. Original: the title in the show's own language.") {
                Picker("Episode titles", selection: $episodeTitles) {
                    Text("English").tag("english")
                    Text("Original language").tag("original")
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
    @State private var confirmClear = false

    /// Worked out once per body (1.26.1: three times, each parsing every file name).
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
                let c = counts
                HStack(spacing: 10) {
                    stat(c.movies, "Movies")
                    stat(c.episodes, "TV Episodes")
                    stat(c.other, "Other")
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            Section {
                Button("Scan for Changes") { store.refresh() }
                Button("Refresh Metadata") {
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
            } header: { Text("Metadata & Artwork") } footer: {
                Text("Titles, posters and episode names come from IMDb, looked up from the file names and kept on this device.")
            }
            // 1.26.1: the artwork cache as a labelled row (an icon-only bin
            // until then), and watch history, from Help & Diagnostics.
            Section {
                LabeledContent("Artwork cache", value: ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))
                Button("Clear Artwork Cache") {
                    ImageCache.shared.clear()
                    Task { await measure() }
                }
                Button("Clear Watch History", role: .destructive) { confirmClear = true }
                    .confirmationDialog("Clear all history and resume positions?", isPresented: $confirmClear, titleVisibility: .visible) {
                        Button("Clear Watch History", role: .destructive) { HistoryStore.shared.clear() }
                    } message: {
                        Text("Forgets where you stopped every video and what you've watched, and empties Continue Watching. This can't be undone.")
                    }
            } header: { Text("Storage & History") } footer: {
                Text("The artwork cache refills as you browse.")
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
                            .clipShape(.rect(cornerRadius: 13, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.hairline) }
                            .padding(3)
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(current == o.id ? Theme.accent : .clear, lineWidth: 2)
                            }
                        Text(o.title).font(.caption)
                            .foregroundStyle(current == o.id ? Color.primary : Color.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
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
                    if running { FolioSpinner(size: .small) }
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
