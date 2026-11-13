import SwiftUI
import QuartzCore

/// Discover's search as you type, and your recent searches.
///
/// - Titles come from IMDb's suggestion API (`IMDbSource.suggest`, the
///   app's metadata source; made for typeahead and cached a day on disk).
///   Addon catalogs that can search are asked only when you press Search:
///   they are other people's servers, and asking all of them at every pause
///   in your typing would be heavy.
/// - A search starts 300 ms after the last change (`debounce`). The study of
///   37,000 people typing on phones (Palin et al., MobileHCI 2019) measured
///   36.2 words a minute on average, about 330 ms a keystroke: at 300 ms most
///   searches start when you pause, not on every letter, and the answer
///   still comes well inside a second.
/// - From 2 characters (`minLength`): IMDb's endpoint is split by first
///   letter, and one letter only brings back generic popular titles. Search
///   on the keyboard runs any non-blank query.
/// - Each new query cancels the request before it (Task cancellation reaches
///   URLSession's request), and every answer carries the generation it was
///   asked for: an older answer that still arrives is dropped, so it can
///   never replace a newer one.
@MainActor
final class DiscoverSearch: ObservableObject {
    enum Phase: Equatable {
        case idle, loading, done
        case failed(offline: Bool)
    }

    nonisolated static let debounce: Duration = .milliseconds(300)
    nonisolated static let minLength = 2

    @Published private(set) var phase: Phase = .idle
    /// IMDb titles, and the query they answer.
    @Published private(set) var titles: [MetaItem] = []
    @Published private(set) var titlesQuery = ""
    /// Addon catalogs' answers to the last query you pressed Search for.
    @Published private(set) var addonResults: [AddonSearchView.SearchResult] = []
    @Published private(set) var addonsSearching = false
    @Published private(set) var history: [SearchHistoryEntry] = []

    private let store: SearchHistoryStore
    private var historyLoaded = false
    private var liveTask: Task<Void, Never>?
    private var addonTask: Task<Void, Never>?
    private var generation = 0
    private var addonQuery = ""
    /// The text the live search last started for (tidied).
    private var current = ""

    init(store: SearchHistoryStore = .shared) { self.store = store }

    /// Recent searches, read the first time the search screen asks.
    func loadHistory() async {
        guard !historyLoaded else { return }
        historyLoaded = true
        history = await store.all()
    }

    /// The field changed (each keystroke).
    func textChanged(_ text: String) {
        let q = SearchHistoryStore.tidy(text)
        if q != addonQuery { addonTask?.cancel(); addonResults = []; addonsSearching = false; addonQuery = "" }
        guard q != current else { return }          // only spaces changed
        start(q, wait: true)
    }

    /// Search on the keyboard: now, without the pause, plus addon catalogs; kept in history.
    func submit(_ text: String) {
        let q = SearchHistoryStore.tidy(text)
        guard !q.isEmpty else { return }
        dlog("search", "\(q.count) character(s) submitted")
        commit(q)
        if q != current || phase != .done { start(q, wait: false, minLength: 1) }
        searchAddons(q)
    }

    /// A result was opened: the query that found it goes into history.
    func opened(from query: String) { commit(SearchHistoryStore.tidy(query)) }

    func retry() { start(current, wait: false, minLength: 1) }

    func delete(_ entry: SearchHistoryEntry) {
        history.removeAll { $0.id == entry.id }
        Task { history = await store.remove(entry.query) }
    }

    func clearHistory() {
        history = []
        Task { history = await store.clear() }
    }

    // MARK: Running

