import SwiftUI

struct CatalogRow: View {
    let addon: InstalledAddon
    let catalog: AddonManifest.Catalog
    @State private var metas: [MetaItem] = []
    @State private var failed = false
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(catalogTitle).font(.title3.weight(.bold))
                    Text(addon.manifest.name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                NavigationLink {
                    CatalogGridView(addon: addon, catalog: catalog, title: catalogTitle)
                } label: {
                    Text("See all").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    if !loaded {
                        ForEach(0..<6, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 12).fill(Theme.card).frame(width: 118, height: 177)
                        }
                    }
                    ForEach(metas) { m in
                        NavigationLink { MetaDetailView(preview: m, sourceAddon: addon) } label: {
                            PosterCard(meta: m, width: catalogShape == "landscape" ? 210 : 118)
                        }
                        .buttonStyle(.plain)
                    }
                    if failed {
                        Text("Couldn't load").font(.caption).foregroundStyle(.secondary).frame(height: 177)
                    }
                }
                .padding(.horizontal, 16)
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
    private var catalogTitle: String {
        let n = catalog.name ?? catalog.id
        return "\(n) · \(catalog.type.capitalized)"
    }
}

struct PosterCard: View {
    let meta: MetaItem
    var width: CGFloat? = 118

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterImage(url: meta.poster, aspect: meta.posterShape == "landscape" ? 16.0 / 9.0 : (meta.posterShape == "square" ? 1 : 2.0 / 3.0))
                .frame(width: width)
                .overlay(alignment: .topLeading) {
                    if let rank = meta.rank {
                        Text("#\(rank)").font(.caption2.weight(.heavy))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.65), in: Capsule())
                            .padding(6)
                    }
                }
                .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
            Text(meta.name).font(.caption.weight(.medium)).lineLimit(1).frame(width: width, alignment: .leading)
            let sub = [meta.imdbRating.map { "★ \($0)" }, meta.releaseInfo].compactMap { $0 }.joined(separator: " · ")
            if !sub.isEmpty {
                Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
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
                    NavigationLink { MetaDetailView(preview: m, sourceAddon: addon) } label: {
                        PosterCard(meta: m, width: 108)
                    }
                    .buttonStyle(.plain)
                    .onAppear { if m.id == metas.last?.id { Task { await loadMore() } } }
                }
            }
            .padding(16)
            if loading { ProgressView().padding() }
        }
        .background(Theme.background)
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

struct MetaDetailView: View {
    let preview: MetaItem
    let sourceAddon: InstalledAddon?
    @State private var meta: MetaItem?
    @State private var season: Int = 1
    @State private var seasons: [Int] = []
    @State private var episodes: [MetaVideo] = []
    @State private var loadingEpisodes = false
    @ObservedObject private var history = HistoryStore.shared

