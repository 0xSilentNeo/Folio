import SwiftUI

@MainActor
final class ServerStore: ObservableObject {
    static let shared = ServerStore()
    @Published var servers: [WebDAVServer] = [] { didSet { save() } }

    private init() {
        if let data = UserDefaults.standard.data(forKey: "webdavServers"),
           let list = JSONDecoder().decodeLossy(WebDAVServer.self, from: data) {
            servers = list
        }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(servers), forKey: "webdavServers")
    }

    func upsert(_ s: WebDAVServer) {
        if let i = servers.firstIndex(where: { $0.id == s.id }) {
            // Another address, user name or start folder: another library.
            if LibraryIndex.account(servers[i]) != LibraryIndex.account(s) { LibraryIndexStore.shared.clear(s.id) }
            servers[i] = s
        } else {
            servers.append(s)
        }
        LibraryIndexStore.shared.refreshNow(s)
    }

    func remove(_ s: WebDAVServer) {
        s.password = nil
        servers.removeAll { $0.id == s.id }
        LibraryIndexStore.shared.clear(s.id)
        // Its unfinished downloads went on retrying with no login.
        DownloadManager.shared.cancelUnfinished(server: s.id)
    }

    func server(id: UUID) -> WebDAVServer? { servers.first { $0.id == id } }
}

struct ServerEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State var server: WebDAVServer
    @State private var password: String = ""
    @State private var testing = false
    @State private var testResult: String?
    let isNew: Bool

    init(server: WebDAVServer?) {
        _server = State(initialValue: server ?? WebDAVServer(name: "Real-Debrid", baseURL: "https://dav.real-debrid.com/", username: ""))
        _password = State(initialValue: server?.password ?? "")
        isNew = server == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if isNew {
                    Section("Preset") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(WebDAVServer.presets, id: \.name) { p in
                                    Button(p.name) { server.name = p.name; server.baseURL = p.url }
                                        .buttonStyle(.bordered)
                                        .tint(server.baseURL == p.url ? Theme.accent : .gray)
                                }
                                Button("Custom") { server.name = "My Server"; server.baseURL = "https://" }
                                    .buttonStyle(.bordered).tint(.gray)
                            }
                        }
                    }
                }
                Section("Server") {
                    TextField("Name", text: $server.name)
                    TextField("URL (https://host/path)", text: $server.baseURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Start folder", text: $server.rootPath)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    TextField("Username", text: $server.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                } header: { Text("Login") } footer: {
                    if server.baseURL.contains("real-debrid") {
                        Text("Real-Debrid: use your username and the WebDAV password from real-debrid.com/account (not your login password).")
                    }
                }
                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack { Text("Test connection"); Spacer(); if testing { FolioSpinner(size: .small) } }
                    }
                    if let testResult { Text(testResult).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .brandListBackground()
            .navigationTitle(isNew ? "Add WebDAV" : "Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        server.password = password
                        ServerStore.shared.upsert(server)
                        if let host = server.base?.host { Task { _ = await BrandIcon.fetch(host) } }
                        dismiss()
                    }
                    .disabled(server.base == nil)
                }
            }
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        // The typed password, for this test only: it's saved with Save.
        let client = WebDAVClient(server: server, password: password)
        guard let url = client.url(forPath: server.rootPath) else { testResult = "Invalid URL"; return }
        do {
            let items = try await client.list(url)
            testResult = "Connected — \(items.count) item\(items.count == 1 ? "" : "s") in the start folder."
        } catch {
            testResult = error.localizedDescription
        }
    }
}

struct FolderSortPref: Codable, Equatable { var sort: LibrarySort; var ascending: Bool }

