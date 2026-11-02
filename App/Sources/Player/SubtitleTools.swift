import SwiftUI

/// Subtitle style presets (1.20.3, 2 Nov), remembered for every video
/// (Settings → Audio & Subtitles, or the player's Settings menu). They set
/// mpv's sub-* options on top of your size, position, bold and box
/// settings: Large multiplies your size, Boxed always has the box, and
/// your Background box setting adds it to the others. Plain-text subtitles
/// (SRT, WebVTT) take the style; styled ASS subtitles keep their own look.
enum SubtitleStyle: String, CaseIterable, Identifiable {
    case standard = "default", large, yellow, boxed
    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Default"
        case .large: return "Large"
        case .yellow: return "Yellow"
        case .boxed: return "Boxed"
        }
    }

    var hint: String {
        switch self {
        case .standard: return "White with a black outline"
        case .large: return "A third larger than your size"
        case .yellow: return "Yellow with a black outline"
        case .boxed: return "White on a dark box"
        }
    }

    var scaleFactor: Double { self == .large ? 1.3 : 1 }

    static var current: SubtitleStyle {
        get { SubtitleStyle(rawValue: UserDefaults.standard.string(forKey: SettingsKey.subStyle) ?? "") ?? .standard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKey.subStyle) }
    }

    /// mpv options for this style with the user's own settings.
    func options(scale: Double, position: Int, bold: Bool, box: Bool) -> [(String, String)] {
        let boxed = box || self == .boxed
        return [
            ("sub-scale", String(scale * scaleFactor)),
            ("sub-pos", String(position)),
            ("sub-bold", bold ? "yes" : "no"),
            ("sub-color", self == .yellow ? "#FFE600" : "#FFFFFF"),
            ("sub-border-color", "#000000"),
            ("sub-border-style", boxed ? "background-box" : "outline-and-shadow"),
            ("sub-back-color", boxed ? "0.0/0.0/0.0/0.6" : "#00000000"),
        ]
    }

    /// The options from what's saved in Settings.
    static func savedOptions(_ d: UserDefaults = .standard) -> [(String, String)] {
        current.options(scale: d.double(forKey: SettingsKey.subScale), position: d.integer(forKey: SettingsKey.subPos),
                        bold: d.bool(forKey: SettingsKey.subBold), box: d.bool(forKey: SettingsKey.subBox))
    }
}

/// "Search subtitles…" in the player's Tracks menu (1.20.3, 2 Nov): asks
/// the installed subtitle addons for the title playing, the same request a
/// stream from an addon makes when it starts (AddonPlayback.subtitles).
/// An addon item has its IMDb id, season and episode; a library or WebDAV
/// file is looked up by its name first (MetadataService) for them.
@MainActor
final class SubtitleSearch: ObservableObject, Identifiable {
    struct Result: Identifiable, Hashable {
        var id: String { url }
        let url: String
        let lang: String?
        let addon: String
        /// "OpenSubtitles 3": the n-th result of that addon in that language.
        let label: String
    }

    struct Group: Identifiable {
        let id: String
        let name: String
        let preferred: Bool
        let results: [Result]
    }

    enum Phase: Equatable {
        case lookingUp
        case searching(answered: Int, of: Int)
        case done
        /// No subtitle addon installed at all.
        case noAddon
        /// Subtitle addons, but none for this kind of title or id.
        case noAddonForTitle
        /// The title couldn't be found online.
        case notFound
    }

    let id = UUID()
    @Published private(set) var phase: Phase = .lookingUp
    @Published private(set) var results: [Result] = []
    @Published private(set) var heading: String
    private var task: Task<Void, Never>?
    private let item: MediaItem

