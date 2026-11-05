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
    @ObservedObject private var mediaServers = MediaServerStore.shared
    @StateObject private var catalogs = CatalogSearch()
    @AppStorage(SettingsKey.cleanTitles) private var cleanTitles = true
    /// Files or posters for what's on the servers (1.23.0), kept between searches.
    @AppStorage(SettingsKey.searchServerLayout) private var serverLayout = ServerLayout.files
    @State private var route: LibraryRoute?
    @State private var opened: OpenedEntry?
    /// The library's titles, grouped once (not at every keystroke).
    @State private var groups: [LibraryGroup] = []

    /// How the files found on the servers show: a row each, or a poster for
    /// each release they're in.
    enum ServerLayout: String, CaseIterable, Identifiable {
        case files, posters
        var id: String { rawValue }
        var title: String { self == .files ? "Files" : "Posters" }
        var icon: String { self == .files ? "list.bullet" : "square.grid.2x2" }
    }

    /// A Plex or Jellyfin show or season, opened in its server's browser.
    private struct OpenedEntry: Hashable {
        let server: UUID
        let entry: CatalogEntry
        static func == (a: Self, b: Self) -> Bool { a.server == b.server && a.entry.id == b.entry.id }
        func hash(into h: inout Hasher) { h.combine(server); h.combine(entry.id) }
    }

    /// The typed words, two letters at least.
    private var words: [String] { LibrarySearchText.words(query) }

    var body: some View {
        let words = self.words
        let library = libraryMatches(words)
        let files = serverMatches(words)
        let indexing = self.indexing
        let found = !library.isEmpty || !files.isEmpty || catalogs.results.contains { !$0.entries.isEmpty || $0.error != nil }
        let working = !indexing.isEmpty || catalogs.searching
        Group {
            if words.isEmpty {
                ScrollView { SearchIntro(sources: sources).padding(.top, 36) }
                    .scrollDismissesKeyboard(.immediately)
            } else if !found && !working {
                ScrollView {
                    SearchNothing(query: query.trimmingCharacters(in: .whitespacesAndNewlines), sources: sources)
                        .padding(.top, 36)
                }
                .scrollDismissesKeyboard(.immediately)
            } else {
                List {
                    if !library.isEmpty { librarySection(library) }
                    if !files.isEmpty { serverSection(files) }
                    ForEach(indexing, id: \.id) { server in
                        let st = index.state(server.id)
                        FolioWorkingRow(text: "Indexing \(server.name)… \(st.done) of \(st.total) folders")
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(catalogs.results) { r in catalogSection(r) }
                    if catalogs.searching {
                        FolioWorkingRow(text: "Searching Plex and Jellyfin…")
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.immediately)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: query) { _, q in catalogs.textChanged(kids.isOn ? "" : q) }
        // Each server's index brought up to date when it's due, as the
        // server's "Search all files" page did until 1.22.5.
        .onAppear {
            HitchProbe.mark("search", "page appeared")
            if !kids.isOn { for server in webdav.servers { index.refreshIfNeeded(server) } }
            // Text kept from the last search asks Plex and Jellyfin again.
            catalogs.textChanged(kids.isOn ? "" : query)
            groups = LibraryOrganizer.groups(local.files)
            HitchProbe.mark("search", "page set up")
        }
        .onChange(of: local.files) { _, files in groups = LibraryOrganizer.groups(files) }
        .navigationDestination(item: $route) { r in LibraryRoute.destination(r) }
        .navigationDestination(item: $opened) { o in
            if let source = CatalogSearch.source(for: o.server) {
                CatalogBrowserView(source: source, parent: o.entry, title: CatalogTitles.rowTitle(o.entry))
            }
        }
    }

    /// What the search looks through, for the page before typing and the
    /// one with nothing found: the library, then each server by name.
    private var sources: [SearchSource] {
        var out = [SearchSource(name: "Library", icon: "play.rectangle.fill")]
        guard !kids.isOn else { return out }
        out += webdav.servers.map { SearchSource(name: $0.name, icon: RealDebrid.isRealDebrid($0) ? "bolt.horizontal.circle.fill" : "externaldrive.fill") }
        out += mediaServers.servers.filter { $0.kind != .smb }.map { SearchSource(name: $0.displayName, icon: $0.kind.icon) }
        return out
    }

    // MARK: The library

    /// Library titles whose name has every word: the kids profile's titles
    /// only, as Home shows them.
    private func libraryMatches(_ words: [String]) -> [LibraryGroup] {
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
        } header: { SearchHeader(title: "In your library") }
    }

    // MARK: WebDAV and Real-Debrid

    /// Each server's indexed files whose name has every word, at most 40
    /// a server. Not in the kids profile.
    private func serverMatches(_ words: [String]) -> [ServerFile] {
        guard !words.isEmpty, !kids.isOn else { return [] }
        return webdav.servers.flatMap { server in
            index.state(server.id).searchable.lazy
                .filter { s in words.allSatisfy { s.haystack.contains($0) } }
                .prefix(40)
                .map { ServerFile(server: server, file: $0.file) }
        }
    }

    /// Servers whose index is being built or checked right now.
    private var indexing: [WebDAVServer] {
        kids.isOn ? [] : webdav.servers.filter { index.state($0.id).refreshing }
    }

    private func serverSection(_ files: [ServerFile]) -> some View {
        Section {
            switch serverLayout {
            case .files:
                ForEach(files) { f in fileRow(f) }
            case .posters:
                posterGrid(ServerFile.releases(files))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 12, trailing: 20))
            }
        } header: {
            HStack(spacing: 10) {
                SearchHeader(title: "On your servers")
                Spacer(minLength: 8)
                LayoutPill(selection: $serverLayout)
            }
        }
    }

    /// A file: tap to play it (its folder as the queue, as the server's
    /// browser plays it); its server's pill opens the folder it's in.
    private func fileRow(_ f: ServerFile) -> some View {
        let item = f.davItem
        return VStack(alignment: .leading, spacing: 8) {
            Button { play(f) } label: {
                DAVRow(item: item, clean: cleanTitles, entry: HistoryStore.shared.entry(forURL: f.file.url.absoluteString))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("searchFile:" + f.file.name)
            ServerPill(name: f.server.name, icon: RealDebrid.isRealDebrid(f.server) ? "bolt.horizontal.circle.fill" : "externaldrive.fill") {
                route = f.folderRoute
            }
            .padding(.leading, 84)              // under the name, past the picture
            .accessibilityLabel("Open the folder on \(f.server.name)")
            .accessibilityIdentifier("searchFileFolder:" + f.file.name)
        }
        .listRowBackground(Color.clear)
    }

    private func posterGrid(_ releases: [ServerFile.Release]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 132), spacing: 14, alignment: .top)], alignment: .leading, spacing: 18) {
            ForEach(releases) { r in
                Button { open(r) } label: { ReleaseTile(release: r.name) }
                    .buttonStyle(PressStyle(scale: 0.97))
                    .accessibilityLabel(ReleaseTile.spoken(r.name) + (r.count > 1 ? ", \(r.count) files" : ""))
                    .accessibilityIdentifier("searchRelease:" + r.name.title)
            }
        }
    }

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
        } header: { SearchHeader(title: r.server.displayName) }
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