    private func start(_ q: String, wait: Bool, minLength: Int = DiscoverSearch.minLength) {
        liveTask?.cancel()
        generation += 1
        current = q
        guard q.count >= minLength else {
            phase = .idle
            titles = []
            titlesQuery = ""
            return
        }
        let gen = generation
        let kids = KidsProfile.shared.activeLimits
        phase = .loading                 // the last results stay up meanwhile: nothing jumps
        liveTask = Task { [weak self] in
            if wait {
                do { try await Task.sleep(for: Self.debounce) } catch { return }   // the next keystroke came first
            }
            let t0 = CACurrentMediaTime()
            do {
                var items = try await Self.lookUp(q)
                if let kids { items = await Self.kidsFiltered(items, limits: kids) }
                guard let self, gen == self.generation else { return }             // a newer query took over
                self.titles = items
                self.titlesQuery = q
                self.phase = .done
                // Counts only: what you search for stays out of the log (review, 5 Nov).
                dlog("search", String(format: "%d title(s) in %.0f ms", items.count, (CACurrentMediaTime() - t0) * 1000))
            } catch {
                guard let self, gen == self.generation, !IMDbSource.isCancellation(error) else { return }
                let offline = Self.isOffline(error)
                self.phase = .failed(offline: offline)
                dlog("search/error", "\(error.localizedDescription)\(offline ? " (offline)" : "")")
            }
        }
    }

    /// Lab (`-labSearchOffline`): every search fails as it does without a connection.
    private static func lookUp(_ q: String) async throws -> [MetaItem] {
        if CommandLine.arguments.contains("-labSearchOffline") { throw URLError(.notConnectedToInternet) }
        return try await IMDbSource.suggest(q)
    }

    /// Kids profile (1.22.0): suggestions carry no rating or genre, so the
    /// first ones are looked up (IMDb's title page, kept 7 days), three at a
    /// time, and only what KidsRules allows is kept. Cancelled with the search.
    nonisolated static let kidsChecked = 10
    nonisolated static func kidsFiltered(_ items: [MetaItem], limits: KidsRules.Limits) async -> [MetaItem] {
        let checked = await ForYou.each(Array(items.prefix(kidsChecked)), limit: 3) { m -> MetaItem in
            guard m.id.hasPrefix("tt"), m.contentRating == nil, let d = await IMDbSource.details(id: m.id, type: m.type) else { return m }
            var out = m
            out.contentRating = d.contentRating
            out.genres = d.genres ?? m.genres
            return out
        }
        let kept = checked.filter { KidsRules.allows($0, limits: limits) }
        dlog("search", "kids profile: \(kept.count) of \(checked.count) title(s) kept")
        return kept
    }

    static func isOffline(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff, .cannotFindHost, .cannotConnectToHost].contains(code)
    }

    private func searchAddons(_ q: String) {
        addonTask?.cancel()
        addonResults = []
        addonQuery = q
        let targets = AddonStore.shared.active.flatMap { a in a.manifest.catalogs.filter(\.supportsSearch).map { (a, $0) } }
        guard !targets.isEmpty else { addonsSearching = false; return }
        addonsSearching = true
        // The kids profile: an addon's titles go by what they carry (KidsRules; unknown is hidden).
        let kids = KidsProfile.shared.activeLimits
        addonTask = Task { [weak self] in
            await withTaskGroup(of: AddonSearchView.SearchResult?.self) { group in
                for (a, c) in targets {
                    group.addTask {
                        var metas = (try? await AddonAPI.catalog(a, c, extra: ["search": q])) ?? []
                        if let kids { metas = metas.filter { KidsRules.allows($0, limits: kids) } }
                        guard !metas.isEmpty else { return nil }
                        return AddonSearchView.SearchResult(id: a.id + c.type + c.id, title: "\(c.name ?? c.id) · \(c.type.capitalized) — \(a.manifest.name)",
                                                            addon: a, metas: metas)
                    }
                }
                for await r in group {
                    guard let self, !Task.isCancelled, self.addonQuery == q else { return }
                    if let r { self.addonResults.append(r) }
                }
            }
            guard let self, !Task.isCancelled, self.addonQuery == q else { return }
            self.addonsSearching = false
        }
    }

    private func commit(_ q: String) {
        guard !q.isEmpty else { return }
        Task { history = await store.add(q) }
    }
}

/// The one search page (1.28.11), behind the tab bar's search button on
/// every tab. One list, one kind of row: what's yours first (the library,
/// your servers' releases, Plex and Jellyfin), then movies and shows from
/// IMDb as you type, and your addons' titles after Search. Until then each
/// source was a section of its own with its own rows, a file on a server
/// was a row each (a season: 24), and each addon catalog a carousel.
struct AddonSearchView: View {
    /// The tab bar's search field owns the text.
    @Binding var query: String