    init(item: MediaItem) {
        self.item = item
        heading = item.subtitle.map { "\(item.displayTitle) · \($0)" } ?? item.displayTitle
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in await self?.run() }
    }

    func cancel() { task?.cancel(); task = nil }

    private func run() async {
        guard AddonStore.shared.addons.contains(where: { $0.manifest.has(resource: "subtitles") }) else {
            phase = .noAddon
            dlog("subs", "search: no subtitle addon installed")
            return
        }
        guard let target = await Self.target(for: item) else {
            phase = .notFound
            dlog("subs", "search: no IMDb title found for \(item.fileName)")
            return
        }
        guard !Task.isCancelled else { return }
        heading = target.label
        let addons = AddonStore.shared.subtitleAddons(type: target.type, id: target.id)
        guard !addons.isEmpty else {
            phase = .noAddonForTitle
            dlog("subs", "search: none of the subtitle addons covers \(target.type) \(target.id)")
            return
        }
        phase = .searching(answered: 0, of: addons.count)
        dlog("subs", "search: asking \(addons.count) subtitle addon(s) for \(target.type) \(target.id)")
        let t0 = Date()
        await withTaskGroup(of: (String, [AddonSubtitle]).self) { group in
            for a in addons {
                let name = a.manifest.name
                group.addTask { (name, (try? await AddonAPI.subtitles(a, type: target.type, id: target.id)) ?? []) }
            }
            var answered = 0
            for await (name, list) in group {
                guard !Task.isCancelled else { return }
                answered += 1
                add(list, from: name)
                phase = answered == addons.count ? .done : .searching(answered: answered, of: addons.count)
                dlog("subs", "search: \(name) answered with \(list.count) subtitle(s) after \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            }
        }
    }

    private func add(_ list: [AddonSubtitle], from addon: String) {
        var seen = Set(results.map(\.url))
        var counts: [String: Int] = [:]
        for r in results where r.addon == addon { counts[TrackMatch.language(r.lang) ?? "", default: 0] += 1 }
        for s in list where seen.insert(s.url).inserted {
            let key = TrackMatch.language(s.lang) ?? ""
            counts[key, default: 0] += 1
            results.append(Result(url: s.url, lang: s.lang, addon: addon, label: "\(addon) \(counts[key]!)"))
        }
    }

    /// Results by language: your subtitle languages first, in your order,
    /// then the rest by name.
    var groups: [Group] {
        let prefs = Self.preferredLanguages()
        var byLang: [String: [Result]] = [:]
        for r in results { byLang[TrackMatch.language(r.lang) ?? "", default: []].append(r) }
        return byLang.map { code, list in
            Group(id: code, name: Self.languageName(code), preferred: prefs.contains(code), results: list)
        }
        .sorted { a, b in
            let ia = prefs.firstIndex(of: a.id) ?? Int.max, ib = prefs.firstIndex(of: b.id) ?? Int.max
            if ia != ib { return ia < ib }
            if a.id.isEmpty != b.id.isEmpty { return !a.id.isEmpty }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    static func preferredLanguages() -> [String] {
        var out: [String] = []
        for l in PlaybackLanguage.parse(UserDefaults.standard.string(forKey: SettingsKey.subLangs) ?? "") {
            for c in l.codes { if let n = TrackMatch.language(c), !out.contains(n) { out.append(n) } }
        }
        return out
    }

    static func languageName(_ code: String) -> String {
        guard !code.isEmpty else { return "Other" }
        if code == "pt-br" { return "Portuguese (Brazil)" }
        if code == "zh-tw" { return "Chinese (Traditional)" }
        return Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    /// The addon request's type and id ("series", "tt0903747:1:5"), and a heading.
    static func target(for item: MediaItem) async -> (type: String, id: String, label: String)? {
        let ref = (item.addonRef ?? "").split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if ref.count == 3, !ref[2].isEmpty {
            let label = [item.title, item.subtitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return (ref[0], ref[2], label.isEmpty ? item.displayTitle : label)
        }
        let file = item.fileName
        let name = TitleParser.isMedia(file) || item.title.isEmpty ? file : item.title
        let parsed = TitleParser.parse(name)
        guard let meta = await MetadataService.shared.lookup(filename: name), meta.id.hasPrefix("tt") else { return nil }
        if meta.type == "series", let e = meta.episodeNumber ?? parsed.episode {
            let s = meta.episodeSeason ?? parsed.season ?? 1
            return ("series", "\(meta.id):\(s):\(e)", "\(meta.name) · S\(s) E\(e)")
        }
        return ("movie", meta.id, meta.year.map { "\(meta.name) (\($0))" } ?? meta.name)
    }
}

/// The search's card, drawn in the player like the stream picker (a sheet
/// can't be presented from the player while one of its menus is up).
struct SubtitleSearchCard: View {
    @ObservedObject var search: SubtitleSearch
    let onPick: (SubtitleSearch.Result) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SEARCH SUBTITLES").font(.caption.weight(.bold)).tracking(1.5).foregroundStyle(.white.opacity(0.55))
                    Text(search.heading).font(.headline).lineLimit(2)
                }
                Spacer()
                CloseDot(action: onClose).accessibilityLabel("Close subtitle search")
            }
            status
            if !search.results.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(search.groups) { g in
                            PanelHeader(title: g.name)
                            ForEach(g.results) { r in
                                TrackRow(title: r.label, subtitle: g.preferred ? "Your language" : nil, selected: false) { onPick(r) }
                                    .accessibilityIdentifier("subResult")
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(18)
        .foregroundStyle(.white)
        .glass(cornerRadius: 26)
        .tint(Theme.accent)
    }

    @ViewBuilder private var status: some View {
        switch search.phase {
        case .lookingUp:
            HStack(spacing: 8) { ProgressView().tint(.white); Text("Finding the title…") }.font(.subheadline)
        case .searching(let answered, let total):
            HStack(spacing: 8) { ProgressView().tint(.white); Text("Asking subtitle addons… \(answered) of \(total)") }.font(.subheadline)
        case .done:
            if search.results.isEmpty { note("The subtitle addons found nothing for this title.") }
        case .noAddon:
            note("No subtitle addon is installed. Add one in Settings → Discover → Addons.")
        case .noAddonForTitle:
            note("None of your subtitle addons has subtitles for this kind of title.")
        case .notFound:
            note("This title couldn't be found online, so there's nothing to ask the subtitle addons for. Load a subtitle file instead.")
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.subheadline).foregroundStyle(.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
    }
}
