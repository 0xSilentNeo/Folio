import SwiftUI

/// Streaming-service catalogs (what's on Netflix, Prime Video, Max, Disney+…)
/// from the public "Streaming Catalogs" addon. Items carry IMDb ids,
/// so details come from IMDb and streams from your stream addons.
struct StreamingPlatform: Identifiable, Hashable {
    let id: String
    let name: String
    let short: String
    let color: Color
    let color2: Color

    static let all: [StreamingPlatform] = [
        .init(id: "nfx", name: "Netflix", short: "N", color: Color(red: 0.90, green: 0.04, blue: 0.08), color2: Color(red: 0.45, green: 0.0, blue: 0.02)),
        .init(id: "amp", name: "Prime Video", short: "prime", color: Color(red: 0.0, green: 0.66, blue: 0.88), color2: Color(red: 0.0, green: 0.25, blue: 0.45)),
        .init(id: "hbm", name: "HBO Max", short: "max", color: Color(red: 0.0, green: 0.17, blue: 0.91), color2: Color(red: 0.35, green: 0.13, blue: 0.70)),
        .init(id: "dnp", name: "Disney+", short: "D+", color: Color(red: 0.07, green: 0.24, blue: 0.81), color2: Color(red: 0.02, green: 0.08, blue: 0.30)),
        .init(id: "atp", name: "Apple TV+", short: "tv+", color: Color(white: 0.55), color2: Color(white: 0.12)),
        .init(id: "pmp", name: "Paramount+", short: "P+", color: Color(red: 0.0, green: 0.39, blue: 1.0), color2: Color(red: 0.0, green: 0.12, blue: 0.40)),
        .init(id: "hlu", name: "Hulu", short: "hulu", color: Color(red: 0.11, green: 0.91, blue: 0.51), color2: Color(red: 0.02, green: 0.35, blue: 0.20)),
        .init(id: "pcp", name: "Peacock", short: "P", color: Color(red: 0.98, green: 0.73, blue: 0.0), color2: Color(red: 0.40, green: 0.10, blue: 0.55)),
        .init(id: "cru", name: "Crunchyroll", short: "CR", color: Color(red: 0.96, green: 0.46, blue: 0.13), color2: Color(red: 0.45, green: 0.15, blue: 0.0)),
    ]

    static func byID(_ id: String) -> StreamingPlatform? { all.first { $0.id == id } }

    /// Platforms shown on Discover, in order.
    static var enabled: [StreamingPlatform] {
        get {
            let ids = UserDefaults.standard.stringArray(forKey: "discoverPlatforms") ?? all.map(\.id)
            return ids.compactMap(byID)
        }
        set { UserDefaults.standard.set(newValue.map(\.id), forKey: "discoverPlatforms") }
    }
}

enum PlatformCatalogs {
    private static let host = "https://7a82163c306e-stremio-netflix-catalog-addon.baby-beamup.club"
    private static var cache: [String: (Date, [MetaItem])] = [:]
    private static let lock = NSLock()

    static var region: String {
        UserDefaults.standard.string(forKey: "discoverRegion") ?? Locale.current.region?.identifier ?? "US"
    }

    private static var base: String {
        let ids = StreamingPlatform.all.map(\.id).joined(separator: ",")
        let config = "\(ids)::\(region):1700000000000:1:0:"
        return host + "/" + Data(config.utf8).base64EncodedString()
    }

    /// The last list fetched for a catalog this launch, and when.
    static func cached(type: String, id: String) -> (metas: [MetaItem], date: Date)? {
        lock.lock(); defer { lock.unlock() }
        return cache["\(region)|\(type)|\(id)"].map { ($0.1, $0.0) }
    }

