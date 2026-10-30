import SwiftUI

struct NetworkView: View {
    @ObservedObject private var store = ServerStore.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @State private var editing: WebDAVServer?
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.servers) { s in
                        NavigationLink {
                            if let url = WebDAVClient(server: s).url(forPath: s.rootPath) {
                                WebDAVBrowserView(server: s, url: url, title: s.name)
                            } else {
                                Text("Invalid server URL")
                            }
                        } label: { ServerRow(server: s) }
                        .swipeActions {
                            Button(role: .destructive) { store.remove(s) } label: { Label("Delete", systemImage: "trash") }
                            Button { editing = s } label: { Label("Edit", systemImage: "pencil") }.tint(.gray)
                        }
                        .contextMenu {
                            Button { editing = s } label: { Label("Edit", systemImage: "pencil") }
                            Button(role: .destructive) { store.remove(s) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                    Button { adding = true } label: { Label("Add WebDAV server", systemImage: "plus.circle.fill") }
                } header: { Text("WebDAV") } footer: {
                    Text("Real-Debrid, TorBox, Premiumize, Nextcloud, Synology, rclone serve webdav… Passwords are stored in the iOS Keychain.")
                }
                Section {
                    NavigationLink { DownloadsView() } label: {
                        HStack {
                            Label("Downloads", systemImage: "arrow.down.circle")
                            Spacer()
                            if downloads.hasWork { Text("\(downloads.active.count) active").font(.subheadline).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .brandListBackground()
            .navigationTitle("Network")
            .sheet(isPresented: $adding) { ServerEditView(server: nil) }
            .sheet(item: $editing) { s in ServerEditView(server: s) }
            .navigationDestination(for: LibraryRoute.self) { LibraryRoute.destination($0) }
        }
    }
}

struct LocalFolderView: View {
    let url: URL
    let title: String
    @State private var items: [URL] = []
    @AppStorage("libraryView") private var libraryView = LibraryViewMode.grid.rawValue
    @ObservedObject private var history = HistoryStore.shared

    private var folders: [URL] { items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } }
    private var media: [URL] { LibraryOrganizer.sorted(items.filter { TitleParser.isMedia($0.lastPathComponent) }) }
    @AppStorage("librarySort") private var librarySort: LibrarySort = .name
    @AppStorage("librarySortAsc") private var librarySortAsc = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zoomsFromTile) private var zooms

    var body: some View {
        GeometryReader { geo in
            let margin: CGFloat = geo.size.width > 700 ? 28 : 20
            let cols = max(2, Int((geo.size.width - margin * 2 + 14) / 184))
            let mode = LibraryViewMode(rawValue: libraryView) ?? .grid
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(folders, id: \.self) { u in
                        NavigationLink(value: LibraryRoute.folder(u.path)) {
                            Label(u.lastPathComponent, systemImage: "folder.fill").font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(PressStyle(scale: 0.98))
                    }
                    if mode == .grid {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: cols), spacing: 18) {
                            ForEach(media, id: \.self) { f in
                                NavigationLink(value: LibraryRoute.file(f.path)) {
                                    MediaTile(title: TitleParser.clean(f.lastPathComponent), subtitle: f.pathExtension.uppercased(),
                                              key: f.path, fileURL: f, lookupName: f.lastPathComponent,
                                              progress: history.entry(forURL: f.path)?.progress)
                                }
                                .buttonStyle(PressStyle(scale: 0.97))
                                .contextMenu {
                                    Button { play(f) } label: { Label("Play", systemImage: "play") }
                                    Button(role: .destructive) { try? FileManager.default.removeItem(at: f); reload() } label: { Label("Delete", systemImage: "trash") }
                                }
                            }
                        }
                    } else {
                        LibraryList(files: media, mode: mode) { play($0) }
                    }
                    if items.isEmpty {
                        Text("Empty. Add files from Home, or copy them with the Files app (On My iPhone → Folio → \(title)).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, margin)
                .padding(.vertical, 12)
            }
        }
        .background(HomeBackdrop().ignoresSafeArea())
        .brandListBackground()
        .pageChrome(zooms: zooms, title: title, back: { dismiss() }) {
            HStack(spacing: 6) { LibrarySortMenu(sort: $librarySort, ascending: $librarySortAsc); ViewModeMenu(mode: $libraryView) }
        }
        .onAppear(perform: reload)
        .refreshable { reload() }
        .onReceive(LocalMediaStore.shared.$files) { _ in reload() }
    }

    private func play(_ u: URL) {
        let queue = media.map { f -> MediaItem in
            var m = MediaItem(url: f.path, title: TitleParser.clean(f.lastPathComponent), source: .local)
            m.historyKey = f.path
            return m
        }
        if let i = media.firstIndex(of: u) { PlayerPresenter.play(queue: queue, index: i) }
    }

    private func reload() {
        items = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}


struct ServerRow: View {
    let server: WebDAVServer
    @StateObject private var brand = BrandIconLoader()
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let img = brand.image {
                    Image(uiImage: img).resizable().scaledToFit()
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 10).fill(Theme.accentSoft)
                    Image(systemName: "externaldrive.connected.to.line.below").foregroundStyle(Theme.accent)
                }
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).font(.headline)
                Text(server.base?.host ?? server.baseURL).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { brand.load(host: server.base?.host) }
    }
}