    private var m: MetaItem { meta ?? preview }
    private var resolvedID: String { meta?.id ?? preview.id }
    private var usesIMDb: Bool { resolvedID.hasPrefix("tt") }
    private var allSeasons: [Int] { usesIMDb ? seasons : m.seasons }
    private var allVideos: [MetaVideo] { usesIMDb ? episodes : (m.videos ?? []) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                VStack(alignment: .leading, spacing: 12) {
                    Text(m.name).font(.largeTitle.weight(.bold))
                    HStack(spacing: 10) {
                        if let r = m.releaseInfo { tag(r) }
                        if let r = m.runtime { tag(r) }
                        if let r = m.imdbRating { tag("★ \(r)") }
                    }
                    if let g = m.genres, !g.isEmpty {
                        Text(g.prefix(4).joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if m.type == "movie" || (allVideos.isEmpty && allSeasons.isEmpty && !loadingEpisodes) {
                        NavigationLink {
                            StreamsView(meta: m, video: nil)
                        } label: {
                            Label(resumeLabel(for: m.id) ?? "Find streams", systemImage: "play.fill")
                                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                                .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 16))
                                .foregroundStyle(.white)
                        }
                    }
                    if let d = m.description {
                        Text(d).font(.callout).foregroundStyle(.white.opacity(0.85))
                    }
                    if let c = m.cast, !c.isEmpty {
                        Text("Cast: " + c.prefix(6).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    }
                    if let d = m.director, !d.isEmpty {
                        Text((m.type == "series" ? "Created by: " : "Directed by: ") + d.prefix(3).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)

                if m.type != "movie" && (!allVideos.isEmpty || !allSeasons.isEmpty) {
                    episodeList(allVideos)
                }
                if loadingEpisodes && allVideos.isEmpty { ProgressView().frame(maxWidth: .infinity).padding() }
            }
            .padding(.bottom, 30)
        }
        .background(Theme.background)
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard meta == nil else { return }
            var id = preview.id
            if id.hasPrefix("tmdb:") {
                guard let imdb = await TMDB.imdbID(for: preview) else { return }
                id = imdb
            }
            if id.hasPrefix("tt") {
                if var full = await IMDbSource.details(id: id, type: preview.type) {
                    if full.poster == nil { full.poster = preview.poster }
                    if full.background == nil { full.background = preview.background }
                    if full.type == "movie" && preview.type == "series" { full.type = "series" }
                    meta = full
                } else {
                    var p = preview; p.id = id; meta = p
                }
                if m.type != "movie" {
                    loadingEpisodes = true
                    seasons = await IMDbSource.seasons(id: id)
                    if let first = seasons.first {
                        season = first
                        episodes = await IMDbSource.episodes(id: id, season: first)
                    }
                    loadingEpisodes = false
                }
            } else {
                guard let addon = AddonStore.shared.metaAddon(type: preview.type, id: id, preferred: sourceAddon) else { return }
                if var full = try? await AddonAPI.meta(addon, type: preview.type, id: id) {
                    if full.poster == nil { full.poster = preview.poster }
                    meta = full
                }
                if let first = meta?.seasons.first { season = first }
            }
        }
        .task(id: season) {
            guard usesIMDb, m.type != "movie", !seasons.isEmpty else { return }
            loadingEpisodes = true
            let eps = await IMDbSource.episodes(id: resolvedID, season: season)
            if !Task.isCancelled { episodes = eps; loadingEpisodes = false }
        }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            PosterImage(url: m.background ?? m.poster, aspect: 16.0 / 9.0, cornerRadius: 0)
                .overlay(LinearGradient(colors: [.clear, Theme.background], startPoint: .center, endPoint: .bottom))
            if let logo = m.logo, let u = URL(string: logo) {
                CachedImage(url: u, maxPixel: 600) { img in img.resizable().scaledToFit() } placeholder: { EmptyView() }
                    .frame(maxWidth: 220, maxHeight: 80)
                    .padding(16)
            }
        }
    }

    private func tag(_ s: String) -> some View {
        Text(s).font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.card, in: Capsule())
    }

    private func resumeLabel(for videoId: String) -> String? {
        guard let e = history.entry(for: "addon:\(videoId)"), e.canResume else { return nil }
        return "Resume from \(PlayerModel.format(e.position))"
    }

    @ViewBuilder
    private func episodeList(_ videos: [MetaVideo]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if allSeasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(allSeasons, id: \.self) { s in
                            Button { season = s } label: {
                                Text(s == 0 ? "Specials" : "Season \(s)").font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(season == s ? Theme.accent : Theme.card, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            let seasonEps = videos.filter { allSeasons.isEmpty || $0.season == season }.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
            if seasonEps.count > 1 {
                // Whole season: starts at the first episode not finished yet.
                let startAt = seasonEps.firstIndex { history.entry(for: "addon:\($0.id)")?.isFinished != true } ?? 0
                NavigationLink {
                    StreamsView(meta: m, video: seasonEps[startAt], seasonVideos: Array(seasonEps[startAt...]))
                } label: {
                    Label(startAt == 0 ? (season == 0 ? "Play all specials" : "Play Season \(season)")
                                       : "Continue Season \(season) · E\(seasonEps[startAt].episode ?? startAt + 1)",
                          systemImage: "play.square.stack.fill")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
            }
            LazyVStack(spacing: 10) {
                ForEach(seasonEps) { v in
                    NavigationLink { StreamsView(meta: m, video: v) } label: { EpisodeRow(video: v, entry: history.entry(for: "addon:\(v.id)")) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

struct EpisodeRow: View {
    let video: MetaVideo
    let entry: HistoryEntry?

    private var episodeTitle: String {
        if let e = video.episode { return "\(e). " + (video.title ?? "Episode \(e)") }
        return video.title ?? video.id
    }
    var body: some View {
        HStack(spacing: 12) {
            PosterImage(url: video.thumbnail, aspect: 16.0 / 9.0, cornerRadius: 10)
                .frame(width: 130)
                .overlay(alignment: .bottom) {
                    if let entry, entry.progress > 0.01 {
                        GeometryReader { g in
                            Rectangle().fill(Theme.accent).frame(width: g.size.width * entry.progress, height: 3)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(episodeTitle)
                    .font(.subheadline.weight(.semibold)).lineLimit(2)
                if let o = video.overview { Text(o).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                if video.rating != nil || video.released != nil {
                    Text([video.rating.map { "★ \($0)" }, video.released].compactMap { $0 }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                }
                if let entry, entry.isFinished {
                    Label("Watched", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(Theme.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Streams

struct StreamsView: View {
    let meta: MetaItem
    let video: MetaVideo?
    /// Play Season: this episode and the ones after it (first = `video`).
    var seasonVideos: [MetaVideo] = []

    struct StreamGroup: Identifiable { let id: String; let addon: InstalledAddon; var streams: [AddonStream]; var error: String? }
    @State private var groups: [StreamGroup] = []
    @State private var loading = true
    @State private var starting = false

    private var videoId: String { video?.id ?? meta.id }

    var body: some View {
        List {
            if seasonVideos.count > 1 {
                Section {
                    Label("Pick a stream for \(video?.label ?? "the first episode"). The other \(seasonVideos.count - 1) episodes follow automatically with the matching stream from the same addon.",
                          systemImage: "play.square.stack").font(.footnote)
                }
            }
            if loading && groups.allSatisfy({ $0.streams.isEmpty }) {
                HStack { ProgressView(); Text("Asking addons…").foregroundStyle(.secondary) }
            }
            ForEach(groups) { g in
                Section(g.addon.manifest.name) {
                    if let e = g.error { Text(e).font(.caption).foregroundStyle(.orange) }
                    ForEach(g.streams) { s in
                        Button { play(s, from: g.addon) } label: { StreamRow(stream: s) }
                            .disabled(!s.isPlayable || starting)
                    }
                    if g.streams.isEmpty && g.error == nil && !loading {
                        Text("No streams").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !loading && groups.isEmpty {
                Text("None of your addons provide streams for this title. Add a stream addon in Discover → Addons.")
                    .foregroundStyle(.secondary)
            }
        }
        .overlay { if starting { ProgressView().controlSize(.large).padding(20).glass() } }
        .navigationTitle(video?.label ?? meta.name)
        .navigationBarTitleDisplayMode(.inline)
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
            if seasonVideos.count > 1 {
                // Play Season: the rest follow, each resolved just before it plays.
                let pick = AddonPlayback.pick(from: s, addon: addon, context: first)
                let rest = seasonVideos.dropFirst().map { AddonPlayback.placeholder(context(for: $0), pick: pick) }
                dlog("player", "season: \(seasonVideos.count) episodes from \(addon.manifest.name), release group \(pick.bingeGroup ?? "none"), \(pick.resolution ?? "?")")
                PlayerPresenter.play(queue: [item] + rest, index: 0)
            } else {
                PlayerPresenter.play(item)
            }
        }
    }
}

struct StreamRow: View {
    let stream: AddonStream
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
                    .font(.caption).lineLimit(6)
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

// MARK: - Search

struct AddonSearchView: View {
    @State private var query = ""
    struct SearchResult: Identifiable { let id: String; let title: String; let addon: InstalledAddon?; let metas: [MetaItem] }
    @State private var results: [SearchResult] = []
    @State private var searching = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if searching { ProgressView().frame(maxWidth: .infinity).padding() }
                ForEach(results) { r in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(r.title).font(.headline).padding(.horizontal, 16)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 12) {
                                ForEach(r.metas) { m in
                                    NavigationLink { MetaDetailView(preview: m, sourceAddon: r.addon) } label: { PosterCard(meta: m) }
                                        .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
                if !searching && results.isEmpty && !query.isEmpty {
                    Text("No results").foregroundStyle(.secondary).padding()
                }
            }
            .padding(.vertical, 12)
        }
        .background(Theme.background)
        .navigationTitle("Search")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Movies, shows, anime")
        .onSubmit(of: .search) { run() }
    }

    private func run() {
        task?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        results = []
        task = Task {
            let imdb = await IMDbSource.search(q)
            if Task.isCancelled { return }
            if !imdb.isEmpty { results.append(SearchResult(id: "imdb", title: "IMDb", addon: nil, metas: imdb)) }
            let targets = AddonStore.shared.addons.flatMap { a in a.manifest.catalogs.filter(\.supportsSearch).map { (a, $0) } }
            await withTaskGroup(of: (String, String, InstalledAddon, [MetaItem]).self) { tg in
                for (a, c) in targets {
                    tg.addTask {
                        let metas = (try? await AddonAPI.catalog(a, c, extra: ["search": q])) ?? []
                        return (a.id + c.type + c.id, "\(c.name ?? c.id) · \(c.type.capitalized) — \(a.manifest.name)", a, metas)
                    }
                }
                for await r in tg where !r.3.isEmpty && !Task.isCancelled {
                    results.append(SearchResult(id: r.0, title: r.1, addon: r.2, metas: r.3))
                }
            }
            searching = false
        }
    }
}

// MARK: - Manager

struct AddonsManagerView: View {
    @ObservedObject private var store = AddonStore.shared
    @State private var url = ""
    @State private var error: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("https://…/manifest.json or stremio://", text: $url)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Button {
                        Task {
                            do { try await store.install(url); url = ""; error = nil } catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        if store.installing { ProgressView() } else { Text("Install").fontWeight(.semibold) }
                    }
                    .disabled(url.isEmpty || store.installing)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                Button("Paste from clipboard") { url = UIPasteboard.general.string ?? "" }
            } header: { Text("Add addon") } footer: {
                Text("Works with Stremio-protocol addons (Torrentio/Comet/MediaFusion with your debrid key, OpenSubtitles, Kitsu/anime catalogs…). Configure an addon on its website, then paste the manifest link here. Only direct HTTP(S) streams can play; raw torrents need a debrid-configured addon. Titles, posters and ratings come from IMDb; addons only need to provide streams.")
            }
            Section("Installed") {
                ForEach(store.addons) { a in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            if let logo = a.manifest.logo, let u = URL(string: logo) {
                                CachedImage(url: u, maxPixel: 120) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
                                    .frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            Text(a.manifest.name).font(.headline)
                            if let v = a.manifest.version { Text("v\(v)").font(.caption).foregroundStyle(.secondary) }
                        }
                        Text(a.manifest.resources.map(\.name).joined(separator: " · ")).font(.caption).foregroundStyle(Theme.accent)
                        if let d = a.manifest.description { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                    }
                    .swipeActions {
                        Button(role: .destructive) { store.remove(a) } label: { Label("Remove", systemImage: "trash") }
                        if a.manifest.configurable {
                            Button {
                                if let u = URL(string: a.baseURL + "/configure") { openURL(u) }
                            } label: { Label("Configure", systemImage: "gear") }
                            .tint(.gray)
                        }
                    }
                    .contextMenu {
                        Button { UIPasteboard.general.string = a.transportURL } label: { Label("Copy manifest URL", systemImage: "doc.on.doc") }
                    }
                }
                .onMove { store.move(from: $0, to: $1) }
            }
        }
        .navigationTitle("Addons")
        .toolbar { EditButton() }
    }
}
