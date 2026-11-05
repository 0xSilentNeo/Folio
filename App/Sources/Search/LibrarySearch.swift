import SwiftUI

/// Home's search (1.22.5): what the tab bar's search button finds when it's
/// opened from Home or Network. Only what's yours, in this order: the
/// library's titles, the files on each WebDAV or Real-Debrid server (from
/// its index, what a server's "Search all files" used), and what each Plex
/// and Jellyfin server finds. Titles on IMDb and the addons are Discover's
/// search. The kids profile sees its library titles only: the servers are
/// locked there.
struct LibrarySearchPage: View {
    @Binding var query: String

    @ObservedObject private var kids = KidsProfile.shared
    @ObservedObject private var local = LocalMediaStore.shared
    @ObservedObject private var index = LibraryIndexStore.shared
    @ObservedObject private var webdav = ServerStore.shared
    @StateObject private var catalogs = CatalogSearch()
    @AppStorage(SettingsKey.cleanTitles) private var cleanTitles = true
    @State private var route: LibraryRoute?
    @State private var opened: OpenedEntry?
    /// The library's titles, grouped once (not at every keystroke).
    @State private var groups: [LibraryGroup] = []

    /// A Plex or Jellyfin show or season, opened in its server's browser.
    private struct OpenedEntry: Hashable {
        let server: UUID
        let entry: CatalogEntry
        static func == (a: Self, b: Self) -> Bool { a.server == b.server && a.entry.id == b.entry.id }
        func hash(into h: inout Hasher) { h.combine(server); h.combine(entry.id) }
    }

    /// The typed words, two letters at least.
    private var words: [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return q.count >= 2 ? q.split(separator: " ").map(String.init) : []
    }

