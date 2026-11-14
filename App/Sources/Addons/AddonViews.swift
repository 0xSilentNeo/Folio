import SwiftUI

/// A row of an addon's catalog (on Discover since 1.27.0).
struct CatalogRow: View {
    let addon: InstalledAddon
    let catalog: AddonManifest.Catalog
    var margin: CGFloat = 16
    /// Discover's pulls to refresh (1.30.4): a row that failed asks again.
    var refresh = 0
    @Namespace private var zoomNS
    @State private var metas: [MetaItem] = []
    @State private var failed = false
    @State private var loaded = false
    /// Tries so far, so Retry asks again even with no pull to refresh.
    @State private var tries = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(catalogTitle).font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
                    Text(addon.manifest.name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                NavigationLink {
                    CatalogGridView(addon: addon, catalog: catalog, title: catalogTitle)
                } label: {
                    Text("See all").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, margin)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    if !loaded {
                        ForEach(0..<6, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 12).fill(Theme.card).frame(width: 118, height: 177)
                        }
                    }
                    ForEach(metas) { m in
                        NavigationLink { MetaDetailView(preview: m, sourceAddon: addon).zoomDestination(m.id, in: zoomNS) } label: {
                            PosterCard(meta: m, width: catalogShape == "landscape" ? 210 : 118, zoom: ZoomSource(m.id, zoomNS))
                        }
                        .buttonStyle(.plain)
                    }
                    if failed {
                        // A way to ask again (1.30.4): a failed row stayed so for the session.
                        Button { tries += 1 } label: {
                            Label("Couldn't load · Retry", systemImage: "arrow.clockwise").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .frame(height: 177)
                    }
                }
                .padding(.horizontal, margin)
            }
        }
        // Asked when the row comes on screen, and again on a pull to refresh
        // or Retry after a failure (1.30.4). A load cut short (the row went
        // off screen, a push, a tab switch) isn't a failure: it marked the row
        // failed and loaded, and nothing asked again for the session.
        .task(id: "\(refresh)|\(tries)") {
            guard !loaded || failed else { return }
            var extra: [String: String] = [:]
            if catalog.requiredExtras.contains("genre"), let g = catalog.genreOptions.first { extra["genre"] = g }
            do {
                let list = try await AddonAPI.catalog(addon, catalog, extra: extra)
                metas = list
                failed = false
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return }
                // What was shown stays; the row says it couldn't load only with nothing to show.
                failed = metas.isEmpty
            }
            loaded = true
        }
    }

    private var catalogShape: String? { metas.first?.posterShape }
    private var catalogTitle: String { Self.title(catalog) }

    /// "Popular · Movie".
    static func title(_ catalog: AddonManifest.Catalog) -> String {
        "\(catalog.name ?? catalog.id) · \(typeName(catalog.type))"
    }

    /// "movie" → "Movies", as Discover's own headings say it.
    static func typeName(_ type: String) -> String {
        switch type.lowercased() {
        case "movie": "Movies"
        case "series": "Series"
        case "channel": "Channels"
        case "tv": "TV"
        default: type.capitalized
        }
    }
}

struct PosterCard: View {
    let meta: MetaItem
    var width: CGFloat? = 118
    /// The title page zooms out of this poster.
    var zoom: ZoomSource? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Decoded for the tile's width where it has one (1.30.2).
            PosterImage(url: meta.poster, aspect: meta.posterShape == "landscape" ? 16.0 / 9.0 : (meta.posterShape == "square" ? 1 : 2.0 / 3.0),
                        width: width)
                .frame(width: width)
                .overlay(alignment: .topLeading) {
                    if let rank = meta.rank {
                        Text("#\(rank)").font(.caption2.weight(.heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.65), in: Capsule())
                            .padding(6)
                    }
                }
                // No drop shadow: every blurred shadow in a grid is re-rendered
                // on each scroll frame; a hairline edge reads the same on dark.
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                .pointerHover(cornerRadius: 12)
                .zoomSource(zoom)
            // Two lines for a long title (1.27.0: cut at one).
            Text(meta.name).font(.caption.weight(.medium)).lineLimit(2).frame(width: width, alignment: .leading)
            // An addon's empty rating ("") showed a lone star (1.27.0).
            let rating = meta.imdbRating.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            let year = meta.releaseInfo.flatMap { $0.isEmpty ? nil : $0 }
            let sub = [rating.map { "★ \($0)" }, year].compactMap { $0 }.joined(separator: " · ")
            if !sub.isEmpty {
                Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityLabel([rating.map { "Rated \($0)" }, year].compactMap { $0 }.joined(separator: ", "))
            }
        }
    }
}

