import SwiftUI

/// An SMB share's folder (or a host's shares), browsed like a WebDAV folder
/// (1.20.3, 2 Nov): the same rows (DAVRow), order (DAVOrder), Clean titles
/// and Only media files. A video plays with the folder's other videos as the
/// queue, each with its subtitle files ("Film.en.srt" for "Film.mkv").
///
/// Entries are DAVItems with smb:// addresses without the login, so rows,
/// pictures and history never hold the password.
struct SMBBrowserView: View {
    let server: MediaServer
    /// From the host: "/" (its shares), "/Media", "/Media/Films".
    let path: String
    let title: String

    @ObservedObject private var history = HistoryStore.shared
    @State private var items: [DAVItem] = []
    @State private var keyed: [DAVOrder.Keyed] = []
    @State private var ordered: [DAVItem] = []
    @State private var attributeLines: [URL: [String]] = [:]
    @State private var loading = true
    @State private var error: String?
    @State private var offline = false
    @State private var filter = ""
    @State private var sort: LibrarySort = .name
    @State private var ascending = true
    @State private var prefLoaded = false
    @AppStorage(SettingsKey.cleanTitles) private var cleanTitles = true
    @AppStorage(SettingsKey.showOnlyMedia) private var onlyMedia = false

    private var sortKey: String { "\(server.id.uuidString)|\(path)" }

    var body: some View {
        List {
            if let error {
                Section {
                    Label(error, systemImage: offline ? "wifi.slash" : "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("Retry") { Task { await load() } }
                }
            }
            ForEach(visible) { item in
                if item.isDirectory {
                    NavigationLink {
                        SMBBrowserView(server: server, path: itemPath(item),
                                       title: cleanTitles ? ReleaseName.folder(item.name)?.title ?? item.name : item.name)
                    } label: {
                        DAVRow(item: item, clean: cleanTitles, entry: nil, attributes: attributeLines[item.url] ?? [])
                    }
                    .accessibilityIdentifier("smb:" + item.name)
                    .contextMenu {
                        Button { UIPasteboard.general.string = item.name } label: { Label("Copy original name", systemImage: "doc.on.doc") }
                        Text(item.name)
                    }
                } else {
                    let key = historyKey(item)
                    Button { open(item) } label: {
                        DAVRow(item: item, clean: cleanTitles, entry: history.entry(forURL: key), attributes: attributeLines[item.url] ?? [])
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("smb:" + item.name)
                    .contextMenu {
                        if item.isMedia { Button { open(item) } label: { Label("Play", systemImage: "play") } }
                        // The address without the login.
                        Button { UIPasteboard.general.string = item.url.absoluteString } label: { Label("Copy link", systemImage: "link") }
                        if item.isMedia {
                            WatchedMenuItems(keys: [key]) { _ in mediaItem(item) }
                        }
                        if let e = history.entry(forURL: key), e.canResume {
                            Button(role: .destructive) { history.remove(e) } label: { Label("Clear progress", systemImage: "arrow.uturn.backward") }
                        }
                        Text(item.name)
                    }
                }
            }
            if !loading && visible.isEmpty && error == nil {
                Text(filter.isEmpty ? (path == "/" ? "No shares" : "Empty folder") : "No matches").foregroundStyle(.secondary)
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
                LibrarySortMenu(sort: $sort, ascending: $ascending, inToolbar: true)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // The automatic style: the app-wide switch style leaves toggles disabled in menus (1.18.0).
                    Group {
                        Toggle("Clean titles", isOn: $cleanTitles)
                        Toggle("Only media files", isOn: $onlyMedia)
                    }
                    .toggleStyle(.automatic)
                } label: { ToolbarGlyph("ellipsis.circle") }
                .accessibilityLabel("More")
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

    private var visible: [DAVItem] {
        var list = ordered
        if onlyMedia { list = list.filter { $0.isDirectory || $0.isMedia } }
        if !filter.isEmpty {
            list = list.filter { i in
                i.name.localizedCaseInsensitiveContains(filter) || TitleParser.clean(i.name).localizedCaseInsensitiveContains(filter)
                    || (i.isDirectory && ReleaseName.folder(i.name)?.title.localizedCaseInsensitiveContains(filter) == true)
            }
        }
        return list
    }

    private func itemPath(_ item: DAVItem) -> String { SMBPath.join(path, item.name) }
    private func historyKey(_ item: DAVItem) -> String { ServerPlayback.historyKey(kind: .smb, server: server.id, item: itemPath(item)) }

    private func rekey() {
        keyed = DAVOrder.keyed(items, clean: cleanTitles)
        attributeLines = DAVRow.attributeLines(items, clean: cleanTitles)
        reorder()
    }

    private func reorder() { ordered = DAVOrder.sorted(keyed, by: sort, ascending: ascending) }

    private func load() async {
        loading = true
        defer { loading = false }
        guard let client = SMBClient.shared(for: server), let host = server.smbHost else {
            error = SMBError.badAddress.localizedDescription
            return
        }
        do {
            let entries = try await client.list(path)
            items = entries.compactMap { e in
                guard let url = URL(string: SMBURL.address(host: host, path: SMBPath.join(path, e.name))) else { return nil }
                return DAVItem(url: url, name: e.name, isDirectory: e.kind != .file, size: e.size, modified: e.modified, contentType: nil)
            }
            rekey()
            error = nil
        } catch {
            let m = ServerError.message(error, server: server.displayName)
            offline = m.offline
            self.error = m.text
        }
    }

    private func mediaItem(_ item: DAVItem, subtitles: [String] = []) -> MediaItem {
        ServerPlayback.smbItem(server: server, path: itemPath(item), name: item.name, cleanTitles: cleanTitles,
                               subtitles: subtitles.map { (path: SMBPath.join(path, $0), name: $0) })
    }

    private func open(_ item: DAVItem) {
        guard item.isMedia else {
            if item.isSubtitle { return }
            PlayerPresenter.play(mediaItem(item))          // unknown extension: let mpv try
            return
        }
        let media = visible.filter(\.isMedia)
        let subs = items.filter(\.isSubtitle).map(\.name)
        let queue = media.map { mediaItem($0, subtitles: ServerPlayback.matchingSubtitles(for: $0.name, in: subs)) }
        PlayerPresenter.play(queue: queue, index: media.firstIndex(of: item) ?? 0)
    }

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

/// What a server row opens: the share, or the server's libraries.
struct MediaServerBrowser: View {
    let server: MediaServer

    var body: some View {
        switch server.kind {
        case .smb:
            SMBBrowserView(server: server, path: server.smbStartPath, title: server.displayName)
        case .jellyfin:
            if let c = JellyfinClient(server: server, device: JellyfinAPI.deviceModel) {
                CatalogBrowserView(source: c, parent: nil, title: server.displayName)
            } else { notSignedIn }
        case .plex:
            if let c = PlexClient(server: server) {
                CatalogBrowserView(source: c, parent: nil, title: server.displayName)
            } else { notSignedIn }
        }
    }

    private var notSignedIn: some View {
        ContentUnavailableView("Not signed in", systemImage: "person.crop.circle.badge.exclamationmark",
                               description: Text(server.kind == .plex ? "Edit the server and paste its X-Plex-Token." : "Edit the server and sign in again."))
            .brandListBackground()
            .navigationTitle(server.displayName)
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct MediaServerRow: View {
    let server: MediaServer
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Theme.accentSoft)
                Image(systemName: server.kind.icon).foregroundStyle(Theme.accent)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayName).font(.headline)
                Text("\(server.kind.title) · \(server.detail)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