    var body: some View {
        let library = libraryMatches
        let files = serverMatches
        List {
            if words.isEmpty {
                Text(kids.isOn ? "Search your library." : "Search your library, your Real-Debrid and WebDAV servers, and Plex and Jellyfin.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            } else {
                if !library.isEmpty { librarySection(library) }
                ForEach(files, id: \.server.id) { group in serverSection(group.server, group.files) }
                ForEach(indexing, id: \.id) { server in
                    let st = index.state(server.id)
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Indexing \(server.name)… \(st.done) of \(st.total) folders").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(catalogs.results) { r in catalogSection(r) }
                if catalogs.searching {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Searching Plex and Jellyfin…").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                }
                if library.isEmpty && files.isEmpty && catalogs.results.allSatisfy(\.entries.isEmpty) && !catalogs.searching {
                    Text("Nothing in your library\(kids.isOn ? "" : " or on your servers") matches “\(query.trimmingCharacters(in: .whitespaces))”.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("librarySearchEmpty")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: query) { _, q in catalogs.textChanged(kids.isOn ? "" : q) }
        // Each server's index brought up to date when it's due, as the
        // server's "Search all files" page did until 1.22.5.
        .onAppear {
            if !kids.isOn { for server in webdav.servers { index.refreshIfNeeded(server) } }
            // Text kept from the last search asks Plex and Jellyfin again.
            catalogs.textChanged(kids.isOn ? "" : query)
            groups = LibraryOrganizer.groups(local.files)
        }
        .onChange(of: local.files) { _, files in groups = LibraryOrganizer.groups(files) }
        .navigationDestination(item: $route) { r in LibraryRoute.destination(r) }
        .navigationDestination(item: $opened) { o in
            if let source = CatalogSearch.source(for: o.server) {
                CatalogBrowserView(source: source, parent: o.entry, title: CatalogTitles.rowTitle(o.entry))
            }
        }
    }

    // MARK: The library

    /// Library titles whose name has every word: the kids profile's titles
    /// only, as Home shows them.
    private var libraryMatches: [LibraryGroup] {
        let words = self.words
        guard !words.isEmpty else { return [] }
        var groups = self.groups
        if let limits = kids.activeLimits { groups = groups.filter { LibraryMetaIndex.shared.kidsAllow($0, limits) } }
        return Array(groups.lazy.filter { g in
            let name = (g.title + " " + (g.files.first.map { $0.deletingPathExtension().lastPathComponent } ?? "")).lowercased()
            return words.allSatisfy { name.contains($0) }
        }.prefix(20))
    }

    private func librarySection(_ groups: [LibraryGroup]) -> some View {
        Section {
            ForEach(groups) { g in
                Button { route = .group(g.id) } label: {
                    row(icon: g.isSeries ? "tv" : "film", title: g.title,
                        detail: g.isSeries ? "\(g.count) episode\(g.count == 1 ? "" : "s")" : "Film")
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("searchLibrary:" + g.title)
            }
        } header: { Text("In your library") }
    }

    // MARK: WebDAV and Real-Debrid

    /// Each server's indexed files whose name has every word, at most 40
    /// a server. Not in the kids profile.
    private var serverMatches: [(server: WebDAVServer, files: [LibraryIndex.File])] {
        let words = self.words
        guard !words.isEmpty, !kids.isOn else { return [] }
        return webdav.servers.compactMap { server in
            let files = index.state(server.id).searchable.lazy
                .filter { s in words.allSatisfy { s.haystack.contains($0) } }
                .prefix(40).map(\.file)
            return files.isEmpty ? nil : (server, Array(files))
        }
    }

    /// Servers whose index is being built or checked right now.
    private var indexing: [WebDAVServer] {
        kids.isOn ? [] : webdav.servers.filter { index.state($0.id).refreshing }
    }

    private func serverSection(_ server: WebDAVServer, _ files: [LibraryIndex.File]) -> some View {
        Section {
            ForEach(files, id: \.url) { file in
                let item = DAVItem(url: file.url, name: file.name, isDirectory: false, size: file.size, modified: file.added, contentType: nil)
                Button {
                    // With its folder as the queue, as the server's browser plays it.
                    ContinueQueue.play(WebDAVClient(server: server).mediaItem(for: item, cleanTitles: cleanTitles))
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        DAVRow(item: item, clean: cleanTitles, entry: HistoryStore.shared.entry(forURL: file.url.absoluteString))
                        Text(file.url.deletingLastPathComponent().path.removingPercentEncoding ?? "")
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
            }
        } header: { Text(server.name) }
    }

    // MARK: Plex and Jellyfin

    private func catalogSection(_ r: CatalogSearch.Result) -> some View {
        Section {
            if let error = r.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange)
                    .listRowBackground(Color.clear)
            }
            ForEach(r.entries) { e in
                Button {
                    if e.isPlayable {
                        guard let source = CatalogSearch.source(for: r.server.id) else { return }
                        PlayerPresenter.play(queue: [source.mediaItem(for: e, parent: nil)], index: 0)
                    } else {
                        opened = OpenedEntry(server: r.server.id, entry: e)
                    }
                } label: {
                    row(icon: icon(e), title: CatalogTitles.rowTitle(e), detail: detail(e))
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("searchCatalog:" + e.name)
            }
        } header: { Text(r.server.displayName) }
    }

    private func icon(_ e: CatalogEntry) -> String {
        switch e.kind {
        case .series, .season: return "tv"
        case .episode: return "play.rectangle"
        default: return "film"
        }
    }

    private func detail(_ e: CatalogEntry) -> String {
        switch e.kind {
        case .series: return "Show" + (e.year.map { " · \($0)" } ?? "")
        case .season: return e.seriesName ?? "Season"
        case .episode: return [e.seriesName, e.season.map { "S\($0)" }.map { s in e.episode.map { s + "E\($0)" } ?? s }].compactMap { $0 }.joined(separator: " · ")
        default: return "Film" + (e.year.map { " · \($0)" } ?? "")
        }
    }

    private func row(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 28).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).lineLimit(1)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// The Plex and Jellyfin part of Home's search: each signed-in server asked
/// 300 ms after the last change (as Discover's search waits), all at once,
/// the newest question's answers kept.
@MainActor
final class CatalogSearch: ObservableObject {
    struct Result: Identifiable {
        let server: MediaServer
        var entries: [CatalogEntry]
        var error: String?
        var id: UUID { server.id }
    }

    @Published private(set) var results: [Result] = []
    @Published private(set) var searching = false
    private var task: Task<Void, Never>?

    /// The client for a Plex or Jellyfin server that's signed in.
    static func source(for id: UUID) -> (any CatalogSource)? {
        guard let s = MediaServerStore.shared.servers.first(where: { $0.id == id }) else { return nil }
        switch s.kind {
        case .plex: return PlexClient(server: s)
        case .jellyfin: return JellyfinClient(server: s, device: JellyfinAPI.deviceModel)
        case .smb: return nil
        }
    }

    func textChanged(_ text: String) {
        task?.cancel()
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sources = MediaServerStore.shared.servers.compactMap { s in Self.source(for: s.id).map { (s, $0) } }
        guard q.count >= 2, !sources.isEmpty else {
            results = []
            searching = false
            return
        }
        searching = true
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let t0 = CACurrentMediaTime()
            let found = await withTaskGroup(of: (Int, Result).self) { group in
                for (n, (server, source)) in sources.enumerated() {
                    group.addTask {
                        do { return (n, Result(server: server, entries: try await source.search(q))) }
                        catch { return (n, Result(server: server, entries: [], error: ServerError.message(error, server: server.displayName).text)) }
                    }
                }
                var out: [(Int, Result)] = []
                for await r in group { out.append(r) }
                return out.sorted { $0.0 < $1.0 }.map(\.1)
            }
            guard let self, !Task.isCancelled else { return }
            self.results = found.filter { !$0.entries.isEmpty || $0.error != nil }
            self.searching = false
            dlog("search", "Plex/Jellyfin \"\(q)\": " + found.map { "\($0.server.displayName) \($0.error == nil ? "\($0.entries.count)" : "error")" }.joined(separator: ", ")
                 + String(format: " in %.0f ms", (CACurrentMediaTime() - t0) * 1000))
        }
    }
}