struct CatalogGridView: View {
    let addon: InstalledAddon
    let catalog: AddonManifest.Catalog
    let title: String
    @State private var metas: [MetaItem] = []
    @State private var loading = false
    @State private var exhausted = false
    @State private var genre: String?
    /// Goes up with each change of genre; a load belongs to the one it began in.
    @State private var generation = 0
    @State private var loadingGeneration: Int?
    /// The last page didn't come (1.30.4): said, with Retry. A first page
    /// that failed left the grid empty with no word, as if the catalog were.
    @State private var loadError: String?
    @Namespace private var zoomNS

    var body: some View {
        ScrollView {
            if !catalog.genreOptions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        if !catalog.requiredExtras.contains("genre") {
                            chip("All", selected: genre == nil) { genre = nil }
                        }
                        ForEach(catalog.genreOptions, id: \.self) { g in chip(g, selected: genre == g) { genre = g } }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 8)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 12)], spacing: 16) {
                ForEach(metas) { m in
                    NavigationLink { MetaDetailView(preview: m, sourceAddon: addon).zoomDestination(m.id, in: zoomNS, zoom: false) } label: {
                        PosterCard(meta: m, width: 108, zoom: ZoomSource(m.id, zoomNS))
                    }
                    .buttonStyle(.plain)
                    .onAppear { if m.id == metas.last?.id { Task { await loadMore() } } }
                }
            }
            .padding(16)
            if loading { FolioSpinner().padding() }
            if !loading, let loadError {
                if metas.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn't Load", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text("\(addon.manifest.name) didn't answer: \(loadError)")
                    } actions: {
                        Button("Try Again") { Task { await loadMore() } }.buttonStyle(.borderedProminent).tint(Theme.action)
                    }
                } else {
                    Button { Task { await loadMore() } } label: { Label("Couldn't load more · Retry", systemImage: "arrow.clockwise").font(.footnote) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).padding()
                }
            }
        }
        .background(Theme.background)
        .brandListBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // A catalog that needs a genre opens on its first (1.30.2): the
            // change loads it (onChange), so nothing is loaded here as well.
            // It asked twice on opening, and went back to the first genre
            // each time the grid came back on screen.
            if catalog.requiredExtras.contains("genre"), genre == nil, let first = catalog.genreOptions.first {
                genre = first
                return
            }
            if metas.isEmpty { await loadMore() }
        }
        .onChange(of: genre) { _, _ in
            generation += 1
            metas = []; exhausted = false; loadError = nil
            Task { await loadMore() }
        }
    }

    private func chip(_ t: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundStyle(selected ? Theme.onAccent : .primary)
                .background(selected ? Theme.accent : Theme.card, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// One load at a time for the genre shown. A genre picked while a page
    /// was on its way was dropped (the load in flight barred the new one) and
    /// the old genre's titles then filled the grid under the new chip
    /// (1.30.1): each genre's load now runs, and an answer for a genre no
    /// longer shown is left out.
    private func loadMore() async {
        let gen = generation
        guard loadingGeneration != gen, !exhausted else { return }
        loadingGeneration = gen
        loading = true
        var extra: [String: String] = [:]
        if let genre { extra["genre"] = genre }
        if !metas.isEmpty { extra["skip"] = String(metas.count) }
        let page: [MetaItem]
        do {
            page = try await AddonAPI.catalog(addon, catalog, extra: extra)
        } catch {
            guard gen == generation else { return }
            loading = false; loadingGeneration = nil
            // Cut short (the page closed) isn't the addon's failure.
            if !(Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled) { loadError = error.localizedDescription }
            return
        }
        guard gen == generation else { return }     // the newer load has the spinner
        defer { loading = false; loadingGeneration = nil }
        loadError = nil
        let known = Set(metas.map(\.id))
        let fresh = page.filter { !known.contains($0.id) }
        if fresh.isEmpty { exhausted = true }
        metas += fresh
    }
}

// MARK: - Meta detail

struct EpisodeRow: View {
    let video: MetaVideo
    /// The episode's state on either side (1.30.0, WatchedState.combined):
    /// its addon entry or its library file's.
    let entry: HistoryEntry?
    @AppStorage(SettingsKey.hideSpoilers) private var hideSpoilers = false

    private var episodeTitle: String {
        if let e = video.episode { return "\(e). " + (video.title ?? "Episode \(e)") }
        return video.title ?? video.id
    }
    private var watched: Bool { entry?.isFinished == true }
    /// Unwatched episode with spoilers hidden: no synopsis, a blurred
    /// still, as the library's rows have it (1.30.0).
    private var spoilerHidden: Bool { hideSpoilers && video.episode != nil && !watched }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PosterImage(url: video.thumbnail, aspect: 16.0 / 9.0, cornerRadius: 10)
                .blur(radius: spoilerHidden ? 12 : 0)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(width: 130)
                .overlay(alignment: .bottom) {
                    // Not on a watched one, as in the library.
                    if let entry, !watched, entry.progress > 0.01 {
                        ArtProgressBar(progress: entry.progress)
                    }
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(episodeTitle)
                    .font(.subheadline.weight(.semibold)).lineLimit(2)
                if !spoilerHidden, let o = video.overview { Text(o).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                if video.rating != nil || video.released != nil {
                    Text([video.rating.map { "★ \($0)" }, video.released].compactMap { $0 }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                        .accessibilityLabel([video.rating.map { "Rated \($0)" }, video.released].compactMap { $0 }.joined(separator: ", "))
                }
            }
            Spacer(minLength: 0)
            // The library's eye, at the row's top right as there (1.30.0: a
            // checkmark and the word under the text). The row says it as its value.
            if watched { WatchedGlyph(spoken: false).padding(.top, 2) }
        }
        .padding(8)
        // The library's episode rows' radius (1.27.0: 14 here, 16 there).
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Streams

struct StreamsView: View {
    let meta: MetaItem
    let video: MetaVideo?
    /// Play Season: this episode and the ones after it (first = `video`).
    var seasonVideos: [MetaVideo] = []
    /// Start over (1.30.0): the stream starts at 0 whatever its history says.
    var fromStart = false
    /// Where it starts when only the episode's library file has a place (1.30.0).
    var startAt: Double? = nil
    @State private var playedOnce = false

    struct StreamGroup: Identifiable { let id: String; let addon: InstalledAddon; var streams: [AddonStream]; var error: String? }
    @State private var groups: [StreamGroup] = []
    @State private var loading = true
    @State private var starting = false
    /// Every addon answered (or failed) once (1.30.4): a load cut short
    /// (the page left mid-way) is asked again when the page is back.
    @State private var complete = false
    /// The kids profile (1.30.4): a page left open when it came on shows nothing to play.
    @ObservedObject private var kids = KidsProfile.shared

    private var videoId: String { video?.id ?? meta.id }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zoomsFromTile) private var zooms

    private var kidsVerdict: KidsRules.Verdict? {
        guard let limits = kids.activeLimits else { return nil }
        let v = KidsRules.verdict(meta, limits: limits)
        return v == .allowed ? nil : v
    }

    var body: some View {
        if let v = kidsVerdict {
            KidsBlockedView(verdict: v)
                .pageChrome(zooms: zooms, title: video?.label ?? meta.name, back: { dismiss() }) { EmptyView() }
        } else {
            streamsList
        }
    }

    private var streamsList: some View {
        List {
            if seasonVideos.count > 1 {
                Section {
                    Label("Pick a stream for \(video?.label ?? "the first episode"). The other \(seasonVideos.count - 1) episodes follow automatically with the matching stream from the same addon.",
                          systemImage: "play.square.stack").font(.footnote)
                }
            }
            if loading && groups.allSatisfy({ $0.streams.isEmpty }) {
                FolioWorkingRow(text: "Asking addons…", size: .regular)
            }
            ForEach(groups) { g in
                Section(g.addon.manifest.name) {
                    if let e = g.error { Text(e).font(.caption).foregroundStyle(.orange) }
                    ForEach(g.streams) { s in
                        Button { play(s, from: g.addon) } label: { StreamRow(stream: s) }
                            .disabled(!s.isPlayable || starting)
                            .swipeActions(edge: .trailing) {
                                if s.isPlayable {
                                    Button { download(s) } label: { Label("Download", systemImage: "arrow.down.circle") }.tint(Theme.swipeTint)
                                }
                            }
                            .contextMenu {
                                if s.isPlayable {
                                    Button { play(s, from: g.addon) } label: { Label("Play", systemImage: "play") }
                                    Button { download(s) } label: { Label("Download", systemImage: "arrow.down.circle") }
                                }
                            } preview: {
                                // All of it, also held upright (1.26.2).
                                StreamRow(stream: s, full: true)
                                    .padding(14)
                                    .frame(width: 360)
                                    .background(Theme.background)
                            }
                    }
                    if g.streams.isEmpty && g.error == nil && !loading {
                        Text("No streams").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !loading && groups.isEmpty {
                ContentUnavailableView("No Streams", systemImage: "antenna.radiowaves.left.and.right.slash",
                                       description: Text("None of your addons has streams for this title. Add a stream addon in Discover → Addons."))
                    .listRowBackground(Color.clear)
            }
        }
        .overlay { if starting { FolioSpinner(size: .large).padding(20).glass() } }
        .overlay(alignment: .bottom) {
            if let note = downloadNote {
                Text(note).font(.footnote.weight(.semibold)).multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 10).glass(cornerRadius: 18)
                    .padding(.bottom, 24).padding(.horizontal, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .brandListBackground()
        .pageChrome(zooms: zooms, title: video?.label ?? meta.name, back: { dismiss() }) { EmptyView() }
        .task { if !complete { await load(fresh: false) } }
        // Past this app's cache of the addons' answers (1.30.4): a pull to
        // refresh got the cached, possibly empty, answer again.
        .refreshable { await load(fresh: true) }
    }

    /// `fresh`: asked of the addons themselves. What's listed stays when an
    /// addon fails or comes back empty this time (1.30.4: a failed refresh
    /// emptied the list).
    private func load(fresh: Bool) async {
        loading = true
        let addons = AddonStore.shared.streamAddons(type: meta.type, id: videoId)
        let had = Dictionary(groups.map { ($0.id, $0.streams) }, uniquingKeysWith: { a, _ in a })
        groups = addons.map { StreamGroup(id: $0.id, addon: $0, streams: had[$0.id] ?? []) }
        let type = meta.type, vid = videoId
        await withTaskGroup(of: (String, [AddonStream]?, String?).self) { tg in
            for a in addons {
                tg.addTask {
                    do {
                        var list = try await AddonAPI.streams(a, type: type, id: vid, fresh: fresh)
                        // Nothing playable from the cache: the addon itself, once.
                        if !fresh, !list.contains(where: \.isPlayable), let again = try? await AddonAPI.streams(a, type: type, id: vid, fresh: true) { list = again }
                        return (a.id, list, nil)
                    } catch {
                        // Cut short: no error under the addon, and asked again on return.
                        if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return (a.id, nil, nil) }
                        return (a.id, nil, error.localizedDescription)
                    }
                }
            }
            for await (id, streams, err) in tg {
                guard let i = groups.firstIndex(where: { $0.id == id }) else { continue }
                if let streams, !streams.isEmpty || groups[i].streams.isEmpty {
                    groups[i].streams = streams
                    groups[i].error = nil
                } else if groups[i].streams.isEmpty {
                    groups[i].error = err
                }
            }
        }
        guard !Task.isCancelled else { return }
        complete = true
        loading = false
    }

    @State private var downloadNote: String?

    /// Download instead of watch (1.17.0): the stream's file goes into the
    /// library under the title's name, through the Downloads queue.
    private func download(_ s: AddonStream) {
        guard let raw = s.url, let u = URL(string: raw), u.scheme?.lowercased().hasPrefix("http") == true else {
            show("Only direct links can be downloaded.")
            return
        }
        let name = Self.fileName(for: s, meta: meta, video: video, url: u)
        let added = DownloadManager.shared.enqueue(stream: u, fileName: name, package: meta.name,
                                                   expected: Int64(s.behaviorHints?.videoSize ?? 0),
                                                   headers: s.behaviorHints?.proxyHeaders?.request ?? [:])
        show(added ? "Downloading \(name)" : "Already in Downloads")
    }

    private func show(_ note: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { downloadNote = note }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeOut(duration: 0.25)) { if downloadNote == note { downloadNote = nil } }
        }
    }

    /// The addon's own file name when it gives one (release names keep the
    /// library's episode matching), else "Title S01E02.<ext>".
    static func fileName(for s: AddonStream, meta: MetaItem, video: MetaVideo?, url: URL) -> String {
        if let f = s.behaviorHints?.filename?.trimmingCharacters(in: .whitespacesAndNewlines), !f.isEmpty, TitleParser.isMedia(f) {
            return f.replacingOccurrences(of: "/", with: "-")
        }
        let ext = TitleParser.isMedia(url.lastPathComponent) ? url.pathExtension : "mkv"
        var base = meta.name
        if let v = video, let se = v.season, let ep = v.episode { base += String(format: " S%02dE%02d", se, ep) }
        return base.replacingOccurrences(of: "/", with: "-") + "." + ext
    }

    private func context(for v: MetaVideo?) -> PlayContext {
        PlayContext(name: meta.name, poster: meta.poster, type: meta.type, metaId: meta.id, isAnime: meta.isAnime,
                    videoId: v?.id ?? meta.id, videoLabel: v?.label, episode: v?.episode)
    }

    private func play(_ s: AddonStream, from addon: InstalledAddon) {
        starting = true
        Task {
            let first = context(for: video)
            let subs = await AddonPlayback.subtitles(type: meta.type, videoId: videoId)
            guard let item = AddonPlayback.makeItem(first, stream: s, addon: addon, extraSubtitles: subs) else { starting = false; return }
            starting = false
            // "Start over" and the carried place are for the first play from
            // this page: a second pick starts where the first one stopped.
            let firstPlay = !playedOnce
            playedOnce = true
            if seasonVideos.count > 1 {
                // Play Season: the rest follow, each resolved just before it plays.
                let pick = AddonPlayback.pick(from: s, addon: addon, context: first)
                let rest = seasonVideos.dropFirst().map { context(for: $0) }
                dlog("player", "season: \(seasonVideos.count) episodes from \(addon.manifest.name), release group \(pick.bingeGroup ?? "none"), \(pick.resolution ?? "?")")
                PlayerPresenter.play(queue: AddonPlayback.seasonQueue(first: item, rest: rest, pick: pick), index: 0,
                                     fromStart: fromStart && firstPlay, startAt: firstPlay ? startAt : nil)
            } else {
                PlayerPresenter.play(queue: [item], index: 0, fromStart: fromStart && firstPlay, startAt: firstPlay ? startAt : nil)
            }
        }
    }
}

struct StreamRow: View {
    let stream: AddonStream
    /// Every line whatever the width (the long-press preview).
    var full = false
    @Environment(\.verticalSizeClass) private var vertical
    @Environment(\.horizontalSizeClass) private var horizontal

    /// Every line of the addon's description where there's room for it (1.26.2):
    /// a phone held sideways, or an iPad. Held upright, six (until then six
    /// everywhere, so a sideways phone still cut the file name and what
    /// followed it). Ellipses inside a line come from the addon itself.
    private var lineLimit: Int? { full || vertical == .compact || horizontal == .regular ? nil : 6 }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(stream.displayName)
                .font(.caption.weight(.bold))
                .multilineTextAlignment(.center)
                .frame(width: 78)
                .padding(.vertical, 8)
                .background(stream.isPlayable ? Theme.accentSoft : Theme.card, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(stream.displayTitle.isEmpty ? (stream.behaviorHints?.filename ?? "Stream") : stream.displayTitle)
                    .font(.caption).lineLimit(lineLimit)
                    .fixedSize(horizontal: false, vertical: lineLimit == nil)
                if !stream.isPlayable {
                    Text(stream.infoHash != nil ? "Torrent stream — use a debrid-enabled addon config" : "Not a direct link")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .opacity(stream.isPlayable ? 1 : 0.5)
    }
}

/// In the player (1.17.0): the next episode has no stream of the release
/// being watched, so you choose one; the episodes after it follow that one.
struct StreamPickerSheet: View {
    let context: PlayContext
    let onPick: (AddonStream, InstalledAddon) -> Void
    /// Shown inside the player, not as a sheet (1.17.1): Cancel calls this.
    var onCancel: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    /// The asking is the loader's, begun as the picker is made (1.30.3):
    /// it was the view's `.task`, and nothing else showed whether it ran.
    @StateObject private var loader: StreamPickerLoader

    init(context: PlayContext, onPick: @escaping (AddonStream, InstalledAddon) -> Void, onCancel: (() -> Void)? = nil) {
        self.context = context
        self.onPick = onPick
        self.onCancel = onCancel
        _loader = StateObject(wrappedValue: StreamPickerLoader(context: context))
    }

    private var label: String { context.videoLabel ?? context.name }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("The release you're watching isn't available for \(label). Pick a stream; the next episodes will follow it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if loader.loading && loader.isEmpty {
                    FolioWorkingRow(text: "Asking addons…", size: .regular)
                }
                ForEach(loader.groups) { g in
                    Section(g.addon.manifest.name) {
                        if let e = g.error { Text(e).font(.caption).foregroundStyle(.orange) }
                        ForEach(g.streams) { s in
                            Button { onPick(s, g.addon) } label: { StreamRow(stream: s) }
                                .disabled(!s.isPlayable)
                        }
                    }
                }
                // Nothing to pick says so, with a way to ask again (1.30.3):
                // the list was left blank under the first line.
                if !loader.loading && loader.isEmpty {
                    ContentUnavailableView {
                        Label("No Streams", systemImage: "antenna.radiowaves.left.and.right.slash")
                    } description: {
                        Text(loader.groups.isEmpty
                             ? "None of your addons that are switched on has streams for this title."
                             : "No addon gave a stream for \(label) just now.")
                    } actions: {
                        Button("Ask Again") { loader.ask(fresh: true) }
                            .buttonStyle(.borderedProminent)
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle(label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if let onCancel { onCancel() } else { dismiss() } } } }
            .refreshable { await loader.load(fresh: true) }
        }
        // Closed (1.30.4): the asking stops; it went on after the picker had gone.
        // Shown again with nothing listed: asked again.
        .onDisappear { loader.cancel() }
        .onAppear { if !loader.loading && loader.isEmpty { loader.ask(fresh: false) } }
    }
}

/// Asks every stream addon for the picker's episode: the same addons, type
/// and video id as the title page's streams list (StreamsView.load).
@MainActor
final class StreamPickerLoader: ObservableObject {
    @Published private(set) var groups: [StreamsView.StreamGroup] = []
    @Published private(set) var loading = true
    let context: PlayContext
    /// The latest asking: an older one that answers later changes nothing.
    private var asking = 0
    /// The asking under way (1.30.4), stopped when the picker closes.
    private var work: Task<Void, Never>?

    var isEmpty: Bool { groups.allSatisfy { $0.streams.isEmpty } }
    private var label: String { context.videoLabel ?? context.name }

    init(context: PlayContext) {
        self.context = context
        ask(fresh: false)
    }

    func ask(fresh: Bool) {
        work?.cancel()
        work = Task { [weak self] in await self?.load(fresh: fresh) }
    }

    /// The picker closed: nothing more is asked, and an answer still on its way changes nothing.
    func cancel() {
        work?.cancel()
        work = nil
        asking += 1
        loading = false
    }

    /// 27 Oct report: E7 and E8 showed the addon's name and no streams here,
    /// though the same addon had just answered with streams when the episode
    /// was checked (that check is what opened this picker), and the title
    /// page listed them. What the addon gave in the last 10 minutes is shown
    /// at once; asking again only replaces it with an answer that has streams.
    ///
    /// 1.30.3 (13 Nov report: no streams at all here, though the title page
    /// then listed them): when no addon gives a stream, they are asked once
    /// more a moment later, past this app's cache of their answers. The
    /// first asking can come while the season check is still asking the
    /// same addon for every later episode, and an empty or failed answer
    /// was the end of it. `fresh`: past the cache from the start (Ask Again).
    func load(fresh: Bool) async {
        asking += 1
        let mine = asking
        loading = true
        let type = context.type, videoId = context.videoId
        let addons = AddonStore.shared.streamAddons(type: type, id: videoId)
        dlog("player", "picker: asking \(addons.count) addon(s) for \(label) (\(type), \(videoId))\(fresh ? ", past the cache" : "")")
        let shown = Dictionary(groups.map { ($0.id, $0.streams) }, uniquingKeysWith: { a, _ in a })
        groups = addons.map { a in
            let recent = AddonPlayback.recentStreams[AddonPlayback.recentKey(a.id, videoId)]
            let kept = recent.map { Date().timeIntervalSince($0.at) < 600 } ?? false
            // Asked again: what's listed stays until a new answer has streams.
            let had = shown[a.id] ?? []
            return StreamsView.StreamGroup(id: a.id, addon: a, streams: !had.isEmpty ? had : (kept ? recent!.streams : []))
        }
        for attempt in 0..<2 where !addons.isEmpty {
            let past = fresh || attempt > 0
            await withTaskGroup(of: (String, [AddonStream]?, String?).self) { tg in
                for a in addons {
                    tg.addTask {
                        do { return (a.id, try await AddonAPI.streams(a, type: type, id: videoId, fresh: past), nil) }
                        catch { return (a.id, nil, error.localizedDescription) }
                    }
                }
                for await (id, streams, err) in tg {
                    guard mine == asking, let i = groups.firstIndex(where: { $0.id == id }) else { continue }
                    let had = groups[i].streams.count
                    dlog("player", "picker: \(groups[i].addon.manifest.name) answered \(streams?.count ?? 0) stream(s) for \(label)\(err.map { " (\($0))" } ?? "")\(had > 0 ? ", \(had) listed already" : "")")
                    if let streams, !streams.isEmpty {
                        groups[i].streams = streams
                        groups[i].error = nil
                        AddonPlayback.recentStreams[AddonPlayback.recentKey(id, videoId)] = (Date(), streams)
                    } else if had == 0 {
                        groups[i].error = err ?? "No streams came back for \(label)."
                    }
                }
            }
            guard mine == asking else { return }        // a newer asking has the list
            guard isEmpty, attempt == 0 else { break }
            dlog("player", "picker: no addon gave a stream for \(label); asking once more")
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard mine == asking else { return }
        }
        loading = false
    }
}
