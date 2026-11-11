import SwiftUI
import TipKit

/// Streaming-service catalogs (what's on Netflix, Prime Video, Max, Disney+…)
/// from the public "Streaming Catalogs" addon. Items carry IMDb ids,
/// so details come from IMDb and streams from your stream addons.
struct StreamingPlatform: Identifiable, Hashable {
    let id: String
    let name: String
    let short: String
    let color: Color
    let color2: Color
    /// The service's logo on TMDB's image server (1.22.6), the square one
    /// TMDB shows for where to watch; until it loads, or offline, the
    /// letters on the service's colours. Each checked by eye on 5 Nov.
    var logo: String? = nil

    static let all: [StreamingPlatform] = [
        .init(id: "nfx", name: "Netflix", short: "N", color: Color(red: 0.90, green: 0.04, blue: 0.08), color2: Color(red: 0.45, green: 0.0, blue: 0.02), logo: "pbpMk2JmcoNnQwx5JGpXngfoWtp"),
        .init(id: "amp", name: "Prime Video", short: "prime", color: Color(red: 0.0, green: 0.66, blue: 0.88), color2: Color(red: 0.0, green: 0.25, blue: 0.45), logo: "pvske1MyAoymrs5bguRfVqYiM9a"),
        .init(id: "hbm", name: "HBO Max", short: "max", color: Color(red: 0.0, green: 0.17, blue: 0.91), color2: Color(red: 0.35, green: 0.13, blue: 0.70), logo: "Ajqyt5aNxNGjmF9uOfxArGrdf3X"),
        .init(id: "dnp", name: "Disney+", short: "D+", color: Color(red: 0.07, green: 0.24, blue: 0.81), color2: Color(red: 0.02, green: 0.08, blue: 0.30), logo: "97yvRBw1GzX7fXprcF80er19ot"),
        .init(id: "atp", name: "Apple TV+", short: "tv+", color: Color(white: 0.55), color2: Color(white: 0.12), logo: "2E03IAZsX4ZaUqM7tXlctEPMGWS"),
        .init(id: "pmp", name: "Paramount+", short: "P+", color: Color(red: 0.0, green: 0.39, blue: 1.0), color2: Color(red: 0.0, green: 0.12, blue: 0.40), logo: "h5DcR0J2EESLitnhR8xLG1QymTE"),
        .init(id: "hlu", name: "Hulu", short: "hulu", color: Color(red: 0.11, green: 0.91, blue: 0.51), color2: Color(red: 0.02, green: 0.35, blue: 0.20), logo: "bxBlRPEPpMVDc4jMhSrTf2339DW"),
        .init(id: "pcp", name: "Peacock", short: "P", color: Color(red: 0.98, green: 0.73, blue: 0.0), color2: Color(red: 0.40, green: 0.10, blue: 0.55), logo: "2aGrp1xw3qhwCYvNGAJZPdjfeeX"),
        .init(id: "cru", name: "Crunchyroll", short: "CR", color: Color(red: 0.96, green: 0.46, blue: 0.13), color2: Color(red: 0.45, green: 0.15, blue: 0.0), logo: "fzN5Jok5Ig1eJ7gyNGoMhnLSCfh"),
    ]

    /// The logo's address, sized for a badge `points` wide.
    func logoURL(points: CGFloat) -> URL? {
        logo.flatMap { URL(string: TMDB.image + (points * 3 > 154 ? "w300" : "w154") + "/\($0).jpg") }
    }

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
            lock.withLock { cache[key] = (Date(), metas) }
            return metas
        } catch {
            LibTrace.discover.log("catalog \(key): failed (\((error as NSError).domain) \((error as NSError).code)) after \(Int(Date().timeIntervalSince(t0) * 1000)) ms; nothing kept")
            throw error
        }
    }
}

// MARK: - Discover