    /// type: "movie" | "series"; id: platform id. From memory when fetched in
    /// the last 30 minutes, else from the addon. Throws when the request
    /// fails or is cancelled, and then nothing is kept: until 1.19.0 any
    /// failure, a cancelled request included, was kept as an empty list for
    /// 30 minutes (your 30 Oct log: Prime Video's Movies request "cancelled"
    /// as the tab switched, then that tab stayed empty).
    static func catalog(type: String, id: String) async throws -> [MetaItem] {
        let key = "\(region)|\(type)|\(id)"
        if let hit = cached(type: type, id: id), Date().timeIntervalSince(hit.date) < 1800 {
            LibTrace.discover.log("catalog \(key): \(hit.metas.count) title(s) from memory (\(Int(Date().timeIntervalSince(hit.date))) s old)")
            return hit.metas
        }
        let t0 = Date()
        do {
            let metas = try await AddonAPI.get(AddonAPI.CatalogResponse.self, "\(base)/catalog/\(type)/\(id).json").metas ?? []
            LibTrace.discover.log("catalog \(key): \(metas.count) title(s) after \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            lock.lock(); cache[key] = (Date(), metas); lock.unlock()
            return metas
        } catch {
            LibTrace.discover.log("catalog \(key): failed (\((error as NSError).domain) \((error as NSError).code)) after \(Int(Date().timeIntervalSince(t0) * 1000)) ms; nothing kept")
            throw error
        }
    }
}

// MARK: - Discover

/// Browse filters for the main grid. Data comes from IMDb (built in) or,
/// when a key is set, TMDB.
@MainActor
final class BrowseModel: ObservableObject {
    enum Sort: String, CaseIterable, Identifiable {
        case trending, topRated, new
        var id: String { rawValue }
        var title: String { self == .trending ? "Trending" : self == .topRated ? "Top Rated" : "New" }
        var footnote: String? {
            if TMDB.enabled { return self == .topRated ? "TMDB top rated" : self == .trending ? "TMDB trending this week" : nil }
            switch self {
            case .trending: return "IMDb Most Popular (MOVIEmeter)"
            case .topRated: return "IMDb Top 250, as rated by IMDb users"
            case .new: return nil
            }
        }
        var imdb: IMDbSource.Sort { self == .trending ? .trending : self == .topRated ? .topRated : .new }
    }
    static var genres: [String] { IMDbSource.genres }
    static let years: [String] = (0..<30).map { String(Calendar.current.component(.year, from: Date()) - $0) }

    @Published var sort: Sort = .trending { didSet { reload() } }
    @Published var type = "movie" { didSet { reload() } }
    @Published var genre: String? { didSet { reload() } }
    @Published var year: String = BrowseModel.years[0] { didSet { if sort == .new { reload() } } }
    @Published var metas: [MetaItem] = []
    @Published var loading = false
    @Published var failed = false
    private var exhausted = false
    private var generation = 0
    private var task: Task<Void, Never>?

    func reload() {
        task?.cancel()
        generation += 1          // anything still in flight is stale now
        metas = []; exhausted = false; failed = false
        loading = true           // keep the spinner up through the gap, no empty-state flash
        task = Task { await load(initial: true) }
    }

    func loadMore() async { await load(initial: false) }

