import SwiftUI

@MainActor
final class ServerStore: ObservableObject {
    static let shared = ServerStore()
    @Published var servers: [WebDAVServer] = [] { didSet { save() } }

    private init() {
        if let data = UserDefaults.standard.data(forKey: "webdavServers"),
           let list = try? JSONDecoder().decode([WebDAVServer].self, from: data) {
            servers = list
        }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(servers), forKey: "webdavServers")
    }

    func upsert(_ s: WebDAVServer) {
        if let i = servers.firstIndex(where: { $0.id == s.id }) { servers[i] = s } else { servers.append(s) }
    }

    func remove(_ s: WebDAVServer) {
        s.password = nil
        servers.removeAll { $0.id == s.id }
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
                        HStack { Text("Test connection"); Spacer(); if testing { ProgressView() } }
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
        server.password = password
        let client = WebDAVClient(server: server)
        guard let url = client.url(forPath: server.rootPath) else { testResult = "Invalid URL"; return }
        do {
            let items = try await client.list(url)
            testResult = "Connected — \(items.count) item\(items.count == 1 ? "" : "s") in the start folder."
        } catch {
            testResult = error.localizedDescription
        }
    }
}

/// Folder sort. `recent` keeps the raw value "date" so choices saved before
/// 1.18.1 still read back.
enum DAVSort: String, CaseIterable, Codable {
    case recent = "date", name, size
    var label: String {
        switch self {
        case .recent: return "Recently Added"
        case .name: return "Name"
        case .size: return "Size"
        }
    }
    /// The direction a sort starts in when you pick it: newest and largest
    /// first, names A to Z.
    var startsAscending: Bool { self == .name }
}