/// Browse filters for the main grid. Data comes from Cinemeta or TMDB when
/// set up, in the order chosen in Addons, else IMDb (built in): see
/// DiscoverSource (1.27.1).
@MainActor
final class BrowseModel: ObservableObject {
    enum Sort: String, CaseIterable, Identifiable {
        case trending, topRated, new
        var id: String { rawValue }
        var title: String { self == .trending ? "Trending" : self == .topRated ? "Top Rated" : "New" }
        func footnote(_ source: DiscoverSource) -> String? {
            switch source {
            case .cinemeta: return self == .topRated ? "Cinemeta Featured, by IMDb rating" : self == .trending ? "Cinemeta Popular" : nil
            case .tmdb: return self == .topRated ? "TMDB top rated" : self == .trending ? "TMDB trending this week" : nil
            case .imdb:
                switch self {
                case .trending: return "IMDb Most Popular (MOVIEmeter)"
                case .topRated: return "IMDb Top 250, as rated by IMDb users"
                case .new: return nil
                }
            }
        }
        var imdb: IMDbSource.Sort { self == .trending ? .trending : self == .topRated ? .topRated : .new }
    }
    static var genres: [String] { IMDbSource.genres }
    static let years: [String] = (0..<30).map { String(Calendar.current.component(.year, from: Date()) - $0) }

    // Only a real change reloads: picking the genre already shown emptied
    // the grid and fetched it again.
    @Published var sort: Sort = .trending { didSet { if sort != oldValue { reload() } } }
    @Published var type = "movie" { didSet { if type != oldValue { reload() } } }
    @Published var genre: String? { didSet { if genre != oldValue { reload() } } }
    @Published var year: String = BrowseModel.years[0] { didSet { if sort == .new, year != oldValue { reload() } } }

    /// What the grid is a list of: changes with each filter (the page scrolls back to the grid's top).
    var filterKey: String { "\(type)|\(sort.rawValue)|\(genre ?? "")|\(sort == .new ? year : "")" }
    @Published var metas: [MetaItem] = []
    @Published var loading = false
    @Published var failed = false
    /// Nothing more to load: the list's end line shows (IMDb, 1.23.0).
    @Published private(set) var exhausted = false
    private var generation = 0
    private var task: Task<Void, Never>?
    /// TMDB's next page (1.23.0): counted per page received, not worked out
    /// from the titles kept, which a repeat across pages made ask for the
    /// same page again and stop for good (review, 5 Nov).
    private var nextPage = 1
    /// IMDb's longer list has been asked for.
    private var askedMore = false
    /// Where the list on screen comes from (1.27.1); more of it comes from there too.
    @Published private(set) var source: DiscoverSource = .imdb
    /// Cinemeta's titles received so far: where its next page starts.
    private var cinemetaSkip = 0

    /// The grid's heading note: where the list comes from.
    var footnote: String? { sort.footnote(source) }

    func reload() {
        task?.cancel()
        generation += 1          // anything still in flight is stale now
        metas = []; exhausted = false; failed = false; nextPage = 1; askedMore = false; cinemetaSkip = 0
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
        // "New" has its genre menu too (1.28.11): it had only the year's,
        // and a genre chosen under another sort was dropped.
        var genre = self.genre
        // Kids profile (1.22.0): the lists start from IMDb's or TMDB's Family
        // genre, and every title is checked by KidsRules where it's shown.
        let kids = KidsProfile.shared.isOn
        if kids && genre == nil { genre = "Family" }
        guard initial else {
            switch source {
            case .cinemeta: _ = await loadCinemeta(gen: gen, genre: genre, kids: kids, last: true)
            case .tmdb: _ = await loadTMDB(gen: gen, genre: genre, kids: kids, last: true)
            case .imdb: await loadIMDb(gen: gen, genre: genre, kids: kids, initial: false)
            }
            return
        }
        // The sources in your order; one that fails with nothing to show
        // hands over to the next (1.27.1). IMDb is last and always there.
        let chain = DiscoverSource.chain
        dlog("discover", "\(sort.rawValue) \(type)\(genre.map { " · " + $0 } ?? ""): from \(chain.map(\.name).joined(separator: ", then "))")
        for (i, s) in chain.enumerated() {
            guard gen == generation else { return }
            source = s
            exhausted = false; failed = false
            let last = i == chain.count - 1
            let done: Bool
            switch s {
            case .cinemeta: done = await loadCinemeta(gen: gen, genre: genre, kids: kids, last: last)
            case .tmdb: done = await loadTMDB(gen: gen, genre: genre, kids: kids, last: last)
            case .imdb: await loadIMDb(gen: gen, genre: genre, kids: kids, initial: true); done = true
            }
            if done { return }
            dlog("discover", "\(s.name) didn't answer: trying \(chain.dropFirst(i + 1).first?.name ?? "nothing else")")
        }
    }

