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
    /// The Search tab's fuller lists as you type (1.30.6): from 3
    /// characters, 900 ms after the last change, and only once the
    /// suggestions have answered. Each is IMDb's /search/title/ page, 50
    /// titles of HTML, and they were asked at the suggestions' 300 ms from 2
    /// characters: two heavy pages a pause, and a 429 from IMDb held every
    /// plain IMDb request (title pages, episodes, Discover) for 30 s.
    /// Search on the keyboard and a Shows or Movies pill still ask from 2.
    nonisolated static let fullerMinLength = 3
    nonisolated static let fullerPause: Duration = .milliseconds(900)
    /// How long an empty fuller list is remembered (1.30.6): IMDbSource
    /// keeps only lists with titles in them, so a query that found nothing
    /// was asked again each time you came back to it.
    nonisolated static let emptyKept: TimeInterval = 5 * 60

    @Published private(set) var phase: Phase = .idle
    /// IMDb titles, and the query they answer.
    @Published private(set) var titles: [MetaItem] = []
    @Published private(set) var titlesQuery = ""
    /// Addon catalogs' answers to the last query you pressed Search for.
    @Published private(set) var addonResults: [AddonSearchView.SearchResult] = []
    @Published private(set) var addonsSearching = false
    @Published private(set) var history: [SearchHistoryEntry] = []

    /// The fuller lists (1.30.3): movies or shows with the typed text in
    /// their title, by kind ("movie", "series"), each for the query in
    /// `fullerFor`. Asked when Search is pressed, the Shows or Movies pill
    /// is chosen, or typing pauses on the Search tab (1.30.5), once per
    /// query and kind; the Library tab asks none.
    ///
    /// A new text keeps the lists up, dimmed (`staleIDs`), until its own
    /// answer replaces them (1.30.6), as the suggestions stay. Each
    /// keystroke emptied them: about 100 rows went to 8 dimmed suggestions,
    /// and the list jumped.
    @Published private(set) var fuller: [String: [MetaItem]] = [:]
    /// The query each kind's list in `fuller` answers. Set before `fuller`,
    /// so the page reads both together.
    private(set) var fullerFor: [String: String] = [:]
    @Published private(set) var fullerLoading: Set<String> = []
    /// The Search tab's pause is running for this text, or it's over and
    /// waits for the suggestions (1.30.6). Counted as loading: with the
    /// suggestions from the cache, "No titles match" showed for a frame
    /// before the fuller lists were asked.
    @Published private(set) var fullerWaitingFor: String?
    private var fullerQuery = ""
    private var fullerAsked: Set<String> = []
    private var fullerTasks: [String: Task<Void, Never>] = [:]
    private var fullerGeneration = 0
    /// The Search tab's pause before both kinds are asked (1.30.5).
    private var pauseTask: Task<Void, Never>?
    /// The pause ended before the suggestions answered: both kinds are
    /// asked when they do, for this text (1.30.6).
    private var fullerAfterSuggestions: String?
    /// Fuller lists IMDb answered empty, by IMDbSource.titleSearchKey, and when.
    private static var emptyAnswers: [String: Date] = [:]

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
        // The lists asked for the last text stop; what they found stays up (1.30.6).
        if q != fullerQuery { stopFuller() }
        guard q != current else { return }          // only spaces changed
        // A pause the last text waited for asks nothing for this one (1.30.5).
        cancelPause()
        start(q, wait: true)
        // Too short for any title: nothing of the last text's stays.
        if q.count < Self.minLength { dropFuller() }
    }

    /// Search on the keyboard: now, without the pause, plus addon catalogs; kept in history.
    func submit(_ text: String) {
        let q = SearchHistoryStore.tidy(text)
        guard !q.isEmpty else { return }
        dlog("search", "\(q.count) character(s) submitted")
        commit(q)
        if q != current || phase != .done { start(q, wait: false, minLength: 1) }
        searchAddons(q)
        // Search pressed: every movie and show with it in the title (1.30.3), from 2 characters.
        askBothKinds(q)
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
        cancelPause()
        generation += 1
        stopFuller()
        dropFuller()
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
        if q != fullerQuery { stopFuller(); fullerQuery = q }
        fullerAsked.insert(type)
        // The list on screen is this text's already (typed on and back, 1.30.6).
        if fullerFor[type] == q { return }
        // IMDb found nothing for it a moment ago: not asked again (1.30.6).
        if Self.knownEmpty(q, type: type) { answered(type, for: q, []); return }
        fullerLoading.insert(type)
        let gen = fullerGeneration
        let kids = KidsProfile.shared.activeLimits
        fullerTasks[type] = Task { [weak self] in
            let t0 = CACurrentMediaTime()
            let found = await Self.lookUpFuller(q, type: type)
            guard let self, gen == self.fullerGeneration, !Task.isCancelled else { return }   // a newer query took over
            if found?.isEmpty == true { Self.noteEmpty(q, type: type) }
            var items = found
            // Kids profile: its title pages only for the text still in the field (1.30.6).
            if let kids, let f = found, !f.isEmpty {
                items = await Self.kidsFiltered(f, limits: kids)
                guard gen == self.fullerGeneration, !Task.isCancelled else { return }
            }
            self.fullerTasks[type] = nil
            if let items {
                self.answered(type, for: q, items)
                dlog("search", String(format: "fuller %@ list: %d title(s) in %.0f ms", type, items.count, (CACurrentMediaTime() - t0) * 1000))
            } else {
                // Not read (offline, IMDb out of reach): asked again the next time it's wanted.
                self.fullerAsked.remove(type)
                self.fullerLoading.remove(type)
                self.dropStaleFuller()
                dlog("search/error", "fuller \(type) list not read")
            }
        }
    }

    /// A kind's list for `q`: shown, and a list of the last text's that
    /// nothing is coming for goes.
    private func answered(_ type: String, for q: String, _ items: [MetaItem]) {
        fullerFor[type] = q
        fuller[type] = items
        if fullerLoading.contains(type) { fullerLoading.remove(type) }
        dropStaleFuller()
    }

    /// The Search tab (1.30.5): every movie and show with the text in its
    /// title, so its "all" is more than IMDb's 8 suggestions. `wait`: once
    /// typing has paused (`fullerPause`) and the suggestions have answered
    /// (1.30.6); without, now (the tab chosen). From 3 characters, once per
    /// query and kind, kids-filtered (loadFuller).
    func loadBothKinds(for text: String, wait: Bool) {
        cancelPause()
        let q = SearchHistoryStore.tidy(text)
        guard q.count >= Self.fullerMinLength else { return }
        let kinds = ["movie", "series"].filter { Self.shouldAskFuller(type: $0, query: q, current: fullerQuery, asked: fullerAsked) && fullerFor[$0] != q }
        guard !kinds.isEmpty else { return }
        // Nothing to read (each known to be empty), or now: answered or asked at once.
        guard wait, kinds.contains(where: { !Self.knownEmpty(q, type: $0) }) else { askBothKinds(q); return }
        fullerWaitingFor = q
        // A kind known to be empty is answered now; the other waits for the pause.
        for type in kinds where Self.knownEmpty(q, type: type) { loadFuller(type: type, for: q) }
        pauseTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.fullerPause) } catch { return }   // typed on
            self?.pauseEnded(q)
        }
    }

    /// The pause is over: both kinds now if the suggestions have answered,
    /// when they do if they're on the way, not at all if they failed (Try
    /// Again asks them).
    private func pauseEnded(_ q: String) {
        pauseTask = nil
        if phase == .done, titlesQuery == q {
            askBothKinds(q)
        } else if phase == .loading, current == q {
            fullerAfterSuggestions = q
        } else {
            fullerWaitingFor = nil
            dropStaleFuller()
        }
    }

    private func askBothKinds(_ q: String) {
        // The kinds to read first, then those known to be empty: an answer
        // drops the last text's lists that nothing is coming for. All of it
        // before the waiting ends, so the page never sees neither (1.30.6).
        let kinds = ["movie", "series"]
        for type in kinds where !Self.knownEmpty(q, type: type) { loadFuller(type: type, for: q) }
        for type in kinds where Self.knownEmpty(q, type: type) { loadFuller(type: type, for: q) }
        cancelPause()
        dropStaleFuller()
    }

    /// The Library tab chosen during the pause (1.30.6, post-fix review):
    /// the Library tab asks IMDb for none of its fuller lists.
    func libraryChosen() {
        guard pauseTask != nil || fullerAfterSuggestions != nil else { return }
        cancelPause()
        dropStaleFuller()
    }

    private func cancelPause() {
        pauseTask?.cancel()
        pauseTask = nil
        fullerAfterSuggestions = nil
        if fullerWaitingFor != nil { fullerWaitingFor = nil }
    }

    /// The lists asked for the last text stop; what they found stays up
    /// until this text's answer, or until nothing is coming for it.
    private func stopFuller() {
        fullerGeneration += 1
        fullerTasks.values.forEach { $0.cancel() }
        fullerTasks = [:]
        fullerAsked = []
        fullerQuery = ""
        if !fullerLoading.isEmpty { fullerLoading = [] }
    }

    private func dropFuller() {
        fullerFor = [:]
        if !fuller.isEmpty { fuller = [:] }
    }

    /// The last text's lists that nothing for this text will replace: none
    /// of their kind asked, on the way, or waiting for the pause.
    private func dropStaleFuller() {
        guard fullerWaitingFor != current else { return }
        let gone = fuller.keys.filter { fullerFor[$0] != current && !(fullerQuery == current && fullerLoading.contains($0)) }
        guard !gone.isEmpty else { return }
        for type in gone { fullerFor[type] = nil }
        var kept = fuller
        for type in gone { kept[type] = nil }
        fuller = kept
    }

    /// Whether the fuller lists, and the search, are still on the way for
    /// this text: asked, or waiting for the pause (1.30.6).
    var fullerBusy: Bool { !fullerLoading.isEmpty || fullerWaitingFor != nil }

    /// The ids of titles shown from the last text's fuller lists, dimmed
    /// until this text's answer replaces them (1.30.6). A title the new
    /// suggestions have too isn't one.
    var staleIDs: Set<String> {
        Self.staleIDs(suggestions: titles, fuller: fuller, fullerFor: fullerFor, query: current)
    }

    nonisolated static func staleIDs(suggestions: [MetaItem], fuller: [String: [MetaItem]], fullerFor: [String: String], query: String) -> Set<String> {
        let fresh = Set(suggestions.map(\.id))
        var out = Set<String>()
        for (type, items) in fuller where fullerFor[type] != query {
            for m in items where !fresh.contains(m.id) { out.insert(m.id) }
        }
        return out
    }

    /// Both kinds' fuller lists answered for `query`, or a text too short
    /// for them (the Search tab shows the suggestions only): what the Search
    /// tab lists is all known, and the Library tab's hint can count it (1.30.6).
    func fullerCounted(for query: String) -> Bool {
        let q = SearchHistoryStore.tidy(query)
        return q.count < Self.fullerMinLength || (fullerFor["movie"] == q && fullerFor["series"] == q)
    }

    // MARK: Empty answers kept (1.30.6)

    static func knownEmpty(_ q: String, type: String, now: Date = Date()) -> Bool {
        guard let at = emptyAnswers[IMDbSource.titleSearchKey(q, type: type)] else { return false }
        return now.timeIntervalSince(at) < emptyKept
    }

    static func noteEmpty(_ q: String, type: String, now: Date = Date()) {
        emptyAnswers = emptyAnswers.filter { now.timeIntervalSince($0.value) < emptyKept }
        if emptyAnswers.count >= 200 { emptyAnswers.removeAll() }
        emptyAnswers[IMDbSource.titleSearchKey(q, type: type)] = now
    }

    static func forgetEmptyAnswers() { emptyAnswers.removeAll() }

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
                if let kids {
                    // Its title pages only for the text still in the field (1.30.6).
                    guard let self, gen == self.generation, !Task.isCancelled else { return }
                    items = await Self.kidsFiltered(items, limits: kids)
                }
                guard let self, gen == self.generation else { return }             // a newer query took over
                self.titles = items
                self.titlesQuery = q
                self.phase = .done
                // The Search tab's pause ended first: its fuller lists now (1.30.6).
                if self.fullerAfterSuggestions == q { self.askBothKinds(q) }
                self.dropStaleFuller()
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
                // Nothing asked after a failure, and nothing of the last text's stays (1.30.6).
                if self.fullerWaitingFor == q || self.fullerAfterSuggestions == q { self.cancelPause() }
                self.dropStaleFuller()
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
            // Typed on (1.30.6): the pages still to read aren't asked for, as each one already asked is cancelled.
            guard !Task.isCancelled, m.id.hasPrefix("tt"), m.contentRating == nil, let d = await IMDbSource.details(id: m.id, type: m.type) else { return m }
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
/// every tab. One kind of row, in two tabs (1.30.5): Library, what's yours
/// (the library, your servers' releases, Plex and Jellyfin) under a top
/// card, and Search, movies and shows from IMDb as you type and your
/// addons' titles after Search, with Shows and Movies pills. Until 1.28.11
/// each source was a section of its own with its own rows, a file on a
/// server was a row each (a season: 24), and each addon catalog a carousel.
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
    /// Library or Search, kept across launches (1.30.5).
    @AppStorage(SettingsKey.searchTabLast) private var tabRaw = SearchTab.library.rawValue
    /// Shows or Movies on the Search tab; none (every title) again for a new query (1.30.5).
    @State private var filter: SearchKindFilter?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    /// The Library tab with nothing of yours waits for Search's count this
    /// long after typing stops, then says so (1.30.6). It waited for IMDb
    /// and the addons whatever they took, up to 25 s in the kids profile,
    /// with "Searching…" up all the while. `searchWaitOver`: the text the
    /// wait ran out for.
    static let searchWait: Duration = .milliseconds(1500)
    @State private var searchWaitOver = ""
    @State private var searchWaiting: Task<Void, Never>?

    /// The index's content, not its dates (1.30.6): `version` moves only
    /// when its files or folders change. `refreshed` moved at each check of
    /// the start folder, once a minute, and the page was filtered again
    /// each time with nothing new.
    private struct IndexSignature: Equatable {
        let files: Int
        let version: Int
    }

    private static func signature(_ states: [UUID: LibraryIndexStore.State]) -> [UUID: IndexSignature] {
        states.mapValues { IndexSignature(files: $0.searchable.count, version: $0.version) }
    }

    private var typed: String { SearchHistoryStore.tidy(query) }
    private var showsStart: Bool { SearchHistoryStore.tidy(shownQuery).isEmpty }
    private var tab: SearchTab { SearchTab.remembered(tabRaw) }
    private var motion: Animation? { reduceMotion ? nil : Animation.snappy(duration: 0.28) }
    private static let tabsID = "searchTabs"
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
                // Emptied a moment ago and typed again: a new query too (1.30.5).
                let wasEmptied = emptying != nil
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
                // Another text, not this one typed on: every title again (1.30.5).
                if filter != nil, wasEmptied || !SearchKindFilter.keeps(from: shownQuery, to: text) { filter = nil }
                shownQuery = text
                search.textChanged(text)
                // The Search tab: both kinds' fuller lists once typing pauses (1.30.5).
                if tab == .search { search.loadBothKinds(for: text, wait: true) }
                waitForSearch()
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
                // Nothing asked twice (once per query and kind, 1.30.5).
                if SearchHistoryStore.tidy(query).isEmpty { filter = nil } else if tab == .search { search.loadBothKinds(for: query, wait: false) }
                waitForSearch()
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
            // The store's announcement, read once it's made (1.30.6): its
            // states are no longer published one by one (LibraryIndexStore).
            .onReceive(index.objectWillChange.receive(on: DispatchQueue.main)) { _ in
                guard visible else { return }
                let now = Self.signature(index.states)
                guard now != indexSignature else { return }
                indexSignature = now
                indexTick &+= 1
            }
            .onChange(of: indexTick) { refilter(force: true) }
            // Nothing to put together when an empty answer replaces an empty one.
            .onReceive(search.$titles) { new in if !(new.isEmpty && search.titles.isEmpty) { answersTick &+= 1 } }
            .onReceive(search.$addonResults) { new in if !(new.isEmpty && search.addonResults.isEmpty) { answersTick &+= 1 } }
            .onReceive(search.$fuller) { new in if !(new.isEmpty && search.fuller.isEmpty) { answersTick &+= 1 } }
            // Answered (1.30.6): the last text's fuller lists are dimmed from
            // then, also when the suggestions are as empty as before.
            .onReceive(search.$phase) { p in if p != .loading, p != .idle, !search.fuller.isEmpty { answersTick &+= 1 } }
            .onReceive(catalogs.$results) { new in if !(new.isEmpty && catalogs.results.isEmpty) { answersTick &+= 1 } }
            .onChange(of: answersTick) { compose() }
    }

    /// The Library tab's wait for Search, started again at each change (1.30.6).
    private func waitForSearch() {
        searchWaiting?.cancel()
        let text = typed
        guard !text.isEmpty, searchWaitOver != text else { return }
        searchWaiting = Task {
            do { try await Task.sleep(for: Self.searchWait) } catch { return }   // typed on
            searchWaitOver = text
        }
    }

    /// The field has been empty for a moment, or the page has gone: the
    /// start page, and every search told so.
    private func emptied() {
        emptying = nil
        guard SearchHistoryStore.tidy(query).isEmpty else { return }
        shownQuery = ""
        filter = nil
        search.textChanged(query)
        catalogs.textChanged(kids.isOn ? "" : query)
        refilter()
    }

    /// A tab chosen, by its pill or the hint (1.30.5): kept for next time
    /// (the hint is a choice too), the list from its top, and on Search
    /// both kinds' fuller lists asked now.
    private func choose(_ t: SearchTab, proxy: ScrollViewProxy) {
        guard t != tab else { return }
        withAnimation(motion) {
            tabRaw = t.rawValue
            proxy.scrollTo(Self.tabsID, anchor: .top)
        }
        if t == .search { search.loadBothKinds(for: query, wait: false) } else { search.libraryChosen() }
    }

    /// A Shows or Movies pill: that kind only, or every title again. A kind
    /// chosen asks for its fuller list, as its chip did (1.30.3).
    private func pick(_ k: SearchKindFilter, proxy: ScrollViewProxy) {
        let next = SearchKindFilter.toggled(filter, by: k)
        withAnimation(motion) {
            filter = next
            proxy.scrollTo(Self.tabsID, anchor: .top)
        }
        if let next { search.loadFuller(type: next.imdbType, for: query) }
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
                    resultRows(onTab: { choose($0, proxy: proxy) })
                }
            }
            .listStyle(.plain)
            // The top marker's row has no height of its own (1.30.6).
            .environment(\.defaultMinListRowHeight, 0)
            // A readable column on a wide iPad window (1.30.0).
            .readableListWidth()
            .scrollContentBackground(.hidden)
            // Library | Search and Shows | Movies stay on screen over the results (1.30.6).
            .modifier(SearchBarsPinned(shown: !showsStart) {
                bars(onTab: { choose($0, proxy: proxy) }, onFilter: { pick($0, proxy: proxy) })
            })
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
        results = SearchResults(owned: owned, imdb: DiscoverSearch.merged(search.titles, fuller: search.fuller), addons: search.addonResults,
                                stale: search.staleIDs)
    }

    // MARK: Results

    /// Library | Search, then (Search) Shows | Movies (1.30.5). Pinned over
    /// the results since 1.30.6 (SearchBarsPinned): as the list's first
    /// rows they scrolled away, and the Search tab can list 100 titles.
    private func bars(onTab: @escaping (SearchTab) -> Void, onFilter: @escaping (SearchKindFilter) -> Void) -> some View {
        let active = tab
        return VStack(alignment: .leading, spacing: 0) {
            SearchPillBar(options: tabOptions(active, onTab), glass: true)
            if active == .search {
                SearchPillBar(options: filterOptions(onFilter), compact: true, glass: true)
                    .transition(.opacity)
            }
        }
    }

    /// The status line, the hint, and the tab's rows (1.30.5).
    @ViewBuilder
    private func resultRows(onTab: @escaping (SearchTab) -> Void) -> some View {
        let active = tab
        // Where "the list from its top" scrolls to (1.30.6): the bars above aren't rows now.
        Color.clear.frame(height: 0)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .accessibilityHidden(true)
            .id(Self.tabsID)
        // Each side counted for this text only: the last answers stay up while the next are asked for.
        let owned = filteredWords == LibrarySearchText.words(query) ? results.count(.library) : 0
        let titles = search.titlesQuery == typed ? results.count(.search) : 0
        let hint = active == .library
            // A count only when it's all of what Search lists (1.30.6): this tab asks IMDb's suggestions, not its fuller lists.
            ? SearchTab.hint(on: .library, owned: owned, titles: titles, settled: librarySettled,
                             counted: search.fullerCounted(for: typed) && !search.addonsSearching)
            // Answered, not failed (1.30.6): offline, "No movies or shows found" was under "You're offline."
            : SearchTab.hint(on: .search, owned: owned, titles: titles, settled: titlesAnswered)
        if let status = status(hinted: hint != nil) { statusLine(status.text, working: status.working) }
        // A server's index being read: its own view, so its progress redraws one line.
        else if active == .library, !kids.isOn { SearchIndexingLine(servers: webdav.servers) }
        if let hint { hintRow(hint, onTab: onTab) }
        switch active {
        case .library:
            if let top = results.top { topCard(top) }
            ForEach(results.ownedRest) { row($0) }
            catalogErrors
            // Once Search has answered too, so it doesn't give way to the hint a moment
            // later; or once the wait for it ran out (1.30.6), and the hint comes when it can.
            if hint == nil, results.owned.isEmpty, librarySettled, titlesSettled || searchWaitOver == typed {
                statusRow("Nothing in your library matches “\(typed)”.", detail: nil, icon: "magnifyingglass", retry: false)
            }
        case .search:
            titleProblem(hinted: hint != nil)
            ForEach(results.filtered(filter)) { row($0) }
        }
    }

    private func tabOptions(_ active: SearchTab, _ onTab: @escaping (SearchTab) -> Void) -> [SearchPillBar.Option] {
        SearchTab.allCases.map { t in
            SearchPillBar.Option(id: "searchTab:" + t.rawValue, title: t.title, selected: t == active, action: { onTab(t) })
        }
    }

    private func filterOptions(_ onFilter: @escaping (SearchKindFilter) -> Void) -> [SearchPillBar.Option] {
        let chosen = filter
        return SearchKindFilter.allCases.map { k in
            SearchPillBar.Option(id: "searchFilter:" + k.rawValue, title: k.title, selected: k == chosen, action: { onFilter(k) })
        }
    }

    /// What's yours is all in for the typed words (1.30.5): the library and
    /// servers looked through (after their pause), Plex and Jellyfin answered.
    private var librarySettled: Bool {
        let words = LibrarySearchText.words(query)
        return !words.isEmpty && words == filteredWords && !catalogs.searching
    }

    /// IMDb, the fuller lists and the addons are all done, answered or
    /// failed (1.30.5). A pause before the fuller lists counts as on the
    /// way (1.30.6).
    private var titlesSettled: Bool {
        Self.titlesSettled(search.phase, fullerBusy: search.fullerBusy, addonsSearching: search.addonsSearching, answeredOnly: false)
    }

    /// The same, and IMDb answered (1.30.6): a failure (offline) found
    /// nothing, it didn't find that there's nothing.
    private var titlesAnswered: Bool {
        Self.titlesSettled(search.phase, fullerBusy: search.fullerBusy, addonsSearching: search.addonsSearching, answeredOnly: true)
    }

    nonisolated static func titlesSettled(_ phase: DiscoverSearch.Phase, fullerBusy: Bool, addonsSearching: Bool, answeredOnly: Bool) -> Bool {
        switch phase {
        case .done: return !fullerBusy && !addonsSearching
        case .failed: return !answeredOnly && !fullerBusy && !addonsSearching
        case .idle, .loading: return false
        }
    }

    /// The one quiet line under the tabs: what the tab's search is still
    /// doing (the most telling of it), or what it's waiting for. Until the
    /// one list each of these was a spinner row of its own.
    private func status(hinted: Bool) -> (text: String, working: Bool)? {
        if typed.count < DiscoverSearch.minLength, search.phase == .idle {
            return (text: tab == .library ? "Keep typing to search your library." : "Keep typing to search titles.", working: false)
        }
        // Each tab says what it's waiting for, not the other's (1.30.5).
        switch tab {
        case .library:
            if catalogs.searching { return (text: "Searching Plex and Jellyfin…", working: true) }
            // Nothing of yours, and Search still looking (1.30.5): said, not a
            // blank page until the hint to Search can count its results. Not
            // past the wait for Search (1.30.6), nor under the hint.
            if results.owned.isEmpty, !hinted, !librarySettled || (!titlesSettled && searchWaitOver != typed) {
                return (text: "Searching…", working: true)
            }
        case .search:
            if search.phase == .loading { return (text: "Searching movies and shows…", working: true) }
            // The fuller list on its way (1.30.3), or the pause before it (1.30.6).
            if search.fullerBusy {
                let kinds = search.fullerWaitingFor != nil ? ["movie", "series"] : search.fullerLoading
                let kind = kinds.count > 1 ? "movies and shows" : kinds.contains("series") ? "shows" : "movies"
                return (text: "Finding more \(kind)…", working: true)
            }
            if search.addonsSearching { return (text: "Searching your addons…", working: true) }
        }
        if let limits = kids.activeLimits { return (text: "Movies and shows rated \(KidsRules.summary(limits)).", working: false) }
        return nil
    }

    /// "Nothing in your library — 12 results in Search" (1.30.5): the other
    /// tab a tap away; the tab chosen this way is kept, as with its pill.
    private func hintRow(_ hint: SearchTab.Hint, onTab: @escaping (SearchTab) -> Void) -> some View {
        Button { onTab(hint.target) } label: {
            HStack(spacing: 6) {
                Text(hint.text).font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.action)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityHint("Shows the \(hint.target.title) tab")
        .accessibilityIdentifier("searchTabHint")
    }

    private func statusLine(_ text: String, working: Bool) -> some View {
        SearchStatusLine(text: text, working: working)
    }

    /// Every result's row, whatever found it.
    private func row(_ item: SearchItem) -> some View {
        // The last titles stay up, dimmed, while the next are asked for: nothing jumps.
        // The last text's fuller lists too, until this text's answer (1.30.6).
        let dim = item.isTitle && (search.phase == .loading || results.stale.contains(item.id))
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

    /// Offline, IMDb out of reach, or nothing found: said in a row where the
    /// titles would be. Nothing found waits for the fuller lists (1.30.5:
    /// the Search tab asks them as you type), and gives way to the hint
    /// (`hinted`), which says it already.
    @ViewBuilder
    private func titleProblem(hinted: Bool) -> some View {
        switch search.phase {
        case .failed(let offline):
            statusRow(offline ? "You're offline." : "Couldn't reach IMDb.",
                      detail: offline ? "Search works again once you're connected." : "Check the connection and try again.",
                      icon: offline ? "wifi.slash" : "exclamationmark.triangle", retry: true)
        // Not while the fuller lists' pause runs either (1.30.6): with the suggestions
        // from the cache, "No titles match" showed for a frame before they were asked.
        case .done where search.titlesQuery == typed && !search.fullerBusy && !hinted:
            if results.titles.isEmpty {
                statusRow(kids.isOn ? "No titles rated for the kids profile match “\(typed)”." : "No titles match “\(typed)”.",
                          detail: nil, icon: "magnifyingglass", retry: false)
            } else if let filter, results.filtered(filter).isEmpty {
                // Titles, none of the chosen kind (1.30.5).
                let kind = filter.title.lowercased()
                statusRow(kids.isOn ? "No \(kind) rated for the kids profile match “\(typed)”." : "No \(kind) match “\(typed)”.",
                          detail: nil, icon: "magnifyingglass", retry: false)
            }
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
                    Button("Try Again") {
                        search.retry()
                        // A fuller list not read is asked again too (1.30.5).
                        if tab == .search { search.loadBothKinds(for: query, wait: false) }
                    }
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

/// The tabs and pills over the results (1.30.6), in the list's column. On
/// iOS 26 the scroll view's own bar (safeAreaBar): the rows passing under
/// it fade and blur as under the navigation bar, and the pills' tracks are
/// glass. Before iOS 26 an inset on the page's colour, which the rows go
/// under. Until 1.30.6 they were the list's first rows and scrolled away.
private struct SearchBarsPinned<Bars: View>: ViewModifier {
    let shown: Bool
    @ViewBuilder let bars: () -> Bars
    /// The list's side inset on a wide iPad window (ReadableListWidth's).
    @State private var column: CGFloat = 0
    /// A plain list row's own side margin, which its content starts at.
    static var rowMargin: CGFloat { 16 }

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            // A hard edge under the bars: with the soft one, the rows
            // scrolled under them still showed through around the pills
            // ("2015 · Movie" beside Shows, a poster behind Library).
            content.scrollEdgeEffectStyle(shown ? .hard : .automatic, for: .top)
                .safeAreaBar(edge: .top, spacing: 0) {
                    if shown { GlassEffectContainer(spacing: 4) { placed } }
                }
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) { if shown { placed.background { Theme.background } } }
        }
        #else
        content.safeAreaInset(edge: .top, spacing: 0) { if shown { placed.background { Theme.background } } }
        #endif
    }

    private var placed: some View {
        bars()
            .padding(.horizontal, column + Self.rowMargin)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                let next = PageLayout(width: width).readableListInset ?? 0
                if next != column { column = next }
            }
    }
}

/// The one quiet line under the tabs.
private struct SearchStatusLine: View {
    let text: String
    let working: Bool
    static let minHeight: CGFloat = 22

    var body: some View {
        HStack(spacing: 8) {
            if working { FolioSpinner(size: .small) }
            Text(text).font(.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        // The row as tall as before the list's 0 pt rows (1.30.6).
        .frame(minHeight: Self.minHeight)
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