struct FolderSortPref: Codable { var sort: DAVSort; var ascending: Bool }

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
        items.map { Keyed(item: $0, name: clean && $0.isMedia ? TitleParser.clean($0.name) : $0.name) }
    }

    static func sorted(_ list: [Keyed], by sort: DAVSort, ascending: Bool) -> [DAVItem] {
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
    @State private var loading = true
    @State private var error: String?
    @State private var filter = ""
    @State private var sort: DAVSort = .name
    @State private var ascending = true
    @State private var prefLoaded = false
    @AppStorage(SettingsKey.cleanTitles) private var cleanTitles = true
    @AppStorage(SettingsKey.showOnlyMedia) private var onlyMedia = false

    private var client: WebDAVClient { WebDAVClient(server: server) }
    private var sortKey: String { "\(server.id.uuidString)|\(url.path)" }

    var body: some View {
        List {
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("Retry") { Task { await load() } }
                }
            }
            ForEach(visible) { item in
                if item.isDirectory {
                    NavigationLink {
                        WebDAVBrowserView(server: server, url: item.url, title: item.name)
                    } label: {
                        DAVRow(item: item, clean: cleanTitles, entry: nil)
                    }
                    .accessibilityIdentifier("dav:" + item.name)
                } else {
                    HStack(spacing: 6) {
                        Button { open(item) } label: {
                            DAVRow(item: item, clean: cleanTitles, entry: history.entry(forURL: item.url.absoluteString))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        if item.isMedia {
                            DownloadButton(item: item, server: server, package: title, siblings: items)
                        }
                    }
                    .accessibilityIdentifier("dav:" + item.name)
                    .contextMenu {
                        if item.isMedia { Button { open(item) } label: { Label("Play", systemImage: "play") } }
                        Button { UIPasteboard.general.string = item.url.absoluteString } label: { Label("Copy link", systemImage: "link") }
                        if let e = history.entry(forURL: item.url.absoluteString) {
                            Button { history.markWatched(e) } label: { Label("Mark as watched", systemImage: "checkmark.circle") }
                            Button(role: .destructive) { history.remove(e) } label: { Label("Clear progress", systemImage: "arrow.uturn.backward") }
                        }
                        Text(item.name)
                    }
                }
            }
            if !loading && visible.isEmpty && error == nil {
                Text(filter.isEmpty ? "Empty folder" : "No matches").foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .overlay { if loading && items.isEmpty { ProgressView() } }
        .brandListBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter, prompt: "Filter this folder")
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Only the three sorts, the current one checked.
                Menu {
                    Picker("Sort by", selection: sortChoice) {
                        ForEach(DAVSort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } label: { ToolbarGlyph("line.3.horizontal.decrease.circle") }
                .accessibilityLabel("Sort by, \(sort.label)")
                .accessibilityIdentifier("davSortMenu")
            }
            ToolbarItem(placement: .topBarTrailing) {
                // Direction: one arrow that turns over, up for ascending.
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { ascending.toggle() }
                } label: {
                    ToolbarGlyph("arrow.up")
                        .rotationEffect(.degrees(ascending ? 0 : 180))
                }
                .accessibilityLabel(ascending ? "Ascending" : "Descending")
                .accessibilityHint("Reverses the order")
                .accessibilityIdentifier("davSortDirection")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // Menus show a toggle as a checkmark item only in the
                    // automatic style; the app-wide switch style
                    // (GlassPlayerApp, BrandSwitchStyle) left them disabled in
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
                            DownloadManager.shared.enqueue(media + items.filter(\.isSubtitle), server: server, package: title)
                        } label: { Label("Download all \(media.count) videos", systemImage: "arrow.down.circle") }
                    }
                } label: { ToolbarGlyph("ellipsis.circle") }
                .accessibilityLabel("More")
                .accessibilityIdentifier("davMoreMenu")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    LibrarySearchView(server: server, root: url)
                } label: { ToolbarGlyph("magnifyingglass.circle") }
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

    /// Picking a sort starts it in its own direction (newest, largest, A to
    /// Z); the arrow then reverses it.
    private var sortChoice: Binding<DAVSort> {
        Binding(get: { sort }, set: { new in
            guard new != sort else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                sort = new
                ascending = new.startsAscending
            }
        })
    }

    /// The listing in order, then the filters (cheap; the sort is done).
    private var visible: [DAVItem] {
        var list = ordered
        if onlyMedia { list = list.filter { $0.isDirectory || $0.isMedia } }
        if !filter.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(filter) || TitleParser.clean($0.name).localizedCaseInsensitiveContains(filter) }
        }
        return list
    }

    private func rekey() {
        keyed = DAVOrder.keyed(items, clean: cleanTitles)
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
            error = nil
        } catch {
            self.error = error.localizedDescription
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
            let base = (m.name as NSString).deletingPathExtension.lowercased()
            mi.subtitles = subs.filter { $0.name.lowercased().hasPrefix(base) }.map {
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
        sort = pref.sort
        ascending = pref.ascending
    }

    private func saveSortPref() {
        guard prefLoaded, let data = try? JSONEncoder().encode(FolderSortPref(sort: sort, ascending: ascending)) else { return }
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
    @StateObject private var thumb = ThumbLoader()

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if item.isMedia, let img = thumb.image {
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
            .onAppear { if item.isMedia && clean { thumb.load(key: item.url.absoluteString, fileURL: nil, artwork: nil, lookupName: item.name) } }
            VStack(alignment: .leading, spacing: 3) {
                label.font(.subheadline.weight(.medium)).lineLimit(2)
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
    /// season 1 showed only the show's name).
    private var label: Text {
        guard item.isMedia, clean else { return Text(displayName) }
        let p = TitleParser.parse(item.name)
        let m = thumb.meta
        let tag = TitleParser.tag(p, season: m?.episodeSeason, episode: m?.episodeNumber)
        let rest: String
        if p.extra == "Movie" { rest = p.subtitle ?? m?.name ?? p.title }
        else if let t = m?.episodeTitle { rest = t }
        else { rest = m?.name ?? p.title }
        guard let tag else { return Text(m?.name ?? displayName) }
        return Text("\(Text(tag).fontWeight(.bold))  \(rest)")
    }

    private var displayName: String {
        guard clean, !item.isDirectory, item.isMedia else { return item.name }
        return TitleParser.clean(item.name)
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
}

/// Crawls the library in the background and searches every file name.
struct LibrarySearchView: View {
    let server: WebDAVServer
    let root: URL

    @State private var query = ""
    @State private var index: [DAVItem] = []
    @State private var folders = 0
    @State private var crawling = false
    @State private var crawlTask: Task<Void, Never>?
    @AppStorage(SettingsKey.cleanTitles) private var cleanTitles = true

    var body: some View {
        List {
            Section {
                HStack {
                    if crawling { ProgressView().padding(.trailing, 6) }
                    Text(crawling ? "Indexing… \(folders) folders, \(index.count) files" : "Indexed \(folders) folders, \(index.count) files")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(results) { item in
                Button {
                    ContinueQueue.play(WebDAVClient(server: server).mediaItem(for: item, cleanTitles: cleanTitles))   // with its folder as the queue
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        DAVRow(item: item, clean: cleanTitles, entry: HistoryStore.shared.entry(forURL: item.url.absoluteString))
                        Text(item.url.deletingLastPathComponent().path.removingPercentEncoding ?? "")
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search all files")
        .brandListBackground()
        .navigationTitle("Search Library")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if crawlTask == nil { startCrawl() } }
        .onDisappear { crawlTask?.cancel() }
    }

    private var results: [DAVItem] {
        guard query.count >= 2 else { return [] }
        let words = query.lowercased().split(separator: " ")
        return index.filter { item in
            let hay = (item.name + " " + TitleParser.clean(item.name)).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
        .prefix(300).map { $0 }
    }

    private func startCrawl() {
        crawling = true
        let client = WebDAVClient(server: server)
        crawlTask = Task {
            var queue: [(URL, Int)] = [(root, 0)]
            var seen = Set<String>()
            while !queue.isEmpty, !Task.isCancelled, folders < 3000 {
                let batch = Array(queue.prefix(4))
                queue.removeFirst(batch.count)
                let results = await withTaskGroup(of: [DAVItem].self) { group -> [[DAVItem]] in
                    for (u, _) in batch { group.addTask { (try? await client.list(u)) ?? [] } }
                    var out: [[DAVItem]] = []
                    for await r in group { out.append(r) }
                    return out
                }
                let depth = (batch.first?.1 ?? 0) + 1
                for list in results {
                    folders += 1
                    for item in list {
                        if item.isDirectory {
                            if depth < 6, seen.insert(item.url.absoluteString).inserted { queue.append((item.url, depth)) }
                        } else if item.isMedia {
                            index.append(item)
                        }
                    }
                }
            }
            crawling = false
        }
    }
}