/// The typed words: two letters at least, lowercased, split on spaces.
enum LibrarySearchText {
    static func words(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return q.count >= 2 ? q.split(separator: " ").map(String.init) : []
    }
}

/// A file one of the WebDAV or Real-Debrid servers has, from its index.
struct ServerFile: Identifiable {
    let server: WebDAVServer
    let file: LibraryIndex.File
    var id: String { server.id.uuidString + "|" + file.url.absoluteString }

    var davItem: DAVItem {
        DAVItem(url: file.url, name: file.name, isDirectory: false, size: file.size, modified: file.added, contentType: nil)
    }

    /// The server's start folder.
    var root: URL? { WebDAVClient(server: server).url(forPath: server.rootPath) }

    /// Where the file is, under the start folder: ["Show.S01.1080p", "E01.mkv"].
    static func components(of url: URL, under root: URL?) -> [String] {
        let all = url.standardized.pathComponents.filter { $0 != "/" }
        guard let root else { return [all.last].compactMap { $0 } }
        let base = root.standardized.pathComponents.filter { $0 != "/" }
        guard all.count > base.count, Array(all.prefix(base.count)) == base else { return [all.last].compactMap { $0 } }
        return Array(all.dropFirst(base.count))
    }

    /// The page the server pill opens: the folder the file is in (the
    /// server's library when that's the start folder).
    var folderRoute: LibraryRoute {
        let parts = Self.components(of: file.url, under: root)
        guard parts.count > 1 else { return .webdav(server.id.uuidString) }
        let folder = file.url.deletingLastPathComponent()
        return .webdavFolder(server.id.uuidString, folder.absoluteString, parts[parts.count - 2])
    }