/// The browser's order, worked out once per listing (not at every redraw).
///
/// - Folders always come first, in every sort.
/// - Name: the name you see (the clean title of a media file when Clean
///   titles is on), compared the way Finder does — localized and
///   numeric-aware (`localizedStandardCompare`: "Episode 2" before "Episode 10").
/// - Recently Added: `DAVItem.added` (creationdate, else getlastmodified).
///   Folders sort by it too. Items the server gives no date are last, by name.
/// - Size: files by getcontentlength; folders have none (servers don't
///   send it for collections), so they're kept by name, A to Z, whichever
///   way the files go. Files without a size are last, by name.
/// - Ties go by name, A to Z.
enum DAVOrder {
    struct Keyed { let item: DAVItem; let name: String }

    static func keyed(_ items: [DAVItem], clean: Bool) -> [Keyed] {
        items.map { i in
            guard clean else { return Keyed(item: i, name: i.name) }
            if i.isDirectory, let r = ReleaseName.folder(i.name) { return Keyed(item: i, name: r.titleWithYear + (r.label.map { " " + $0 } ?? "")) }
            return Keyed(item: i, name: i.isMedia ? TitleParser.clean(i.name) : i.name)
        }
    }

    static func sorted(_ list: [Keyed], by sort: LibrarySort, ascending: Bool) -> [DAVItem] {
        func byName(_ a: Keyed, _ b: Keyed) -> Bool { a.name.localizedStandardCompare(b.name) == .orderedAscending }
        /// Present values in the chosen direction, missing ones last.
        func compare<T: Comparable>(_ x: T?, _ y: T?, _ a: Keyed, _ b: Keyed) -> Bool {
            switch (x, y) {
            case let (x?, y?) where x != y: return ascending ? x < y : x > y
            case (.some, .none): return true
            case (.none, .some): return false
            default: return byName(a, b)
            }
        }
        return list.sorted { a, b in
            if a.item.isDirectory != b.item.isDirectory { return a.item.isDirectory }
            switch sort {
            case .name:
                let r = a.name.localizedStandardCompare(b.name)
                return r == .orderedSame ? false : (r == .orderedAscending) == ascending
            case .recent:
                return compare(a.item.added, b.item.added, a, b)
            case .size:
                if a.item.isDirectory { return byName(a, b) }
                return compare(a.item.size, b.item.size, a, b)
            }
        }.map(\.item)
    }
}

struct WebDAVBrowserView: View {
    let server: WebDAVServer
    let url: URL
    let title: String

    @ObservedObject private var history = HistoryStore.shared
    @State private var items: [DAVItem] = []
    /// `items` with their sort keys (worked out when the listing or Clean
    /// titles changes), and in the chosen order.
    @State private var keyed: [DAVOrder.Keyed] = []
    @State private var ordered: [DAVItem] = []
    /// What each entry shows under its clean title (worked out with the keys).
    @State private var attributeLines: [URL: [String]] = [:]
    @State private var loading = true
    /// Why the folder couldn't be listed, said in Folio's style (1.23.0).
    @State private var problem: ServerProblem?
    @State private var sort: LibrarySort = .name
    @State private var ascending = true
    @State private var prefLoaded = false
    @AppStorage(SettingsKey.cleanTitles) private var cleanTitles = true
    @AppStorage(SettingsKey.showOnlyMedia) private var onlyMedia = false

    private var client: WebDAVClient { WebDAVClient(server: server) }
    private var sortKey: String { "\(server.id.uuidString)|\(url.path)" }
    /// Downloads from here go into this package (and Media folder).
    private var package: String { DownloadManager.packageName(folder: url, title: title) }