    /// Cinemeta's next page(s). False when it failed with nothing on screen.
    private func loadCinemeta(gen: Int, genre: String?, kids: Bool, last: Bool) async -> Bool {
        guard let addon = AddonStore.shared.cinemetaAddon else { return false }
        // A page of titles already shown: the next, up to three in a row.
        for _ in 0..<3 {
            var page: [MetaItem]
            do {
                page = try await CinemetaBrowse.page(addon, sort: sort, type: type, genre: genre, year: year, skip: cinemetaSkip)
            } catch {
                dlog("discover", "Cinemeta \(sort.rawValue) \(type) failed: \(error.localizedDescription)")
                guard gen == generation else { return true }
                if metas.isEmpty && !Task.isCancelled {
                    if last { failed = true }
                    return false
                }
                return true        // asked again on reaching the end
            }
            if kids { page = Self.tagged(page, genre: genre) }
            dlog("discover", "Cinemeta \(sort.rawValue) \(type)\(genre.map { " · " + $0 } ?? ""): \(page.count) title(s) from \(cinemetaSkip)\(gen == generation ? "" : " (stale)")")
            guard gen == generation else { return true }
            if page.isEmpty {
                exhausted = true
                // Nothing at all for this sort or genre: the next source may have it.
                if metas.isEmpty && !last { return false }
                return true
            }
            cinemetaSkip += page.count
            let known = Set(metas.map(\.id))
            let new = page.filter { !known.contains($0.id) }
            metas += new
            if !new.isEmpty { return true }
        }
        return true
    }

    /// TMDB's next page(s). False when it failed with nothing on screen.
    private func loadTMDB(gen: Int, genre: String?, kids: Bool, last: Bool) async -> Bool {
        // A page that repeats only titles already shown: the next one,
        // up to three in a row, so the grid never stalls on a repeat.
        for _ in 0..<3 {
            var page = await TMDB.browse(sort: sort, type: type, genre: genre, year: year, page: nextPage)
            if kids { page = Self.tagged(page, genre: genre) }
            guard gen == generation else { return true }
            if page.isEmpty {
                // A failed page can be asked for again (scrolling back to the end).
                if !TMDB.lastError { exhausted = true; return true }
                if metas.isEmpty && !Task.isCancelled {
                    if last { failed = true }
                    return false
                }
                return true
            }
            nextPage += 1
            let known = Set(metas.map(\.id))
            let new = page.filter { !known.contains($0.id) }
            metas += new
            if !new.isEmpty { return true }
        }
        return true
    }

    private func loadIMDb(gen: Int, genre: String?, kids: Bool, initial: Bool) async {
        if !initial && !metas.isEmpty {
            // More (1.23.0): one IMDb page holds up to 250 titles, so the
            // grid goes on from its first 100 to IMDb's longer list once.
            guard !askedMore else { exhausted = true; return }
            askedMore = true
            var more = await IMDbSource.browse(sort: sort.imdb, type: type, genre: genre, year: year, more: true)
            if kids { more = Self.tagged(more, genre: genre) }
            guard gen == generation else { return }
            let known = Set(metas.map(\.id))
            let new = more.filter { !known.contains($0.id) }
            metas += new
            dlog("discover", "more: \(new.count) title(s) after the first \(known.count)")
            exhausted = true
            return
        }
        // Last list first (any age), fresh one when it arrives.
        var stale = await IMDbSource.browse(sort: sort.imdb, type: type, genre: genre, year: year, staleOnly: true)
        if kids { stale = Self.tagged(stale, genre: genre) }
        if gen == generation, !stale.isEmpty, metas.isEmpty { metas = stale }
        var list = await IMDbSource.browse(sort: sort.imdb, type: type, genre: genre, year: year)
        if kids { list = Self.tagged(list, genre: genre) }
        guard gen == generation else { return }
        if !list.isEmpty || metas.isEmpty { metas = list }
        // A full first page (100) may have more behind it; the Top 250
        // chart is whole.
        exhausted = metas.count < 100 || (genre == nil && sort == .topRated)
        failed = metas.isEmpty
    }

