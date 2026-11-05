import SwiftUI

/// A Jellyfin or Plex server, browsed like a WebDAV folder (1.20.3, 2 Nov):
/// libraries, then their films, shows or folders, then seasons and
/// episodes. A film or episode plays with the rest of the list (the season,
/// the library) as the queue, in the order shown. Watched marks and
/// progress come from Folio's own history, as for WebDAV files.
struct CatalogBrowserView: View {
    let source: any CatalogSource
    /// nil: the server's libraries.
    let parent: CatalogEntry?
    let title: String

    @ObservedObject private var history = HistoryStore.shared
    @State private var entries: [CatalogEntry] = []
    @State private var ordered: [CatalogEntry] = []
    @State private var loading = true
    @State private var error: String?
    @State private var offline = false
    @State private var sort: LibrarySort = .name
    @State private var ascending = true
    @State private var prefLoaded = false

    private var sortKey: String { "\(source.server.id.uuidString)|\(parent?.id ?? "/")" }

    var body: some View {
        List {
            if let error {
                Section {
                    Label(error, systemImage: offline ? "wifi.slash" : "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("Retry") { Task { await load() } }
                }
            }
            ForEach(visible) { e in
                if e.isPlayable {
                    let key = source.historyKey(e)
                    Button { play(e) } label: {
                        ServerCatalogRow(entry: e, image: source.imageRequest(for: e, pixels: e.hasWideArt ? 84 : 120),
                                   history: history.entry(forURL: key))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("catalog:" + e.name)
                    .contextMenu {
                        Button { play(e) } label: { Label("Play", systemImage: "play") }
                        WatchedMenuItems(keys: [key]) { _ in source.mediaItem(for: e, parent: parent) }
                        if let h = history.entry(forURL: key), h.canResume {
                            Button(role: .destructive) { history.remove(h) } label: { Label("Clear progress", systemImage: "arrow.uturn.backward") }
                        }
                        if let f = e.fileName { Text(f) }
                    }
                } else {
                    NavigationLink {
                        CatalogBrowserView(source: source, parent: e, title: CatalogTitles.rowTitle(e))
                    } label: {
                        ServerCatalogRow(entry: e, image: e.kind == .library ? nil : source.imageRequest(for: e, pixels: 120), history: nil)
                    }
                    .accessibilityIdentifier("catalog:" + e.name)
                }
            }
            if !loading && visible.isEmpty && error == nil {
                Text(parent == nil ? "No libraries" : "Nothing here").foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .overlay { if loading && entries.isEmpty { FolioSpinner(size: .large) } }
        .brandListBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // No search bar of its own (1.22.5): the tab bar's search button,
        // opened from Home or Network, asks every Plex and Jellyfin server.
        .refreshable { await load() }
        .toolbar {
            if parent != nil {
                ToolbarItem(placement: .topBarTrailing) { LibrarySortMenu(sort: $sort, ascending: $ascending, inToolbar: true) }
            }
        }
        .task {
            loadSortPref()
            if entries.isEmpty { await load() }
        }
        .onChange(of: sort) { _, _ in saveSortPref(); reorder() }
        .onChange(of: ascending) { _, _ in saveSortPref(); reorder() }
    }

    private var visible: [CatalogEntry] { ordered }

    private func reorder() {
        // The libraries stay in the server's order.
        ordered = parent == nil ? entries : CatalogOrder.sorted(entries, by: sort, ascending: ascending)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            entries = try await source.children(of: parent)
            reorder()
            error = nil
        } catch {
            let m = ServerError.message(error, server: source.server.displayName)
            offline = m.offline
            self.error = m.text
        }
    }

    private func play(_ e: CatalogEntry) {
        let list = visible.filter(\.isPlayable)
        let queue = list.map { source.mediaItem(for: $0, parent: parent) }
        PlayerPresenter.play(queue: queue, index: list.firstIndex(of: e) ?? 0)
    }

    /// This list's own choice, else the last one made in any folder (the WebDAV browser's).
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

struct ServerCatalogRow: View {
    let entry: CatalogEntry
    let image: URLRequest?
    let history: HistoryEntry?
    @StateObject private var art = ServerArtLoader()

    private var wide: Bool { entry.hasWideArt }
    private var size: CGSize {
        switch entry.kind {
        case .library, .folder, .audio: return CGSize(width: 40, height: 40)
        default: return wide ? CGSize(width: 72, height: 42) : CGSize(width: 40, height: 60)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let img = art.image {
                    Image(uiImage: img).resizable().scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 10).fill(entry.isPlayable ? Theme.card : Theme.accentSoft)
                    Image(systemName: icon).foregroundStyle(entry.isPlayable ? .primary.opacity(0.8) : Theme.accent)
                }
            }
            .frame(width: size.width, height: size.height)
            .onAppear { art.load(image, key: image?.url?.absoluteString, pixels: max(size.width, size.height) * UIScreen.main.scale) }
            VStack(alignment: .leading, spacing: 3) {
                label.font(.subheadline.weight(.medium)).lineLimit(2)
                let details = CatalogTitles.details(entry)
                if !details.isEmpty {
                    Text(details.joined(separator: " · ")).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let s = entry.size, entry.isPlayable { Text(s.byteString) }
                    if let d = entry.added, entry.kind != .library { Text(d, format: .dateTime.day().month().year()) }
                    if let history, history.isFinished {
                        Label("Watched", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                    } else if let history, history.canResume {
                        Text("\(PlayerModel.format(history.position)) / \(PlayerModel.format(history.duration))").foregroundStyle(Theme.accent)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let history, history.canResume {
                    ProgressView(value: history.progress).tint(Theme.accent).scaleEffect(x: 1, y: 0.6)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// "S1 · E5  The Name", as the WebDAV browser shows episodes.
    private var label: Text {
        let name = CatalogTitles.rowTitle(entry)
        guard let tag = CatalogTitles.tag(entry) else { return Text(name) }
        return Text("\(Text(tag).fontWeight(.bold))  \(name)")
    }

    private var icon: String {
        switch entry.kind {
        case .library:
            switch entry.libraryType {
            case "movies", "movie": return "film.stack"
            case "tvshows", "show": return "tv"
            case "music", "artist": return "music.note.list"
            case "playlists": return "list.bullet"
            case "boxsets": return "square.stack"
            default: return "folder.fill"
            }
        case .folder: return "folder.fill"
        case .series: return "tv"
        case .season: return "rectangle.stack"
        case .movie, .episode, .video: return "film"
        case .audio: return "music.note"
        }
    }
}

/// A server's picture, asked for with the login in the headers (Plex's
/// need the token), kept in memory with the app's other pictures.
@MainActor
final class ServerArtLoader: ObservableObject {
    @Published var image: UIImage?
    private var key: String?

    func load(_ request: URLRequest?, key: String?, pixels: CGFloat) {
        guard let request, let key, self.key != key else { return }
        self.key = key
        let cacheKey = "server-art|\(Int(pixels))|" + key
        if let c = ImageCache.shared.picture(forKey: cacheKey) { image = c; return }
        Task {
            guard let data = try? await ServerHTTP.data(request) else { return }
            let img = await Task.detached(priority: .userInitiated) { ImageCache.downsample(data, maxPixel: pixels) }.value
            guard let img else { return }
            ImageCache.shared.remember(img, forKey: cacheKey)
            if self.key == key { image = img }
        }
    }
}