    var body: some View {
        List {
            if let problem {
                ProblemCard(problem: problem, actions: [ProblemCard.Action(title: "Try again", primary: true) { Task { await load() } }])
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(visible) { item in
                if item.isDirectory {
                    NavigationLink {
                        WebDAVBrowserView(server: server, url: item.url, title: cleanTitles ? ReleaseName.folder(item.name)?.title ?? item.name : item.name)
                    } label: {
                        DAVRow(item: item, clean: cleanTitles, entry: nil, attributes: attributeLines[item.url] ?? [])
                    }
                    .accessibilityIdentifier("dav:" + item.name)
                    .contextMenu {
                        // The original name stays at hand.
                        Button { UIPasteboard.general.string = item.name } label: { Label("Copy original name", systemImage: "doc.on.doc") }
                        Text(item.name)
                    }
                } else {
                    HStack(spacing: 6) {
                        Button { open(item) } label: {
                            DAVRow(item: item, clean: cleanTitles, entry: history.entry(forURL: item.url.absoluteString), attributes: attributeLines[item.url] ?? [])
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        if item.isMedia {
                            DownloadButton(item: item, server: server, package: package, siblings: items)
                        }
                    }
                    .accessibilityIdentifier("dav:" + item.name)
                    .contextMenu {
                        if item.isMedia { Button { open(item) } label: { Label("Play", systemImage: "play") } }
                        Button { UIPasteboard.general.string = item.url.absoluteString } label: { Label("Copy link", systemImage: "link") }
                        if item.isMedia {
                            WatchedMenuItems(keys: [item.url.absoluteString]) { _ in client.mediaItem(for: item, cleanTitles: cleanTitles) }
                        }
                        if let e = history.entry(forURL: item.url.absoluteString), e.canResume {
                            Button(role: .destructive) { history.remove(e) } label: { Label("Clear progress", systemImage: "arrow.uturn.backward") }
                        }
                        Text(item.name)
                    }
                }
            }
            if !loading && visible.isEmpty && problem == nil {
                ContentUnavailableView("Empty Folder", systemImage: "folder")
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .overlay { if loading && items.isEmpty { FolioSpinner(size: .large) } }
        .brandListBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // No search bar of its own (1.22.5): the tab bar's search button,
        // opened from Home or Network, searches every server's files.
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                LibrarySortMenu(sort: $sort, ascending: $ascending, inToolbar: true)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // Menus show a toggle as a checkmark item only in the
                    // automatic style; the app-wide switch style
                    // (FolioApp, BrandSwitchStyle) left them disabled in
                    // menus (1.18.0 UI test: enabled=false).
                    Group {
                        Toggle("Clean titles", isOn: $cleanTitles)
                        Toggle("Only media files", isOn: $onlyMedia)
                    }
                    .toggleStyle(.automatic)
                    let media = visible.filter(\.isMedia)
                    if !media.isEmpty {
                        Divider()
                        Button {
                            DownloadManager.shared.enqueue(media + items.filter(\.isSubtitle), server: server, package: package)
                        } label: { Label("Download all \(media.count) videos", systemImage: "arrow.down.circle") }
                    }
                } label: { ToolbarGlyph("ellipsis.circle") }
                .accessibilityLabel("More")
                .accessibilityIdentifier("davMoreMenu")
            }
        }
        .task {
            loadSortPref()
            if items.isEmpty { await load() }
        }
        .onChange(of: sort) { _, _ in saveSortPref(); reorder() }
        .onChange(of: ascending) { _, _ in saveSortPref(); reorder() }
        .onChange(of: cleanTitles) { _, _ in rekey() }
    }

    /// The listing in order, then "Only media" (cheap; the sort is done).
    private var visible: [DAVItem] {
        var list = ordered
        if onlyMedia { list = list.filter { $0.isDirectory || $0.isMedia } }
        return list
    }

    private func rekey() {
        keyed = DAVOrder.keyed(items, clean: cleanTitles)
        attributeLines = DAVRow.attributeLines(items, clean: cleanTitles)
        reorder()
    }

    private func reorder() {
        ordered = DAVOrder.sorted(keyed, by: sort, ascending: ascending)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            items = try await client.list(url)
            rekey()
            problem = nil
        } catch {
            // Offline, a removed release, a refused login: said plainly (Home's
            // Real-Debrid section stays while offline and opens here).
            let p = ServerProblem.classify(status: nil, error: error, server: server.name,
                                           realDebrid: RealDebrid.isRealDebrid(server), folder: true)
            problem = p
            dlog("webdav", "folder not listed (\(server.name)): \(p.title)")
            // A release Real-Debrid removed leaves Home's row and the search.
            if p.kind == .gone { LibraryIndexStore.shared.refreshNow(server) }
        }
    }