    /// The files found, a poster for each release (the folder at the
    /// server's top they're in, or the file itself when it's there), in the
    /// order found.
    struct Release: Identifiable {
        let server: WebDAVServer
        /// nil: a file at the server's top, which plays.
        let folder: URL?
        let name: ReleaseName
        var files: [ServerFile]
        var count: Int { files.count }
        var id: String { server.id.uuidString + "|" + (folder?.absoluteString ?? files.first?.file.url.absoluteString ?? name.raw) }
    }

    static func releases(_ files: [ServerFile]) -> [Release] {
        var out: [Release] = []
        var at: [String: Int] = [:]
        var roots: [UUID: URL?] = [:]
        for f in files {
            let root: URL?
            if let r = roots[f.server.id] { root = r } else { root = f.root; roots[f.server.id] = root }
            let parts = components(of: f.file.url, under: root)
            let folder: URL?
            let raw: String
            if parts.count > 1, let root {
                folder = root.appendingPathComponent(parts[0], isDirectory: true)
                raw = parts[0]
            } else {
                folder = nil
                raw = f.file.name
            }
            let key = f.server.id.uuidString + "|" + (folder?.absoluteString ?? f.file.url.absoluteString)
            if let i = at[key] { out[i].files.append(f); continue }
            let name = (folder != nil ? ReleaseName.folder(raw) : ReleaseName.file(raw))
                ?? ReleaseName(title: (raw as NSString).deletingPathExtension, label: nil, year: nil, episodeTitle: nil,
                               group: nil, alt: nil, attributes: [], raw: raw)
            at[key] = out.count
            out.append(Release(server: f.server, folder: folder, name: name, files: [f]))
        }
        return out
    }
}

/// A place the search looks, shown as a chip.
struct SearchSource: Hashable {
    let name: String
    let icon: String
}

/// Before anything is typed: what this search finds and where it looks,
/// in Folio's own style (until 1.23.0 a line of grey text between list
/// separators at the top).
private struct SearchIntro: View {
    let sources: [SearchSource]

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Theme.accentSoft).frame(width: 76, height: 76)
                Image(systemName: "magnifyingglass").font(.system(size: 30, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Search what's yours").font(.title3.weight(.bold))
                Text(sources.count > 1 ? "Titles in your library and the files on your servers." : "The titles in your library.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            SourceChips(sources: sources)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("librarySearchIntro")
    }
}

/// Nothing found: said in the same style, with where it looked.
private struct SearchNothing: View {
    let query: String
    let sources: [SearchSource]

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Theme.accentSoft).frame(width: 76, height: 76)
                Image(systemName: "questionmark.text.page").font(.system(size: 28, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Nothing matches “\(query)”").font(.title3.weight(.bold)).multilineTextAlignment(.center)
                Text("Try fewer words, or another spelling. Looked in:")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            SourceChips(sources: sources)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("librarySearchEmpty")
    }
}

private struct SourceChips: View {
    let sources: [SearchSource]

    var body: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(sources, id: \.self) { s in
                Label(s.name, systemImage: s.icon)
                    .labelStyle(ChipLabelStyle())
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary.opacity(0.8))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Theme.fill, in: Capsule())
            }
        }
        .frame(maxWidth: 340)
    }
}

private struct ChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.imageScale(.small)
            configuration.title.lineLimit(1)
        }
    }
}

/// A section's name, in the page's own type (not the list's small caps).
private struct SearchHeader: View {
    let title: String
    var body: some View {
        Text(title).font(.subheadline.weight(.bold)).foregroundStyle(.primary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Files or Posters: two halves of one pill, the chosen one filled.
private struct LayoutPill: View {
    @Binding var selection: LibrarySearchPage.ServerLayout
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(LibrarySearchPage.ServerLayout.allCases) { l in
                let on = selection == l
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = l }
                } label: {
                    Label(l.title, systemImage: l.icon)
                        .labelStyle(ChipLabelStyle())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(on ? Theme.onAccent : .primary.opacity(0.75))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background {
                            if on { Capsule().fill(Theme.accent).matchedGeometryEffect(id: "on", in: ns) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("searchLayout:" + l.rawValue)
            }
        }
        .padding(3)
        .background(Theme.fill, in: Capsule())
        .textCase(nil)
    }
}

/// Which server a file is on, as a button: it opens the folder the file is in.
struct ServerPill: View {
    let name: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).imageScale(.small)
                Text(name).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).opacity(0.6)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary.opacity(0.8))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.fill, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle(scale: 0.95))
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
