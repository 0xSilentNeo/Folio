import SwiftUI

/// A row of an addon's catalog (on Discover since 1.27.0).
struct CatalogRow: View {
    let addon: InstalledAddon
    let catalog: AddonManifest.Catalog
    var margin: CGFloat = 16
    @Namespace private var zoomNS
    @State private var metas: [MetaItem] = []
    @State private var failed = false
    @State private var loaded = false

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
                        Text("Couldn't load").font(.caption).foregroundStyle(.secondary).frame(height: 177)
                    }
                }
                .padding(.horizontal, margin)
            }
        }
        .task {
            guard !loaded else { return }
            var extra: [String: String] = [:]
            if catalog.requiredExtras.contains("genre"), let g = catalog.genreOptions.first { extra["genre"] = g }
            do { metas = try await AddonAPI.catalog(addon, catalog, extra: extra) } catch { failed = true }
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
            PosterImage(url: meta.poster, aspect: meta.posterShape == "landscape" ? 16.0 / 9.0 : (meta.posterShape == "square" ? 1 : 2.0 / 3.0))
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
        }
        .background(Theme.background)
        .brandListBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if catalog.requiredExtras.contains("genre") { genre = catalog.genreOptions.first }
            if metas.isEmpty { await loadMore() }
        }
        .onChange(of: genre) { _, _ in
            metas = []; exhausted = false
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

    private func loadMore() async {
        guard !loading, !exhausted else { return }
        loading = true
        defer { loading = false }
        var extra: [String: String] = [:]
        if let genre { extra["genre"] = genre }
        if !metas.isEmpty { extra["skip"] = String(metas.count) }
        let page = (try? await AddonAPI.catalog(addon, catalog, extra: extra)) ?? []
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

    private var videoId: String { video?.id ?? meta.id }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zoomsFromTile) private var zooms

    var body: some View {
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
        .task { if groups.isEmpty { await load() } }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        let addons = AddonStore.shared.streamAddons(type: meta.type, id: videoId)
        groups = addons.map { StreamGroup(id: $0.id, addon: $0, streams: []) }
        await withTaskGroup(of: (String, [AddonStream]?, String?).self) { tg in
            for a in addons {
                tg.addTask {
                    do { return (a.id, try await AddonAPI.streams(a, type: meta.type, id: videoId), nil) }
                    catch { return (a.id, nil, error.localizedDescription) }
                }
            }
            for await (id, streams, err) in tg {
                if let i = groups.firstIndex(where: { $0.id == id }) {
                    groups[i].streams = streams ?? []
                    groups[i].error = err
                }
            }
        }
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
                let rest = seasonVideos.dropFirst().map { AddonPlayback.placeholder(context(for: $0), pick: pick) }
                dlog("player", "season: \(seasonVideos.count) episodes from \(addon.manifest.name), release group \(pick.bingeGroup ?? "none"), \(pick.resolution ?? "?")")
                PlayerPresenter.play(queue: [item] + rest, index: 0, fromStart: fromStart && firstPlay, startAt: firstPlay ? startAt : nil)
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
    @State private var groups: [StreamsView.StreamGroup] = []
    @State private var loading = true

    private var label: String { context.videoLabel ?? context.name }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("The release you're watching isn't available for \(label). Pick a stream; the next episodes will follow it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if loading && groups.allSatisfy({ $0.streams.isEmpty }) {
                    FolioWorkingRow(text: "Asking addons…", size: .regular)
                }
                ForEach(groups) { g in
                    Section(g.addon.manifest.name) {
                        if let e = g.error { Text(e).font(.caption).foregroundStyle(.orange) }
                        ForEach(g.streams) { s in
                            Button { onPick(s, g.addon) } label: { StreamRow(stream: s) }
                                .disabled(!s.isPlayable)
                        }
                    }
                }
            }
            .navigationTitle(label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if let onCancel { onCancel() } else { dismiss() } } } }
            .refreshable { await load() }
        }
        .task { await load() }
    }

    /// 27 Oct report: E7 and E8 showed the addon's name and no streams here,
    /// though the same addon had just answered with streams when the episode
    /// was checked (that check is what opened this picker), and the title
    /// page listed them. What the addon gave in the last 10 minutes is shown
    /// at once; asking again only replaces it with an answer that has streams.
    private func load() async {
        let addons = AddonStore.shared.streamAddons(type: context.type, id: context.videoId)
        groups = addons.map { a in
            let recent = AddonPlayback.recentStreams[AddonPlayback.recentKey(a.id, context.videoId)]
            let fresh = recent.map { Date().timeIntervalSince($0.at) < 600 } ?? false
            return StreamsView.StreamGroup(id: a.id, addon: a, streams: fresh ? recent!.streams : [])
        }
        await withTaskGroup(of: (String, [AddonStream]?, String?).self) { tg in
            for a in addons {
                tg.addTask {
                    do { return (a.id, try await AddonAPI.streams(a, type: context.type, id: context.videoId), nil) }
                    catch { return (a.id, nil, error.localizedDescription) }
                }
            }
            for await (id, streams, err) in tg {
                guard let i = groups.firstIndex(where: { $0.id == id }) else { continue }
                let had = groups[i].streams.count
                dlog("player", "picker: \(groups[i].addon.manifest.name) answered \(streams?.count ?? 0) stream(s) for \(label)\(err.map { " (\($0))" } ?? "")\(had > 0 ? ", \(had) from the episode check" : "")")
                if let streams, !streams.isEmpty {
                    groups[i].streams = streams
                    AddonPlayback.recentStreams[AddonPlayback.recentKey(id, context.videoId)] = (Date(), streams)
                } else if had == 0 {
                    groups[i].error = err ?? "No streams came back for \(label). Pull down to ask again."
                }
            }
        }
        loading = false
    }
}