    /// The grid's last line once it can't go on (IMDb lists, 1.23.0).
    var endNote: String? {
        guard exhausted, source == .imdb, !metas.isEmpty else { return nil }
        if genre == nil && sort == .topRated && sort != .new { return "That's IMDb's whole Top 250." }
        return "That's as far as IMDb's list goes: \(metas.count) titles."
    }

    /// A list asked for by genre whose titles don't say theirs (TMDB's never
    /// do): they're in it, so the kids profile can go by it.
    static func tagged(_ list: [MetaItem], genre: String?) -> [MetaItem] {
        guard let genre else { return list }
        return list.map { m in
            guard m.genres?.isEmpty != false else { return m }
            var m = m
            m.genres = [genre]
            return m
        }
    }

    /// The titles to show: in the kids profile, those KidsRules allows.
    func shown(_ limits: KidsRules.Limits?) -> [MetaItem] {
        guard let limits else { return metas }
        return metas.filter { KidsRules.allows($0, limits: limits) }
    }
}

struct DiscoverView: View {
    @ObservedObject private var store = AddonStore.shared
    @ObservedObject private var kids = KidsProfile.shared
    @Namespace private var zoomNS
    @StateObject private var browse = BrowseModel()
    @StateObject private var forYou = ForYouModel()
    @State private var showPlatformSettings = false
    /// Pulls to refresh so far (the Airing now row reloads on each).
    @State private var refreshCount = 0
    /// What decides Discover's source (1.27.1): a change reloads the grid.
    @AppStorage(DiscoverSource.orderKey) private var sourceOrder = ""
    @AppStorage("tmdbApiKey") private var tmdbKey = ""
    private var sourceSetup: String { "\(sourceOrder)|\(!tmdbKey.isEmpty)|\(store.cinemetaAddon != nil)" }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let margin: CGFloat = geo.size.width > 700 ? 28 : 20
                let cols = max(3, Int((geo.size.width - margin * 2 + 12) / 122))
                let shown = browse.shown(kids.activeLimits)
                ScrollViewReader { scroller in
                ScrollView {
                    // A plain stack around the lazy grid (1.26.0): a lazy grid in
                    // a lazy stack drew nothing after a new genre emptied and
                    // refilled it while scrolled down, until the page was
                    // scrolled up by hand (8 Nov report).
                    VStack(alignment: .leading, spacing: 24) {
                        header(margin)
                        AiringNowRow(margin: margin, zoomNS: zoomNS, refresh: refreshCount)
                        forYouRow(margin)
                        platformStrip(margin)
                        // Installed addons' catalogs (1.27.0), not in the kids
                        // profile: what they carry isn't rated.
                        if !kids.isOn {
                            ForEach(store.discoverCatalogs) { ref in
                                CatalogRow(addon: ref.addon, catalog: ref.catalog, margin: margin)
                            }
                        }
                        gridSection(margin: margin, cols: cols, shown: shown, minHeight: geo.size.height)
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 90)
                }
                .scrollIndicators(.hidden)
                // Room under the last row for the downloads pill (1.24.1).
                .downloadPillRoom()
                // Another kind, sort, genre or year (1.26.2: wherever the page
                // is): the grid's heading goes to the top, where the new list
                // starts. Until then only when the heading was above the
                // screen, and the emptied grid left too little page under it
                // to get there: the new list loaded below where you were.
                .onChange(of: browse.filterKey) {
                    withAnimation(.snappy) { scroller.scrollTo(Self.gridTop, anchor: .top) }
                }
                }
            }
            .background(HomeBackdrop().ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) { filterBar }
            .onAppear { DownloadPillLift.shared.discoverShown = true }
            .onDisappear { DownloadPillLift.shared.discoverShown = false }
            .task {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "discoverLastUsed")
                // The addons tip waits for a second visit (1.27.0).
                FolioTips.note(AddonsTip.discoverOpened)
                if browse.metas.isEmpty { browse.reload() }
                forYou.load()
            }
            .refreshable { browse.reload(); forYou.load(force: true); refreshCount += 1 }
            // The kids profile turned on or off: the lists start from another
            // genre, and For you shows only titles whose rating is known (1.22.1).
            .onChange(of: kids.isOn) { _, on in
                browse.reload()
                if on { forYou.lookUpRatings() }
            }
            .onChange(of: sourceSetup) { _, _ in
                dlog("discover", "source now \(DiscoverSource.current.name): reloading")
                browse.reload()
            }
            .sheet(isPresented: $showPlatformSettings) { PlatformSettingsView() }
        }
    }

    /// The grid with its heading. At least `minHeight` (the screen) tall, with
    /// placeholder tiles while a new list loads, so the heading can always be
    /// scrolled to the top.
    private func gridSection(margin: CGFloat, cols: Int, shown: [MetaItem], minHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(gridTitle).font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if browse.loading && browse.metas.isEmpty { FolioSpinner(size: .small) }
                }
                if let f = browse.footnote { Text(f).font(.caption).foregroundStyle(.secondary) }
                if let limits = kids.activeLimits { KidsFilterNote(limits: limits).padding(.top, 2) }
            }
            .padding(.horizontal, margin)
            .id(Self.gridTop)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: cols), spacing: 18) {
                if shown.isEmpty && browse.loading {
                    ForEach(0..<(cols * 3), id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card)
                            .aspectRatio(2 / 3, contentMode: .fit)
                    }
                    .accessibilityHidden(true)
                }
                ForEach(shown) { m in
                    NavigationLink { MetaDetailView(preview: m, sourceAddon: nil).zoomDestination(m.id, in: zoomNS) } label: {
                        PosterCard(meta: m, width: nil, zoom: ZoomSource(m.id, zoomNS))
                    }
                        .buttonStyle(.plain)
                        .contextMenu { WatchlistMenuButton(meta: m) }
                        .onAppear { if m.id == shown.last?.id { Task { await browse.loadMore() } } }
                }
            }
            .padding(.horizontal, margin)
            if browse.loading && !browse.metas.isEmpty { FolioSpinner().frame(maxWidth: .infinity).padding(.vertical, 8) }
            if !browse.loading, let note = browse.endNote {
                Text(note).font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .accessibilityIdentifier("discoverEnd")
            }
            // The system's empty and error layout, as elsewhere (1.27.0).
            if !browse.loading && shown.isEmpty {
                Group {
                    if browse.failed {
                        ContentUnavailableView {
                            Label("IMDb Didn't Answer", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text("Check the connection and try again.")
                        } actions: {
                            Button("Try Again") { browse.reload() }.buttonStyle(.borderedProminent).tint(Theme.action)
                        }
                    } else if kids.isOn && !browse.metas.isEmpty {
                        ContentUnavailableView("Nothing for the Kids Profile", systemImage: "figure.and.child.holdinghands",
                                               description: Text("None of these titles is rated for its limits."))
                    } else {
                        ContentUnavailableView("Nothing Here", systemImage: "film.stack",
                                               description: Text("Try another genre or sort."))
                    }
                }
                .padding(.horizontal, margin)
            }
        }
        .frame(minHeight: minHeight, alignment: .top)
    }

    private static let gridTop = "discoverGridTop"

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
            // Grows with the text size (1.27.0: a fixed 28 pt).
            Text("Discover").font(.system(.title, design: .rounded, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            // The search is the tab bar's search button now (1.22.4).
            // Addons and streaming services are settings: locked in the kids profile (1.22.0).
            // 1.27.0: Addons a button of their own, its sheet growing out of
            // it (was an item in a "…" menu, with Streaming services, which
            // is now the only item, so a button too).
            if !kids.isOn {
                AddonsSheetButton()
            }
            WatchlistSheetButton()
            if !kids.isOn {
                Button { showPlatformSettings = true } label: {
                    Image(systemName: "rectangle.grid.2x2").font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44).glassCircle()
                }
                .buttonStyle(PressStyle())
                .foregroundStyle(.primary)
                .accessibilityLabel("Streaming Services")
            }
        }
        .padding(.horizontal, margin)
        .padding(.top, 8)
    }

    /// Titles like the ones you've watched (ForYou), only when the history
    /// has one to start from. Placeholders keep its place while the first
    /// row loads, so the page below doesn't jump when it arrives. Its tiles
    /// zoom by their own ids: the same title can be in the grid too.
    @ViewBuilder
    private func forYouRow(_ margin: CGFloat) -> some View {
        let metas = forYou.shown(kids.activeLimits)
        if forYou.hasSeeds && (!metas.isEmpty || (forYou.loading && forYou.metas.isEmpty)) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("For you").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
                    Text(TMDB.enabled ? "Like what you've watched, from IMDb and TMDB" : "Like what you've watched, from IMDb")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, margin)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        if metas.isEmpty {
                            ForEach(0..<6, id: \.self) { _ in
                                VStack(alignment: .leading, spacing: 6) {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card).frame(width: 118, height: 177)
                                    Capsule().fill(Theme.card).frame(width: 84, height: 10)
                                }
                            }
                            .accessibilityHidden(true)
                        }
                        ForEach(metas) { m in
                            NavigationLink { MetaDetailView(preview: m, sourceAddon: nil).zoomDestination("fy|" + m.id, in: zoomNS) } label: {
                                PosterCard(meta: m, width: 118, zoom: ZoomSource("fy|" + m.id, zoomNS))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { WatchlistMenuButton(meta: m) }
                        }
                    }
                    .padding(.horizontal, margin)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("forYouRow")
        }
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
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(p.name)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, margin)
        }
    }

    /// Floating Liquid Glass filter bar. 1.27.0: fits any iPhone's width. The
    /// chips keep their whole titles ("Trending" was cut to "Trendi…" on a
    /// 17 Pro) and Movies/Series gives way first; where even that isn't
    /// enough (a 13 mini with a long genre), sort and genre become icons.
    private var filterBar: some View {
        ViewThatFits(in: .horizontal) {
            filterRow(compact: false)
            filterRow(compact: true)
        }
        .padding(6)
        .glass(cornerRadius: 28, interactive: true)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .tint(Theme.accent)
        // The downloads pill sits above the bar while Discover shows (it covered it).
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { DownloadPillLift.shared.discoverBar = $0 }
    }

    private func filterRow(compact: Bool) -> some View {
        HStack(spacing: 6) {
            SegmentPicker(options: [("movie", "Movies"), ("series", "Series")], selection: $browse.type)
                // Its smallest width is what the bar measures when it picks a
                // layout; it takes more (up to 160) when there's room.
                .frame(minWidth: compact ? 120 : 140, idealWidth: compact ? 120 : 140, maxWidth: 160)
            Menu {
                Picker("Sort", selection: $browse.sort) { ForEach(BrowseModel.Sort.allCases) { Text($0.title).tag($0) } }
            } label: {
                FilterChip(title: browse.sort.title, active: true, icon: compact ? "arrow.up.arrow.down" : nil)
            }
            .accessibilityLabel("Sort")
            .accessibilityValue(browse.sort.title)
            if browse.sort == .new {
                Menu {
                    Picker("Year", selection: $browse.year) { ForEach(BrowseModel.years, id: \.self) { Text($0).tag($0) } }
                } label: { FilterChip(title: browse.year, active: true, icon: compact ? "calendar" : nil) }
                .accessibilityLabel("Year")
                .accessibilityValue(browse.year)
            }
            Menu {
                Button { browse.genre = nil } label: { browse.genre == nil ? Label("All genres", systemImage: "checkmark") : Label("All genres", systemImage: "circle") }
                Divider()
                ForEach(BrowseModel.genres, id: \.self) { g in
                    Button { browse.genre = g } label: { if browse.genre == g { Label(g, systemImage: "checkmark") } else { Text(g) } }
                }
            } label: {
                FilterChip(title: browse.genre ?? "Genre", active: browse.genre != nil, icon: compact ? "theatermasks" : nil)
            }
            .accessibilityLabel("Genre")
            .accessibilityValue(browse.genre ?? "All genres")
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct FilterChip: View {
    let title: String
    let active: Bool
    /// Shown instead of the title where the bar is short of room (1.27.0).
    var icon: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(.subheadline.weight(.semibold))
            } else {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            Image(systemName: "chevron.down").font(.caption2.weight(.bold))
        }
        // Whole, never cut: the bar picks a shorter layout instead (1.27.0).
        .fixedSize()
        .foregroundStyle(active ? Color.primary : Color.secondary)
        .padding(.horizontal, 12).frame(minHeight: 44)
        .background(active ? Theme.fill : Color.clear, in: Capsule())
        .contentShape(Capsule())          // a clear background isn't tappable: only the text was
    }
}