    private func load(initial: Bool) async {
        if !initial { guard !loading, !exhausted else { return } }
        generation += 1
        let gen = generation
        loading = true
        defer { if gen == generation { loading = false } }
        if TMDB.enabled {
            let page = await TMDB.browse(sort: sort, type: type, genre: genre, year: year, page: metas.count / 20 + 1)
            guard gen == generation else { return }
            if page.isEmpty { exhausted = true; failed = metas.isEmpty && page.isEmpty && !Task.isCancelled && TMDB.lastError }
            let known = Set(metas.map(\.id))
            metas += page.filter { !known.contains($0.id) }
            return
        }
        // IMDb lists come whole (100–250 items); nothing to page.
        guard initial || metas.isEmpty else { exhausted = true; return }
        // Last list first (any age), fresh one when it arrives.
        let stale = await IMDbSource.browse(sort: sort.imdb, type: type, genre: genre, year: year, staleOnly: true)
        if gen == generation, !stale.isEmpty, metas.isEmpty { metas = stale }
        let list = await IMDbSource.browse(sort: sort.imdb, type: type, genre: genre, year: year)
        guard gen == generation else { return }
        if !list.isEmpty || metas.isEmpty { metas = list }
        exhausted = true
        failed = metas.isEmpty
    }
}

struct DiscoverView: View {
    @ObservedObject private var store = AddonStore.shared
    @Namespace private var zoomNS
    @StateObject private var browse = BrowseModel()
    @State private var showPlatformSettings = false

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let margin: CGFloat = geo.size.width > 700 ? 28 : 20
                let cols = max(3, Int((geo.size.width - margin * 2 + 12) / 122))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        header(margin)
                        platformStrip(margin)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(gridTitle).font(.title3.weight(.bold))
                                Spacer()
                                if browse.loading && browse.metas.isEmpty { ProgressView() }
                            }
                            if let f = browse.sort.footnote { Text(f).font(.caption).foregroundStyle(.secondary) }
                        }
                        .padding(.horizontal, margin)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: cols), spacing: 18) {
                            ForEach(browse.metas) { m in
                                NavigationLink { MetaDetailView(preview: m, sourceAddon: nil).zoomDestination(m.id, in: zoomNS) } label: {
                                    PosterCard(meta: m, width: nil, zoom: ZoomSource(m.id, zoomNS))
                                }
                                    .buttonStyle(.plain)
                                    .onAppear { if m.id == browse.metas.last?.id { Task { await browse.loadMore() } } }
                            }
                        }
                        .padding(.horizontal, margin)
                        if browse.loading && !browse.metas.isEmpty { ProgressView().frame(maxWidth: .infinity) }
                        if !browse.loading && browse.metas.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(browse.failed ? "IMDb didn't answer." : "Nothing here.").foregroundStyle(.secondary)
                                if browse.failed {
                                    Text("Check the connection, then pull to retry. The diagnostics log (Settings → Help & Diagnostics) records the HTTP status.")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Button("Retry") { browse.reload() }.buttonStyle(.bordered).tint(Theme.accent)
                                }
                            }
                            .padding(.horizontal, margin)
                        }
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 90)
                }
                .scrollIndicators(.hidden)
            }
            .background(HomeBackdrop().ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) { filterBar }
            .task {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "discoverLastUsed")
                if browse.metas.isEmpty { browse.reload() }
            }
            .refreshable { browse.reload() }
            .sheet(isPresented: $showPlatformSettings) { PlatformSettingsView() }
        }
    }

    private var gridTitle: String {
        let t = browse.type == "movie" ? "Movies" : "Series"
        switch browse.sort {
        case .new: return "New \(t) · \(browse.year)"
        case .topRated: return "Top Rated \(t)" + (browse.genre.map { " · \($0)" } ?? "")
        case .trending: return "Trending \(t)" + (browse.genre.map { " · \($0)" } ?? "")
        }
    }

    private func header(_ margin: CGFloat) -> some View {
        HStack(spacing: 10) {
            Text("Discover").font(.system(size: 28, weight: .bold, design: .rounded))
            Spacer()
            NavigationLink { AddonSearchView() } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .semibold)).frame(width: 44, height: 44).glassCircle()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search")
            Menu {
                Button { showPlatformSettings = true } label: { Label("Streaming services", systemImage: "rectangle.grid.2x2") }
                NavigationLink { AddonsManagerView() } label: { Label("Addons", systemImage: "puzzlepiece.extension") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).frame(width: 44, height: 44).glassCircle()
            }
        }
        .padding(.horizontal, margin)
        .padding(.top, 8)
    }

    private func platformStrip(_ margin: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(StreamingPlatform.enabled) { p in
                    NavigationLink { PlatformDetailView(platform: p) } label: {
                        VStack(spacing: 6) {
                            PlatformBadge(platform: p, size: 56)
                            Text(p.name).font(.caption2.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(width: 68)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, margin)
        }
    }

    /// Floating Liquid Glass filter bar.
    private var filterBar: some View {
        HStack(spacing: 6) {
            SegmentPicker(options: [("movie", "Movies"), ("series", "Series")], selection: $browse.type)
                .frame(width: 160)
            Menu {
                Picker("Sort", selection: $browse.sort) { ForEach(BrowseModel.Sort.allCases) { Text($0.title).tag($0) } }
            } label: { FilterChip(title: browse.sort.title, active: true) }
            if browse.sort == .new {
                Menu {
                    Picker("Year", selection: $browse.year) { ForEach(BrowseModel.years, id: \.self) { Text($0).tag($0) } }
                } label: { FilterChip(title: browse.year, active: true) }
            } else {
                Menu {
                    Button { browse.genre = nil } label: { browse.genre == nil ? Label("All genres", systemImage: "checkmark") : Label("All genres", systemImage: "circle") }
                    Divider()
                    ForEach(BrowseModel.genres, id: \.self) { g in
                        Button { browse.genre = g } label: { if browse.genre == g { Label(g, systemImage: "checkmark") } else { Text(g) } }
                    }
                } label: { FilterChip(title: browse.genre ?? "Genre", active: browse.genre != nil) }
            }
        }
        .padding(6)
        .glass(cornerRadius: 28, interactive: true)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .tint(Theme.accent)
    }
}

struct FilterChip: View {
    let title: String
    let active: Bool
    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Image(systemName: "chevron.down").font(.caption2.weight(.bold))
        }
        .foregroundStyle(active ? Color.primary : Color.secondary)
        .padding(.horizontal, 12).frame(height: 38)
        .background(active ? Theme.fill : Color.clear, in: Capsule())
        .contentShape(Capsule())          // a clear background isn't tappable: only the text was
    }
}