    private func open(_ item: DAVItem) {
        guard item.isMedia else {
            if item.isSubtitle { return }
            // Unknown extension: let mpv try anyway.
            PlayerPresenter.play(client.mediaItem(for: item, cleanTitles: cleanTitles))
            return
        }
        let media = visible.filter(\.isMedia)
        let subs = items.filter(\.isSubtitle)
        let queue: [MediaItem] = media.map { m in
            var mi = client.mediaItem(for: m, cleanTitles: cleanTitles)
            mi.subtitles = subs.filter { SubtitleMatch.belongs($0.name, to: m.name) }.map {
                ExternalSubtitle(url: $0.url.absoluteString, lang: nil, title: $0.name)
            }
            return mi
        }
        let index = media.firstIndex(of: item) ?? 0
        PlayerPresenter.play(queue: queue, index: index)
    }

    /// This folder's own choice, else the last one made in any folder.
    private func loadSortPref() {
        guard !prefLoaded else { return }
        prefLoaded = true
        let own = (UserDefaults.standard.dictionary(forKey: SettingsKey.folderSorts)?[sortKey] as? Data)
            ?? UserDefaults.standard.data(forKey: SettingsKey.folderSortLast)
        guard let data = own, let pref = try? JSONDecoder().decode(FolderSortPref.self, from: data) else { return }
        shownPref = pref
        sort = pref.sort
        ascending = pref.ascending
    }

    /// The order the folder opened with. Only a different one is saved as the
    /// folder's own: until 1.20.3 opening a folder saved the inherited order
    /// for it, so every folder visited kept an entry and later changes made
    /// elsewhere no longer reached it (review, 2 Nov).
    @State private var shownPref: FolderSortPref?

    private func saveSortPref() {
        let pref = FolderSortPref(sort: sort, ascending: ascending)
        guard prefLoaded, pref != shownPref, let data = try? JSONEncoder().encode(pref) else { return }
        shownPref = pref
        var dict = UserDefaults.standard.dictionary(forKey: SettingsKey.folderSorts) ?? [:]
        dict[sortKey] = data
        UserDefaults.standard.set(dict, forKey: SettingsKey.folderSorts)
        UserDefaults.standard.set(data, forKey: SettingsKey.folderSortLast)
    }
}

struct DAVRow: View {
    let item: DAVItem
    let clean: Bool
    let entry: HistoryEntry?
    /// With Clean titles: what tells this entry apart from the others shown
    /// with it (ReleaseName.distinguishing) — resolution, source, HDR, group…
    var attributes: [String] = []
    @StateObject private var thumb = ThumbLoader()