/// A streaming service's badge: its logo (1.22.6), shaped like an app's
/// icon so the square logos keep their edges (a circle cut into "prime
/// video" and "hulu"). Until 1.22.6 its letters on its colours, which are
/// still what shows until the logo loads, or offline.
struct PlatformBadge: View {
    let platform: StreamingPlatform
    var size: CGFloat = 44
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
        CachedImage(url: platform.logoURL(points: size), maxPixel: size * 3) {
            $0.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                shape.fill(LinearGradient(colors: [platform.color, platform.color2], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(platform.short)
                    .font(.system(size: size * (platform.short.count > 2 ? 0.24 : 0.36), weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .padding(4)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.15)))
        .accessibilityLabel(platform.name)
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
    @ObservedObject private var kids = KidsProfile.shared
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
        // The kids profile: only what KidsRules allows (these catalogs rarely say, so often little).
        let metas = kids.activeLimits.map { l in tab.metas.filter { KidsRules.allows($0, limits: l) } } ?? tab.metas
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
                // The same control, words and order as Discover's (1.27.0: "Shows |
                // Movies" in the system's grey control).
                SegmentPicker(options: [("movie", "Movies"), ("series", "Series")], selection: $type)
                    .frame(height: 36)
                    .accessibilityLabel("Movies or series")
                    .padding(.horizontal, 20)
                if let limits = kids.activeLimits { KidsFilterNote(limits: limits).padding(.horizontal, 20) }
                if tab.loading && tab.metas.isEmpty { FolioSpinner().frame(maxWidth: .infinity).padding() }
                if let error = tab.error, metas.isEmpty {
                    // Nothing to show: the system's error layout (1.27.0).
                    ContentUnavailableView {
                        Label("Couldn't Load \(platform.name)", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { page.load(t) }.buttonStyle(.borderedProminent).tint(Theme.action)
                    }
                } else if let error = tab.error {
                    // Inline, over whatever the grid already has; never in its place.
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.action)
                        Text(error).font(.subheadline)
                        Spacer(minLength: 0)
                        Button("Retry") { page.load(t) }.buttonStyle(.bordered).tint(Theme.accent)
                    }
                    .padding(12)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 20)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 12)], spacing: 16) {
                    ForEach(metas) { m in
                        NavigationLink { MetaDetailView(preview: m, sourceAddon: nil).zoomDestination(m.id, in: zoomNS, zoom: false) } label: {
                            PosterCard(meta: m, width: 108, zoom: ZoomSource(m.id, zoomNS))
                        }
                            .buttonStyle(.plain)
                            .contextMenu { WatchlistMenuButton(meta: m) }
                    }
                }
                .padding(.horizontal, 20)
                if !tab.loading && metas.isEmpty && tab.error == nil {
                    ContentUnavailableView(tab.metas.isEmpty ? "Nothing Here Right Now" : "Nothing for the Kids Profile",
                                           systemImage: tab.metas.isEmpty ? "film.stack" : "figure.and.child.holdinghands")
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
                            .accessibilityLabel("Show \(p.name)")
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
                // 1.26.1: Cancel, and no swipe away once something changed
                // (a swipe dropped the changes without a word).
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { StreamingPlatform.enabled = enabled; dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(enabled != StreamingPlatform.enabled)
    }
}