struct PlatformBadge: View {
    let platform: StreamingPlatform
    var size: CGFloat = 44
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [platform.color, platform.color2], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(platform.short)
                .font(.system(size: size * (platform.short.count > 2 ? 0.24 : 0.36), weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .padding(4)
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(.white.opacity(0.15)))
    }
}

/// A provider page's two tabs, kept while the page is open: switching is
/// instant, nothing is fetched twice, a failed or interrupted load never
/// empties a grid. Each tab's load runs to the end even when you switch
/// away (until 1.19.0 switching cancelled it, and the cancelled request was
/// kept as an empty list).
@MainActor
final class PlatformPageModel: ObservableObject {
    struct Tab: Equatable {
        var metas: [MetaItem] = []
        var loading = false
        var error: String?
        /// The tab has been shown (its data is loaded only then).
        var started = false
    }

    let platform: StreamingPlatform
    @Published private(set) var tabs: [String: Tab] = [:]

    init(platform: StreamingPlatform) { self.platform = platform }

    /// The tab is on screen: the last list fetched this launch shows at once,
    /// and the first time it's loaded (a fresh copy replaces it only when the
    /// load works).
    func show(_ type: String) {
        guard tabs[type]?.started != true else { return }
        var t = Tab()
        t.started = true
        if let hit = PlatformCatalogs.cached(type: type, id: platform.id) { t.metas = hit.metas }
        tabs[type] = t
        load(type)
    }

    func load(_ type: String) {
        guard tabs[type]?.loading != true else { return }
        tabs[type, default: Tab()].loading = true
        tabs[type]?.error = nil
        LibTrace.discover.log("\(platform.name) \(type): load starts (grid shows \(tabs[type]?.metas.count ?? 0))")
        Task {
            do {
                let metas = try await PlatformCatalogs.catalog(type: type, id: platform.id)
                if !metas.isEmpty || tabs[type]?.metas.isEmpty != false { tabs[type]?.metas = metas }
                LibTrace.discover.log("\(platform.name) \(type): \(metas.count) title(s)")
            } catch {
                tabs[type]?.error = (error as? URLError)?.code == .notConnectedToInternet ? "You're offline." : "The catalog didn't load."
                LibTrace.discover.log("\(platform.name) \(type): load failed, the grid keeps \(tabs[type]?.metas.count ?? 0) title(s)")
            }
            tabs[type]?.loading = false
        }
    }
}

struct PlatformDetailView: View {
    let platform: StreamingPlatform
    @Namespace private var zoomNS
    @StateObject private var page: PlatformPageModel
    @State private var type = "series"

    init(platform: StreamingPlatform) {
        self.platform = platform
        _page = StateObject(wrappedValue: PlatformPageModel(platform: platform))
    }

