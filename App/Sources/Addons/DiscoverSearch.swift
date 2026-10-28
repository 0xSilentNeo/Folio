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

    /// History entries that contain what's typed (not the same search), newest first.
    func matchingHistory(_ text: String, max: Int = 4) -> [SearchHistoryEntry] {
        let k = SearchHistoryStore.key(text)
        guard !k.isEmpty else { return history }
        return Array(history.filter { $0.id != k && $0.id.contains(k) }.prefix(max))
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
        phase = .loading                 // the last results stay up meanwhile: nothing jumps
        liveTask = Task { [weak self] in
            if wait {
                do { try await Task.sleep(for: Self.debounce) } catch { return }   // the next keystroke came first
            }
            let t0 = CACurrentMediaTime()
            do {
                let items = try await Self.lookUp(q)
                guard let self, gen == self.generation else { return }             // a newer query took over
                self.titles = items
                self.titlesQuery = q
                self.phase = .done
                dlog("search", String(format: "\"%@\": %d title(s) in %.0f ms", q, items.count, (CACurrentMediaTime() - t0) * 1000))
            } catch {
                guard let self, gen == self.generation, !IMDbSource.isCancellation(error) else { return }
                let offline = Self.isOffline(error)
                self.phase = .failed(offline: offline)
                dlog("search/error", "\"\(q)\": \(error.localizedDescription)\(offline ? " (offline)" : "")")
            }
        }
    }

    /// Lab (`-labSearchOffline`): every search fails as it does without a connection.
    private static func lookUp(_ q: String) async throws -> [MetaItem] {
        if CommandLine.arguments.contains("-labSearchOffline") { throw URLError(.notConnectedToInternet) }
        return try await IMDbSource.suggest(q)
    }

    static func isOffline(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff, .cannotFindHost, .cannotConnectToHost].contains(code)
    }

    private func searchAddons(_ q: String) {
        addonTask?.cancel()
        addonResults = []
        addonQuery = q
        let targets = AddonStore.shared.addons.flatMap { a in a.manifest.catalogs.filter(\.supportsSearch).map { (a, $0) } }
        guard !targets.isEmpty else { addonsSearching = false; return }
        addonsSearching = true
        addonTask = Task { [weak self] in
            await withTaskGroup(of: AddonSearchView.SearchResult?.self) { group in
                for (a, c) in targets {
                    group.addTask {
                        let metas = (try? await AddonAPI.catalog(a, c, extra: ["search": q])) ?? []
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

/// Discover → the magnifying glass.
struct AddonSearchView: View {
    struct SearchResult: Identifiable { let id: String; let title: String; let addon: InstalledAddon?; let metas: [MetaItem] }
    /// A title opened from the search (and the addon that found it, if any).
    private struct Opened: Hashable { let meta: MetaItem; let addon: InstalledAddon? }

    @StateObject private var search = DiscoverSearch()
    @State private var query = ""
    @State private var fieldActive = false
    @State private var opened: Opened?
    @State private var confirmClear = false
    @State private var focusedOnce = false

    private var typed: String { SearchHistoryStore.tidy(query) }

    var body: some View {
        List {
            if typed.isEmpty {
                recent
            } else {
                let matches = search.matchingHistory(query)
                if !matches.isEmpty {
                    Section { ForEach(matches) { historyRow($0) } }
                }
                titlesSection
                ForEach(search.addonResults) { addonSection($0) }
                if search.addonsSearching {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Searching your addons…").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .listRowBackground(Color.clear)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, isPresented: $fieldActive, placement: .navigationBarDrawer(displayMode: .always), prompt: "Movies, shows, anime")
        .onChange(of: query) { _, text in search.textChanged(text) }
        .onSubmit(of: .search) { search.submit(query) }
        .task {
            await search.loadHistory()
            // The keyboard comes up the first time (you came here to type),
            // not again on coming back from a title.
            if !focusedOnce { focusedOnce = true; fieldActive = true }
        }
        .navigationDestination(item: $opened) { o in
            MetaDetailView(preview: o.meta, sourceAddon: o.addon).zoomDestination("search|" + o.meta.id, in: zoomNS, zoom: false)
        }
        .confirmationDialog("Clear recent searches?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { search.clearHistory() }
        }
    }
    @Namespace private var zoomNS

    // MARK: Recent

    @ViewBuilder
    private var recent: some View {
        if !search.history.isEmpty {
            Section {
                ForEach(search.history) { historyRow($0) }
            } header: {
                HStack {
                    Text("Recent")
                    Spacer()
                    Button("Clear") { confirmClear = true }
                        .font(.subheadline.weight(.semibold))
                        .accessibilityLabel("Clear recent searches")
                }
            }
        }
    }

    private func historyRow(_ entry: SearchHistoryEntry) -> some View {
        Button {
            query = entry.query
            search.submit(entry.query)
        } label: {
            Label {
                Text(entry.query).foregroundStyle(.primary).lineLimit(1)
            } icon: {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
            }
        }
        .listRowBackground(Color.clear)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { search.delete(entry) } label: { Label("Delete", systemImage: "trash") }
        }
        .accessibilityLabel("Recent search, \(entry.query)")
        .accessibilityHint("Searches again")
        .accessibilityAction(named: "Delete") { search.delete(entry) }
    }

    // MARK: Titles

    @ViewBuilder
    private var titlesSection: some View {
        Section {
            switch search.phase {
            case .failed(let offline):
                statusRow(offline ? "You're offline." : "Couldn't reach IMDb.",
                          detail: offline ? "Search works again once you're connected." : "Check the connection and try again.",
                          icon: offline ? "wifi.slash" : "exclamationmark.triangle", retry: true)
            case .done where search.titles.isEmpty && search.titlesQuery == typed:
                statusRow("No titles match “\(typed)”.", detail: nil, icon: "magnifyingglass", retry: false)
            case .idle where typed.count < DiscoverSearch.minLength:
                statusRow("Keep typing to search titles.", detail: nil, icon: "character.cursor.ibeam", retry: false)
            default:
                EmptyView()
            }
            ForEach(search.titles) { m in
                titleRow(m)
            }
        } header: {
            HStack(spacing: 8) {
                Text("Titles")
                if search.phase == .loading {
                    ProgressView().controlSize(.small).accessibilityLabel("Searching")
                }
                Spacer()
            }
            .frame(minHeight: 22)            // the spinner never changes the header's height
        }
    }

    private func titleRow(_ m: MetaItem) -> some View {
        Button {
            search.opened(from: search.titlesQuery.isEmpty ? query : search.titlesQuery)
            opened = Opened(meta: m, addon: nil)
        } label: {
            HStack(spacing: 12) {
                PosterImage(url: m.poster, cornerRadius: 8)
                    .frame(width: 46)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.name).font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                    Text(subtitle(m)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    if let cast = m.description, !cast.isEmpty {
                        Text(cast).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .opacity(search.phase == .loading ? 0.55 : 1)
        .animation(.easeOut(duration: 0.15), value: search.phase == .loading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func subtitle(_ m: MetaItem) -> String {
        [m.releaseInfo, m.type == "series" ? "Series" : "Movie"].compactMap { $0 }.joined(separator: " · ")
    }

    private func statusRow(_ title: String, detail: String?, icon: String, retry: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(.secondary).frame(width: 46).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.body.weight(.medium))
                if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
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

    // MARK: Addons (after Search)

    private func addonSection(_ r: SearchResult) -> some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(r.metas) { m in
                        Button {
                            search.opened(from: query)
                            opened = Opened(meta: m, addon: r.addon)
                        } label: { PosterCard(meta: m) }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } header: {
            Text(r.title).lineLimit(1)
        }
    }
}