    struct SearchResult: Identifiable { let id: String; let title: String; let addon: InstalledAddon?; let metas: [MetaItem] }
    /// A title opened from the search (and the addon that found it, if any).
    private struct Opened: Hashable { let meta: MetaItem; let addon: InstalledAddon? }

    @StateObject private var search = DiscoverSearch()
    @StateObject private var catalogs = CatalogSearch()
    @ObservedObject private var kids = KidsProfile.shared
    @ObservedObject private var local = LocalMediaStore.shared
    @ObservedObject private var index = LibraryIndexStore.shared
    @ObservedObject private var webdav = ServerStore.shared
    @AppStorage(SettingsKey.cleanTitles) private var cleanTitles = true
    @State private var opened: Opened?
    /// The library's titles, grouped once (not at every keystroke).
    @State private var groups: [LibraryGroup] = []
    @State private var route: LibraryRoute?
    @State private var openedEntry: LibrarySearchResults.OpenedEntry?
    /// The chip chosen; All again when the field is emptied.
    @State private var scope = SearchScope.all
    /// The library's and the servers' matches for `filteredWords`, as rows.
    @State private var mine: [SearchItem] = []
    @State private var filteredWords: [String] = []
    /// Everything found, in the list's order: put together when the query
    /// or an answer changes, not at each redraw.
    @State private var results = SearchResults()
    /// Go up when a server's index, or an answer (IMDb, addons, Plex and
    /// Jellyfin), changes: the lists above are made again then.
    @State private var indexTick = 0
    @State private var answersTick = 0

    private var typed: String { SearchHistoryStore.tidy(query) }
    private static let chipsID = "searchChips"

    var body: some View {
        page
            .onChange(of: query) { _, text in
                search.textChanged(text)
                catalogs.textChanged(kids.isOn ? "" : text)
                if SearchHistoryStore.tidy(text).isEmpty { scope = .all }
                refilter()
            }
            .onSubmit(of: .search) { search.submit(query) }
            .onReceive(NotificationCenter.default.publisher(for: .searchTabSubmitted)) { note in
                search.submit((note.object as? String) ?? query)
            }
            .task { await search.loadHistory() }
            // Each server's index brought up to date when it's due, and text
            // kept from the last search asked again.
            .onAppear {
                HitchProbe.mark("search", "page appeared")
                if !kids.isOn { for server in webdav.servers { index.refreshIfNeeded(server) } }
                search.textChanged(query)
                catalogs.textChanged(kids.isOn ? "" : query)
                groups = LibraryOrganizer.groups(local.files)
                refilter(force: true)
                HitchProbe.mark("search", "page set up")
            }
            .onChange(of: local.files) { _, files in
                groups = LibraryOrganizer.groups(files)
                refilter(force: true)
            }
            .onChange(of: webdav.servers) { refilter(force: true) }
            .onChange(of: kids.isOn) { refilter(force: true) }
            // A counter, not the index itself: comparing two indexes at
            // every redraw would cost more than the search does.
            .onReceive(index.$states) { _ in indexTick &+= 1 }
            .onChange(of: indexTick) { refilter(force: true) }
            .onReceive(search.$titles) { _ in answersTick &+= 1 }
            .onReceive(search.$addonResults) { _ in answersTick &+= 1 }
            .onReceive(catalogs.$results) { _ in answersTick &+= 1 }
            .onChange(of: answersTick) { compose() }
            .navigationDestination(item: $opened) { o in
                MetaDetailView(preview: o.meta, sourceAddon: o.addon).zoomDestination("search|" + o.meta.id, in: zoomNS, zoom: false)
            }
            .navigationDestination(item: $route) { r in LibraryRoute.destination(r) }
            .navigationDestination(item: $openedEntry) { o in
                if let source = CatalogSearch.source(for: o.server) {
                    CatalogBrowserView(source: source, parent: o.entry, title: CatalogTitles.rowTitle(o.entry))
                }
            }
    }
    @Namespace private var zoomNS