    var body: some View {
        // One scroll view per tab, each kept while the page is open: a tab
        // comes back where you left it. The safe area is read before the
        // pages go under the bar, so the header starts below it.
        GeometryReader { geo in
            ZStack {
                ForEach(["series", "movie"], id: \.self) { t in
                    if page.tabs[t]?.started == true {
                        tabPage(t, barBottom: geo.safeAreaInsets.top)
                            .opacity(type == t ? 1 : 0)
                            .allowsHitTesting(type == t)
                            .accessibilityHidden(type != t)
                    }
                }
            }
            .ignoresSafeArea(edges: .top)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { page.show(type) }
        .onChange(of: type) { _, t in page.show(t) }
    }

    /// `barBottom`: where the navigation bar ends (the top safe-area inset,
    /// status bar and bar). The service's colours run up under the bar; its
    /// badge and name start below it, so the back button never covers them
    /// (until 1.19.0 they sat 20 pt above the bottom of a fixed 170 pt band:
    /// on an iPhone 17 Pro the badge's top was at 96 pt, the back button's
    /// bottom at 106 pt — 30 Oct screenshot and lab run). Like the title
    /// page's header (TitleHeroView: safe area + its bar).
    private func tabPage(_ t: String, barBottom: CGFloat) -> some View {
        let tab = page.tabs[t] ?? PlatformPageModel.Tab()
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // The service's colours with its name in white, then a fade into the page.
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        PlatformBadge(platform: platform, size: 54)
                            .accessibilityIdentifier("platformBadge")
                        Text(platform.name).font(.largeTitle.weight(.heavy)).foregroundStyle(.white)
                            .lineLimit(2).minimumScaleFactor(0.7)
                            .accessibilityAddTraits(.isHeader)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, barBottom + 16)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [platform.color, platform.color2], startPoint: .top, endPoint: .bottom))
                    LinearGradient(colors: [platform.color2, Theme.background], startPoint: .top, endPoint: .bottom).frame(height: 36)
                }
                Picker("", selection: $type) {
                    Text("Shows").tag("series")
                    Text("Movies").tag("movie")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                if tab.loading && tab.metas.isEmpty { ProgressView().frame(maxWidth: .infinity).padding() }
                if let error = tab.error {
                    // Inline, over whatever the grid already has; never in its place.
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(error).font(.subheadline)
                        Spacer(minLength: 0)
                        Button("Retry") { page.load(t) }.buttonStyle(.bordered).tint(Theme.accent)
                    }
                    .padding(12)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 20)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 12)], spacing: 16) {
                    ForEach(tab.metas) { m in
                        NavigationLink { MetaDetailView(preview: m, sourceAddon: nil).zoomDestination(m.id, in: zoomNS, zoom: false) } label: {
                            PosterCard(meta: m, width: 108, zoom: ZoomSource(m.id, zoomNS))
                        }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                if !tab.loading && tab.metas.isEmpty && tab.error == nil {
                    Text("Nothing here right now.").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 20)
                }
            }
        }
    }
}

struct PlatformSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: [StreamingPlatform] = StreamingPlatform.enabled
    @AppStorage("discoverRegion") private var region = Locale.current.region?.identifier ?? "US"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(enabled) { p in
                        HStack { PlatformBadge(platform: p, size: 30); Text(p.name) }
                    }
                    .onMove { enabled.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { enabled.remove(atOffsets: $0) }
                } header: { Text("Shown on Discover") } footer: { Text("Drag to reorder, swipe to hide.") }
                let hidden = StreamingPlatform.all.filter { p in !enabled.contains(p) }
                if !hidden.isEmpty {
                    Section("Hidden") {
                        ForEach(hidden) { p in
                            Button { enabled.append(p) } label: {
                                HStack { PlatformBadge(platform: p, size: 30); Text(p.name).foregroundStyle(.primary); Spacer(); Image(systemName: "plus.circle.fill") }
                            }
                        }
                    }
                }
                Section {
                    TextField("Region (e.g. AU, US, GB)", text: $region)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                } header: { Text("Region") }
            }
            .environment(\.editMode, .constant(.active))
            .brandListBackground()
            .navigationTitle("Streaming Services")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { StreamingPlatform.enabled = enabled; dismiss() }
                }
            }
        }
    }
}
