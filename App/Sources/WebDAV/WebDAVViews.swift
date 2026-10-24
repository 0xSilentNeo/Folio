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

enum DAVSort: String, CaseIterable, Codable {
    case name, date, size
    var label: String { rawValue.capitalized }
}

struct FolderSortPref: Codable { var sort: DAVSort; var ascending: Bool }

struct WebDAVBrowserView: View {
    let server: WebDAVServer
    let url: URL
    let title: String

    @ObservedObject private var history = HistoryStore.shared
    @State private var items: [DAVItem] = []
    @State private var loading = true
    @State private var error: String?
    @State private var filter = ""
    @State private var sort: DAVSort = .name
    @State private var ascending = true
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
                } else {
                    Button { open(item) } label: {
                        DAVRow(item: item, clean: cleanTitles, entry: history.entry(forURL: item.url.absoluteString))
                    }
                    .buttonStyle(.plain)
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
                Menu {
                    Picker("Sort by", selection: $sort) {
                        ForEach(DAVSort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle("Ascending", isOn: $ascending)
                    Divider()
                    Toggle("Clean titles", isOn: $cleanTitles)
                    Toggle("Only media files", isOn: $onlyMedia)
                } label: { ToolbarGlyph("arrow.up.arrow.down.circle") }
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
        .onChange(of: sort) { _, _ in saveSortPref() }
        .onChange(of: ascending) { _, _ in saveSortPref() }
    }

    private var visible: [DAVItem] {
        var list = items
        if onlyMedia { list = list.filter { $0.isDirectory || $0.isMedia } }
        if !filter.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(filter) || TitleParser.clean($0.name).localizedCaseInsensitiveContains(filter) }
        }
        return list.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let r: Bool
            switch sort {
            case .name: r = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .date: r = (a.modified ?? .distantPast) < (b.modified ?? .distantPast)
            case .size: r = (a.size ?? 0) < (b.size ?? 0)
            }
            return ascending ? r : !r
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            items = try await client.list(url)
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

    private func loadSortPref() {
        guard let data = UserDefaults.standard.dictionary(forKey: SettingsKey.folderSorts)?[sortKey] as? Data,
              let pref = try? JSONDecoder().decode(FolderSortPref.self, from: data) else { return }
        sort = pref.sort
        ascending = pref.ascending
    }

    private func saveSortPref() {
        var dict = UserDefaults.standard.dictionary(forKey: SettingsKey.folderSorts) ?? [:]
        dict[sortKey] = try? JSONEncoder().encode(FolderSortPref(sort: sort, ascending: ascending))
        UserDefaults.standard.set(dict, forKey: SettingsKey.folderSorts)
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
                Text(item.isMedia && clean ? (thumb.meta.map { m in m.episodeTitle.map { "\(m.name) · \($0)" } ?? m.name } ?? displayName) : displayName)
                    .font(.subheadline.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    if let size = item.size, !item.isDirectory { Text(size.byteString) }
                    if let d = item.modified { Text(d, format: .dateTime.day().month().year()) }
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