    /// A release folder read with the WebDAV browser script's rules
    /// (ReleaseName.folder); nil for folders like "torrents" or "Season 1".
    private var release: ReleaseName? { clean && item.isDirectory ? ReleaseName.folder(item.name) : nil }
    /// A media file read the same way (its episode title from the name).
    private var fileRelease: ReleaseName? { clean && item.isMedia ? ReleaseName.file(item.name) : nil }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let release {
                    ReleasePoster(release: release, width: 40)
                } else {
                    ZStack {
                        if item.isMedia, let img = thumb.image ?? ThumbLoader.cached(key: item.url.absoluteString, points: 72) {
                            Image(uiImage: img).resizable().scaledToFill()
                                .frame(width: 72, height: 42)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            RoundedRectangle(cornerRadius: 10).fill(item.isDirectory ? Theme.accentSoft : Theme.card)
                                .frame(width: item.isMedia ? 72 : 40, height: item.isMedia ? 42 : 40)
                            Image(systemName: icon).foregroundStyle(item.isDirectory ? Theme.accent : .primary.opacity(0.8))
                        }
                    }
                    .frame(width: item.isMedia ? 72 : 40, height: item.isMedia ? 42 : 40)
                }
            }
            .onAppear { if item.isMedia && clean { thumb.load(key: item.url.absoluteString, fileURL: nil, artwork: nil, lookupName: item.name, points: 72) } }
            VStack(alignment: .leading, spacing: 3) {
                label.font(.subheadline.weight(.medium)).lineLimit(2)
                let details = ([release?.label, release?.year].compactMap { $0 } + attributes)
                if !details.isEmpty {
                    Text(details.joined(separator: " · ")).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    if let size = item.size, !item.isDirectory { Text(size.byteString) }
                    if let d = item.added { Text(d, format: .dateTime.day().month().year()) }
                    if let entry, entry.isFinished {
                        Label("Watched", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                    } else if let entry, entry.canResume {
                        Text("\(PlayerModel.format(entry.position)) / \(PlayerModel.format(entry.duration))").foregroundStyle(Theme.accent)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let entry, entry.canResume {
                    ProgressView(value: entry.progress).tint(Theme.accent).scaleEffect(x: 1, y: 0.6)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// "S2 · E1  Beast Titan", "OAD 5  Attack on Titan", "Movie 1  Guren no Yumiya".
    /// The episode number always shows (1.14.1 dropped it, and files past
    /// season 1 showed only the show's name). A release folder: its clean title.
    private var label: Text {
        if let release { return Text(release.title) }
        guard item.isMedia, clean else { return Text(displayName) }
        let p = TitleParser.parse(item.name)
        let m = thumb.meta
        let tag = TitleParser.tag(p, season: m?.episodeSeason, episode: m?.episodeNumber)
        let rest: String
        if p.extra == "Movie" { rest = p.subtitle ?? m?.name ?? p.title }
        else if let t = m?.episodeTitle ?? fileRelease?.episodeTitle { rest = t }
        else { rest = m?.name ?? fileRelease?.title ?? p.title }
        guard let tag else { return Text(m?.name ?? displayName) }
        return Text("\(Text(tag).fontWeight(.bold))  \(rest)")
    }

    private var displayName: String {
        guard clean, !item.isDirectory, item.isMedia else { return item.name }
        return fileRelease?.titleWithYear ?? TitleParser.clean(item.name)
    }

    private var icon: String {
        if item.isDirectory { return "folder.fill" }
        if item.isMedia {
            let ext = (item.name as NSString).pathExtension.lowercased()
            return ["mp3", "flac", "m4a", "aac", "ogg", "opus", "wav", "alac"].contains(ext) ? "music.note" : "film"
        }
        if item.isSubtitle { return "captions.bubble" }
        return "doc"
    }

    /// With Clean titles on: what to show under each entry so none look the
    /// same. Release folders always show their attributes (resolution,
    /// source, HDR, DV, group, then more when two would still look alike);
    /// files only when two would show the same title.
    static func attributeLines(_ items: [DAVItem], clean: Bool) -> [URL: [String]] {
        guard clean else { return [:] }
        var out: [URL: [String]] = [:]
        let folders = items.compactMap { i in i.isDirectory ? ReleaseName.folder(i.name).map { (i.url, $0) } : nil }
        for (k, v) in zip(folders.map(\.0), ReleaseName.distinguishing(folders.map(\.1))) { out[k] = v }
        let files = items.compactMap { i in i.isMedia ? ReleaseName.file(i.name).map { (i.url, $0) } : nil }
        let alike = Dictionary(grouping: files) { [$0.1.title, $0.1.label ?? "", $0.1.year ?? ""].joined(separator: "|").lowercased() }
        for group in alike.values where group.count > 1 {
            for (k, v) in zip(group.map(\.0), ReleaseName.distinguishing(group.map(\.1))) { out[k] = v }
        }
        return out
    }
}

