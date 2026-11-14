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

    /// The fuller lists (1.30.3): movies or shows with the typed text in
    /// their title, by kind ("movie", "series"), for `fullerQuery`. Asked
    /// when the Movies or Shows chip is chosen or Search is pressed, once
    /// per query and kind; typing in All stays the quick suggestions.
    @Published private(set) var fuller: [String: [MetaItem]] = [:]
    @Published private(set) var fullerLoading: Set<String> = []
    private var fullerQuery = ""
    private var fullerAsked: Set<String> = []
    private var fullerTasks: [String: Task<Void, Never>] = [:]
    private var fullerGeneration = 0

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
        // Only what changes is written (1.30.3): each write redraws the page.
        if q != addonQuery {
            addonTask?.cancel()
            if !addonResults.isEmpty { addonResults = [] }
            if addonsSearching { addonsSearching = false }
            addonQuery = ""
        }
        if q != fullerQuery { resetFuller() }
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
        // Search pressed: every movie and show with it in the title (1.30.3).
        loadFuller(type: "movie", for: q)
        loadFuller(type: "series", for: q)
    }

    /// A result was opened: the query that found it goes into history.
    func opened(from query: String) { commit(SearchHistoryStore.tidy(query)) }

    func retry() { start(current, wait: false, minLength: 1) }

    /// The kids profile turned on or off (1.30.4): nothing found under the
    /// other profile's limits stays (IMDb's titles, the fuller lists, the
    /// addons'), and the same text is asked again. Until then the same
    /// text did nothing, and the grown-ups' results stayed in the kids profile.
    func reset() {
        liveTask?.cancel()
        addonTask?.cancel()
        generation += 1
        resetFuller()
        current = ""
        addonQuery = ""
        if !titles.isEmpty { titles = [] }
        if !titlesQuery.isEmpty { titlesQuery = "" }
        if !addonResults.isEmpty { addonResults = [] }
        if addonsSearching { addonsSearching = false }
        if phase != .idle { phase = .idle }
    }

    // MARK: Fuller lists (1.30.3)

    /// IMDb's suggestions with the fuller lists after them, each title once
    /// (the suggestions' order is kept: nothing already on screen moves).
    nonisolated static func merged(_ suggestions: [MetaItem], fuller: [String: [MetaItem]]) -> [MetaItem] {
        var seen = Set<String>()
        var out: [MetaItem] = []
        for m in suggestions + (fuller["movie"] ?? []) + (fuller["series"] ?? []) where seen.insert(m.id).inserted { out.append(m) }
        return out
    }

    /// Whether a kind's fuller list is still to ask for `query`: once per
    /// query and kind, and not for a single letter.
    nonisolated static func shouldAskFuller(type: String, query: String, current: String, asked: Set<String>) -> Bool {
        guard query.count >= minLength else { return false }
        return query != current || !asked.contains(type)
    }

    /// Every movie or show (`type`: "movie", "series") with the text in its
    /// title. An answer for an older text is dropped, as the live search's.
    func loadFuller(type: String, for text: String) {
        let q = SearchHistoryStore.tidy(text)
        guard Self.shouldAskFuller(type: type, query: q, current: fullerQuery, asked: fullerAsked) else { return }
        if q != fullerQuery { resetFuller(); fullerQuery = q }
        fullerAsked.insert(type)
        fullerLoading.insert(type)
        let gen = fullerGeneration
        let kids = KidsProfile.shared.activeLimits
        fullerTasks[type] = Task { [weak self] in
            let t0 = CACurrentMediaTime()
            var items = await Self.lookUpFuller(q, type: type)
            if let kids, let found = items, !Task.isCancelled { items = await Self.kidsFiltered(found, limits: kids) }
            guard let self, gen == self.fullerGeneration, !Task.isCancelled else { return }   // a newer query took over
            self.fullerLoading.remove(type)
            self.fullerTasks[type] = nil
            if let items {
                self.fuller[type] = items
                dlog("search", String(format: "fuller %@ list: %d title(s) in %.0f ms", type, items.count, (CACurrentMediaTime() - t0) * 1000))
            } else {
                // Not read (offline, IMDb out of reach): asked again the next time it's wanted.
                self.fullerAsked.remove(type)
                dlog("search/error", "fuller \(type) list not read")
            }
        }
    }

    private func resetFuller() {
        fullerGeneration += 1
        fullerTasks.values.forEach { $0.cancel() }
        fullerTasks = [:]
        fullerAsked = []
        fullerQuery = ""
        if !fuller.isEmpty { fuller = [:] }
        if !fullerLoading.isEmpty { fullerLoading = [] }
    }

    /// Lab (`-labSearchOffline`): not read, as without a connection.
    private static func lookUpFuller(_ q: String, type: String) async -> [MetaItem]? {
        if CommandLine.arguments.contains("-labSearchOffline") { return nil }
        return await IMDbSource.titleSearch(q, type: type)
    }

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
            if phase != .idle { phase = .idle }
            if !titles.isEmpty { titles = [] }
            if !titlesQuery.isEmpty { titlesQuery = "" }
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
                // The query before's titles don't stay under the error (1.30.3).
                if self.titlesQuery != q {
                    if !self.titles.isEmpty { self.titles = [] }
                    self.titlesQuery = ""
                }
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
        // Not in the kids profile (1.30.4): Recent is the grown-ups' list.
        guard !q.isEmpty, !KidsProfile.shared.isOn else { return }
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
    /// Not observed (1.30.3): a refresh's progress, four times a second,
    /// redrew the whole page. Its files are followed by `indexSignature`,
    /// its progress by the status line's own view (SearchIndexingLine).
    private let index = LibraryIndexStore.shared
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
    /// What each server's index held when the lists were last made.
    @State private var indexSignature: [UUID: IndexSignature] = [:]
    /// The page is on screen: an index that changes behind another tab
    /// waits for the next visit.
    @State private var visible = false
    /// The text the page shows results for (1.30.3). It follows the field
    /// at once while there's text; emptied, it follows a moment later or
    /// when the page has gone. Cancel empties the field as the search
    /// closes, and the whole list was swapped for the start page (recent
    /// searches' chips, the Continue watching posters) in the frames of the
    /// field closing and the tab changing: the lag on dismissing.
    @State private var shownQuery = ""
    @State private var emptying: Task<Void, Never>?
    @State private var filtering: Task<Void, Never>?
    static let filterDelay: Duration = .milliseconds(150)

    private struct IndexSignature: Equatable {
        let files: Int
        let refreshed: Date?
    }

    private static func signature(_ states: [UUID: LibraryIndexStore.State]) -> [UUID: IndexSignature] {
        states.mapValues { IndexSignature(files: $0.searchable.count, refreshed: $0.index?.refreshed) }
    }

    private var typed: String { SearchHistoryStore.tidy(query) }
    private var showsStart: Bool { SearchHistoryStore.tidy(shownQuery).isEmpty }
    private static let chipsID = "searchChips"
    private static let startID = "searchStart"
    private static let emptyingDelay: Duration = .milliseconds(350)

    var body: some View {
        answered
            .navigationDestination(item: $opened) { o in
                MetaDetailView(preview: o.meta, sourceAddon: o.addon).zoomDestination("search|" + o.meta.id, in: zoomNS, zoom: false)
            }
            .navigationDestination(item: $route) { r in LibraryRoute.destination(r) }
            // What the pages opened here push by value (1.30.4): a folder's
            // titles, a file's page. The search's stack had nothing for them.
            .navigationDestination(for: LibraryRoute.self) { r in LibraryRoute.destination(r) }
            .navigationDestination(item: $openedEntry) { o in
                // The client the search made, not a new one at each redraw (1.30.3).
                if let source = catalogs.client(for: o.server) {
                    CatalogBrowserView(source: source, parent: o.entry, title: CatalogTitles.rowTitle(o.entry))
                }
            }
    }
    @Namespace private var zoomNS

    private var watched: some View {
        page
            .onChange(of: query) { _, text in
                emptying?.cancel()
                emptying = nil
                filtering?.cancel()
                guard !SearchHistoryStore.tidy(text).isEmpty else {
                    // Emptied: nothing is redrawn now (see shownQuery).
                    emptying = Task {
                        do { try await Task.sleep(for: Self.emptyingDelay) } catch { return }   // text came back
                        emptied()
                    }
                    return
                }
                shownQuery = text
                search.textChanged(text)
                catalogs.textChanged(kids.isOn ? "" : text)
                // After a pause (1.30.4): every indexed file of every server
                // was looked through on the main thread at each keystroke.
                filtering?.cancel()
                filtering = Task {
                    do { try await Task.sleep(for: Self.filterDelay) } catch { return }
                    refilter()
                }
            }
            // The Search key comes through the tab's field on every iOS (1.30.4, PageSearchField).
            .onReceive(NotificationCenter.default.publisher(for: .searchTabSubmitted)) { note in
                search.submit((note.object as? String) ?? query)
            }
            .task { await search.loadHistory() }
            // Each server's index brought up to date when it's due, and text
            // kept from the last search asked again.
            .onAppear {
                HitchProbe.mark("search", "page appeared")
                visible = true
                emptying?.cancel()
                emptying = nil
                shownQuery = query
                // Home asks for the Real-Debrid server only; the others are asked for here.
                if !kids.isOn { for server in webdav.servers { index.refreshIfNeeded(server) } }
                // Each of these does nothing for the text it already answered (1.30.3).
                search.textChanged(query)
                catalogs.textChanged(kids.isOn ? "" : query)
                if SearchHistoryStore.tidy(query).isEmpty { scope = .all }
                let grouped = LibraryOrganizer.groups(local.files)
                let now = Self.signature(index.states)
                // Made again only when the library or an index changed while away.
                let changed = grouped != groups || now != indexSignature
                if grouped != groups { groups = grouped }
                indexSignature = now
                refilter(force: changed)
                HitchProbe.mark("search", "page set up")
            }
            .onDisappear {
                visible = false
                // Out of sight: the emptied field's start page is set up now.
                if emptying != nil { emptying?.cancel(); emptying = nil; emptied() }
            }
    }

    /// The second half of the page's watching (two halves: one chain was
    /// long for the compiler).
    private var answered: some View {
        watched
            .onChange(of: local.files) { _, files in
                groups = LibraryOrganizer.groups(files)
                refilter(force: true)
            }
            .onChange(of: webdav.servers) { refilter(force: true) }
            // The profile turned on or off (1.30.4): what the other profile
            // opened here closes, the text goes (RootView), and nothing it
            // found stays. Pages left open kept playing anything.
            .onChange(of: kids.isOn) {
                opened = nil
                route = nil
                openedEntry = nil
                search.reset()
                catalogs.textChanged(kids.isOn ? "" : query)
                refilter(force: true)
            }
            // A counter, not the index itself: comparing two indexes at
            // every redraw would cost more than the search does.
            // Only when a server's files changed (1.30.3): `states` also
            // changes with a refresh's progress, up to four times a second,
            // and each change found and put together the whole list again,
            // behind another tab too.
            .onReceive(index.$states) { states in
                guard visible else { return }
                let now = Self.signature(states)
                guard now != indexSignature else { return }
                indexSignature = now
                indexTick &+= 1
            }
            .onChange(of: indexTick) { refilter(force: true) }
            // Nothing to put together when an empty answer replaces an empty one.
            .onReceive(search.$titles) { new in if !(new.isEmpty && search.titles.isEmpty) { answersTick &+= 1 } }
            .onReceive(search.$addonResults) { new in if !(new.isEmpty && search.addonResults.isEmpty) { answersTick &+= 1 } }
            .onReceive(search.$fuller) { new in if !(new.isEmpty && search.fuller.isEmpty) { answersTick &+= 1 } }
            // The Movies or Shows chip (or "Show all … shows"): every title
            // of that kind with the text in its name, not only the few of
            // the suggestions (1.30.3). Asked again for the text typed on
            // while the chip stays chosen, once the suggestions answered.
            .onChange(of: scope) { loadFuller() }
            .onChange(of: search.titlesQuery) { loadFuller() }
            .onReceive(catalogs.$results) { new in if !(new.isEmpty && catalogs.results.isEmpty) { answersTick &+= 1 } }
            .onChange(of: answersTick) { compose() }
    }

    /// The field has been empty for a moment, or the page has gone: the
    /// start page, and every search told so.
    private func emptied() {
        emptying = nil
        guard SearchHistoryStore.tidy(query).isEmpty else { return }
        shownQuery = ""
        scope = .all
        search.textChanged(query)
        catalogs.textChanged(kids.isOn ? "" : query)
        refilter()
    }

    private func loadFuller() {
        switch scope {
        case .movies: search.loadFuller(type: "movie", for: query)
        case .shows: search.loadFuller(type: "series", for: query)
        case .all, .yours: break
        }
    }

    private var page: some View {
        ScrollViewReader { proxy in
            List {
                if showsStart {
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
                        .id(Self.startID)
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
            // The start page from its top, not from where the results were scrolled to (1.30.3).
            .onChange(of: showsStart) { _, start in if start { proxy.scrollTo(Self.startID, anchor: .top) } }
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
        if !(found.isEmpty && mine.isEmpty) { mine = found }
        compose(mine: found)
    }

    /// The whole list: what's yours, then Plex and Jellyfin's entries,
    /// then IMDb's titles and the addons'.
    private func compose(mine found: [SearchItem]? = nil) {
        var owned = found ?? mine
        let words = LibrarySearchText.words(query)
        // Plex and Jellyfin's entries for these words only (1.30.3): the
        // query before's stayed, as the top card too, until the answer came.
        if !words.isEmpty, catalogs.resultsWords == words {
            for r in catalogs.results { owned += r.entries.map { SearchItem(entry: $0, server: r.server) } }
        }
        // Nothing found and nothing shown: nothing to make again.
        if words.isEmpty, owned.isEmpty, search.titles.isEmpty, search.fuller.isEmpty, search.addonResults.isEmpty,
           results.owned.isEmpty, results.titles.isEmpty { return }
        results = SearchResults(owned: owned, imdb: DiscoverSearch.merged(search.titles, fuller: search.fuller), addons: search.addonResults)
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
        // A server's index being read: its own view, so its progress redraws one line.
        else if !kids.isOn { SearchIndexingLine(servers: webdav.servers) }
        switch active {
        case .all:
            if let top = results.top { topCard(top) }
            ForEach(results.ownedShort) { row($0) }
            if results.hiddenOwned > 0 { showAll("Show all \(results.owned.count) in Library", .yours, show) }
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
        // The fuller list on its way (1.30.3).
        if !search.fullerLoading.isEmpty {
            let kind = search.fullerLoading.count > 1 ? "movies and shows" : search.fullerLoading.contains("series") ? "shows" : "movies"
            return (text: "Finding more \(kind)…", working: true)
        }
        if catalogs.searching { return (text: "Searching Plex and Jellyfin…", working: true) }
        if search.addonsSearching { return (text: "Searching your addons…", working: true) }
        if let limits = kids.activeLimits { return (text: "Movies and shows rated \(KidsRules.summary(limits)).", working: false) }
        return nil
    }

    private func statusLine(_ text: String, working: Bool) -> some View {
        SearchStatusLine(text: text, working: working)
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

    /// "Show all 14 in Library": "All" shows the first few of each kind, the chip all of them.
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
        ForEach(catalogs.resultsWords == LibrarySearchText.words(query) ? catalogs.results.filter { $0.error != nil } : []) { r in
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
            // A folder opens as one, and a title found in a folder as its file's page (1.30.4):
            // `.group` opened a folder's first film, and a title in one isn't a group of its own.
            if let folder = g.folder {
                route = .folder(folder.path)
            } else {
                route = groups.contains { $0.id == g.id } ? .group(g.id) : .file(g.nextUp.path)
            }
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

/// The one quiet line under the chips.
private struct SearchStatusLine: View {
    let text: String
    let working: Bool

    var body: some View {
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
}

/// "Indexing Real-Debrid… 12 of 220 folders" (1.30.3): the only part of
/// the page that follows a refresh's progress.
private struct SearchIndexingLine: View {
    let servers: [WebDAVServer]
    @ObservedObject private var index = LibraryIndexStore.shared

    var body: some View {
        if let server = servers.first(where: { index.state($0.id).refreshing }) {
            let st = index.state(server.id)
            SearchStatusLine(text: "Indexing \(server.name)… \(st.done) of \(st.total) folders", working: true)
        }
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