    private var page: some View {
        ScrollViewReader { proxy in
            List {
                if typed.isEmpty {
                    // Recent not in the kids profile (1.28.6): the grown-ups' searches showed, and ran.
                    SearchEmptyState(recent: kids.isOn ? [] : search.history,
                                     run: { entry in
                                         query = entry.query
                                         search.submit(entry.query)
                                     },
                                     delete: { search.delete($0) },
                                     clear: { search.clearHistory() })
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    resultRows { target in
                        withAnimation(.easeOut(duration: 0.2)) {
                            scope = target
                            proxy.scrollTo(Self.chipsID, anchor: .top)
                        }
                    }
                }
            }
            .listStyle(.plain)
            // A readable column on a wide iPad window (1.30.0).
            .readableListWidth()
            .scrollContentBackground(.hidden)
            // Room under the last row for the downloads pill (1.24.1).
            .downloadPillRoom()
            .background(Theme.background.ignoresSafeArea())
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: Finding

    /// What's yours on this device and in the servers' indexes: found and
    /// grouped by release when the typed words change, or (`force`) what
    /// they're looked for in does. Before the one list this ran in the
    /// page's body, at every redraw.
    private func refilter(force: Bool = false) {
        let words = LibrarySearchText.words(query)
        guard force || words != filteredWords else { return }
        filteredWords = words
        let library = LibrarySearchResults.libraryMatches(words, in: groups, limits: kids.activeLimits)
        // Not in the kids profile: the servers are locked there.
        let files = kids.isOn ? [] : LibrarySearchResults.serverMatches(words, servers: webdav.servers, index: index)
        var found: [SearchItem] = library.map { SearchItem(library: $0) }
        // A release's files are one row ("MobLand · 10 files"), not a row each.
        let clean = cleanTitles
        found += ServerFile.releases(files).map { SearchItem(release: $0, clean: clean) }
        mine = found
        compose(mine: found)
    }

    /// The whole list: what's yours, then Plex and Jellyfin's entries,
    /// then IMDb's titles and the addons'.
    private func compose(mine found: [SearchItem]? = nil) {
        var owned = found ?? mine
        if !LibrarySearchText.words(query).isEmpty {
            for r in catalogs.results { owned += r.entries.map { SearchItem(entry: $0, server: r.server) } }
        }
        results = SearchResults(owned: owned, imdb: search.titles, addons: search.addonResults)
    }

    // MARK: Results

    @ViewBuilder
    private func resultRows(show: @escaping (SearchScope) -> Void) -> some View {
        // A chip whose results went away (a new query) falls back to All.
        let active = results.scopes.contains(scope) ? scope : SearchScope.all
        SearchScopeChips(scopes: results.scopes, selection: active, select: show)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .id(Self.chipsID)
        if let status { statusLine(status.text, working: status.working) }
        switch active {
        case .all:
            if let top = results.top { topCard(top) }
            ForEach(results.ownedShort) { row($0) }
            if results.hiddenOwned > 0 { showAll("Show all \(results.owned.count) in Yours", .yours, show) }
            catalogErrors
            titleProblem
            ForEach(results.titlesShort) { row($0) }
            if results.hiddenMovies > 0 { showAll("Show all \(results.movies.count) movies", .movies, show) }
            if results.hiddenShows > 0 { showAll("Show all \(results.shows.count) shows", .shows, show) }
        case .yours:
            ForEach(results.owned) { row($0) }
            catalogErrors
        case .movies:
            titleProblem
            ForEach(results.movies) { row($0) }
        case .shows:
            titleProblem
            ForEach(results.shows) { row($0) }
        }
    }

    /// The one quiet line under the chips: what the search is still doing
    /// (the most telling of it), or what it's waiting for. Until the one
    /// list each of these was a spinner row of its own.
    private var status: (text: String, working: Bool)? {
        if typed.count < DiscoverSearch.minLength, search.phase == .idle { return (text: "Keep typing to search titles.", working: false) }
        if search.phase == .loading { return (text: "Searching movies and shows…", working: true) }
        if catalogs.searching { return (text: "Searching Plex and Jellyfin…", working: true) }
        if search.addonsSearching { return (text: "Searching your addons…", working: true) }
        if !kids.isOn, let server = webdav.servers.first(where: { index.state($0.id).refreshing }) {
            let st = index.state(server.id)
            return (text: "Indexing \(server.name)… \(st.done) of \(st.total) folders", working: true)
        }
        if let limits = kids.activeLimits { return (text: "Movies and shows rated \(KidsRules.summary(limits)).", working: false) }
        return nil
    }

    private func statusLine(_ text: String, working: Bool) -> some View {
        HStack(spacing: 8) {
            if working { FolioSpinner(size: .small) }
            Text(text).font(.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("searchStatus")
    }

    /// Every result's row, whatever found it.
    private func row(_ item: SearchItem) -> some View {
        // The last titles stay up, dimmed, while the next are asked for: nothing jumps.
        let dim = item.isTitle && search.phase == .loading
        let folder: (() -> Void)? = item.isRelease ? { openFolder(item) } : nil
        return Button { open(item) } label: {
            SearchResultRow(item: item, artwork: artwork(item))
        }
        .buttonStyle(.plain)
        .modifier(OpenFolderActions(action: folder))
        .listRowBackground(Color.clear)
        .opacity(dim ? 0.55 : 1)
        .animation(.easeOut(duration: 0.15), value: dim)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(item.identifier)
    }

    /// The first of what's yours, as a card with a capsule that plays it.
    private func topCard(_ item: SearchItem) -> some View {
        let folder: (() -> Void)? = item.isRelease ? { openFolder(item) } : nil
        return SearchTopCard(item: item, artwork: artwork(item), play: topAction(item)) { open(item) }
            .modifier(OpenFolderActions(action: folder))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    /// "Show all 14 in Yours": "All" shows the first few of each kind, the chip all of them.
    private func showAll(_ title: String, _ target: SearchScope, _ show: @escaping (SearchScope) -> Void) -> some View {
        Button { show(target) } label: {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.action)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .accessibilityIdentifier("searchShowAll:" + target.rawValue)
    }

    /// A Plex or Jellyfin server that didn't answer.
    @ViewBuilder
    private var catalogErrors: some View {
        ForEach(catalogs.results.filter { $0.error != nil }) { r in
            Label(r.error ?? "", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
        }
    }

    /// A Plex or Jellyfin entry's picture, asked of the client the search used.
    private func artwork(_ item: SearchItem) -> URLRequest? {
        guard case .catalog(let e, let server) = item.kind else { return nil }
        return catalogs.client(for: server.id)?.imageRequest(for: e, pixels: 240)
    }

    // MARK: Opening

    private func open(_ item: SearchItem) {
        switch item.kind {
        case .library(let g):
            route = .group(g.id)
        case .release(let r):
            // One file found: it plays, as a file's row did. More: the release's folder.
            if r.count == 1, let f = r.files.first { play(f) } else { open(r) }
        case .catalog(let e, let server):
            if e.isPlayable {
                guard let source = catalogs.client(for: server.id) else { return }
                PlayerPresenter.play(queue: [source.mediaItem(for: e, parent: nil)], index: 0)
            } else {
                openedEntry = LibrarySearchResults.OpenedEntry(server: server.id, entry: e)
            }
        case .title(let m, let addon):
            // The query that found it goes into history.
            search.opened(from: addon == nil && !search.titlesQuery.isEmpty ? search.titlesQuery : query)
            opened = Opened(meta: m, addon: addon)
        }
    }

    private func openFolder(_ item: SearchItem) {
        if let folder = item.folderRoute { route = folder }
    }

    /// A file plays with its folder as the queue, as the server's browser plays it.
    private func play(_ f: ServerFile) {
        ContinueQueue.play(WebDAVClient(server: f.server).mediaItem(for: f.davItem, cleanTitles: cleanTitles))
    }

    /// A release: its folder; one file on its own (at the server's top): it plays.
    private func open(_ r: ServerFile.Release) {
        if let folder = r.folder {
            route = .webdavFolder(r.server.id.uuidString, folder.absoluteString, r.name.raw)
        } else if let f = r.files.first {
            play(f)
        }
    }

    /// The top result's capsule: Resume or Play for what has one thing to
    /// play next (a library title's next episode, a single file, a film on
    /// Plex or Jellyfin), Open for a folder of files or a show on a server.
    private func topAction(_ item: SearchItem) -> SearchPlay {
        let opens = SearchPlay(title: "Open", icon: "chevron.right") { open(item) }
        switch item.kind {
        case .library(let g):
            guard g.folder == nil else { return opens }
            let file = g.nextUp
            let entry = HistoryStore.shared.entry(forURL: file.path)
            // Played as Continue Watching plays a library file: the show's episodes as the queue.
            return SearchPlay(title: entry?.canResume == true ? "Resume" : "Play", icon: "play.fill") {
                ContinueQueue.play(entry?.item ?? Self.libraryItem(file))
            }
        case .release(let r):
            guard r.count == 1, let f = r.files.first else { return opens }
            let resumes = HistoryStore.shared.entry(forURL: f.file.url.absoluteString)?.canResume == true
            return SearchPlay(title: resumes ? "Resume" : "Play", icon: "play.fill") { play(f) }
        case .catalog(let e, _):
            guard e.isPlayable else { return opens }
            return SearchPlay(title: "Play", icon: "play.fill") { open(item) }
        case .title:
            return opens
        }
    }

    /// A library file never played, as ContinueQueue makes a show's other episodes.
    private static func libraryItem(_ file: URL) -> MediaItem {
        var m = MediaItem(url: file.path, title: TitleParser.clean(file.lastPathComponent), source: .local)
        m.historyKey = file.path
        let p = TitleParser.parse(file.lastPathComponent)
        if p.episode != nil { m.anime = AnimeHint(title: p.title, episode: p.episode) }
        return m
    }

    // MARK: Titles' problems

    /// Offline, IMDb out of reach, or nothing found: said in a row where the titles would be.
    @ViewBuilder
    private var titleProblem: some View {
        switch search.phase {
        case .failed(let offline):
            statusRow(offline ? "You're offline." : "Couldn't reach IMDb.",
                      detail: offline ? "Search works again once you're connected." : "Check the connection and try again.",
                      icon: offline ? "wifi.slash" : "exclamationmark.triangle", retry: true)
        case .done where results.titles.isEmpty && search.titlesQuery == typed:
            statusRow(kids.isOn ? "No titles rated for the kids profile match “\(typed)”." : "No titles match “\(typed)”.",
                      detail: nil, icon: "magnifyingglass", retry: false)
        default:
            EmptyView()
        }
    }

    private func statusRow(_ title: String, detail: String?, icon: String, retry: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(.secondary).frame(width: 46).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.body.weight(.semibold))
                if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
                if retry {
                    Button("Try Again") { search.retry() }
                        .buttonStyle(.bordered)
                        .tint(Theme.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .contain)
    }
}

/// "Open folder" on a release's row, by long press or a swipe: where the
/// server's pill under each file was. Other rows get neither.
private struct OpenFolderActions: ViewModifier {
    let action: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let action {
            content
                .contextMenu {
                    Button("Open folder", systemImage: "folder", action: action)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(action: action) { Label("Open folder", systemImage: "folder") }
                        .tint(Theme.swipeTint)
                }
        } else {
            content
        }
    }
}

/// The Recent header's Clear pill (1.28.7). iOS 26: the system's glass
/// button, which swells under the finger and morphs open into its menu. Before iOS 26: the filled capsule the search's other pills are.
struct ClearPillStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glass).controlSize(.small).tint(.primary)
                // 44 pt to tap, whatever the pill's own height.
                .frame(minHeight: 44)
        } else {
            flat(content)
        }
        #else
        flat(content)
        #endif
    }

    /// A menu takes the system's button styles only, so before iOS 26 the
    /// capsule is drawn on its label (1.28.10: a ButtonStyle of Folio's own
    /// left it plain text).
    private func flat(_ content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .foregroundStyle(.primary.opacity(0.75))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Theme.fill, in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}
