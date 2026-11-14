import SwiftUI
import TipKit

struct NetworkView: View {
    @ObservedObject private var store = ServerStore.shared
    @ObservedObject private var mediaServers = MediaServerStore.shared
    /// Running downloads, for the Downloads row (1.25.0: a throttled count,
    /// not the whole manager, which redrew the tab on every progress tick).
    @State private var activeDownloads = 0
    @State private var editing: WebDAVServer?
    @State private var adding = false
    /// SMB, Jellyfin and Plex (1.20.3): their own list and form.
    @State private var addingServer: MediaServer.Kind?
    @State private var editingServer: MediaServer?
    /// A server about to be deleted (1.27.0: it went on one swipe, with its
    /// password, its library and its downloads, without a word).
    @State private var deletingWebDAV: WebDAVServer?
    @State private var deletingServer: MediaServer?
    /// The welcome's "Connect a Server" (1.27.0): which kind.
    @State private var choosingKind = false
    @State private var serversTipShown = false

    var body: some View {
        NavigationStack {
            List {
                // While there's no server (1.27.0). A row only while the tip
                // shows: an empty TipView still took a row's height.
                if serversTipShown {
                    TipView(ServersTip())
                        .tint(Theme.action)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
                Section {
                    ForEach(store.servers) { s in
                        NavigationLink {
                            if let url = WebDAVClient(server: s).url(forPath: s.rootPath) {
                                WebDAVBrowserView(server: s, url: url, title: s.name)
                            } else {
                                Text("Invalid server URL")
                            }
                        } label: { ServerRow(server: s) }
                        .swipeActions(allowsFullSwipe: false) {
                            Button(role: .destructive) { deletingWebDAV = s } label: { Label("Delete", systemImage: "trash") }
                            Button { editing = s } label: { Label("Edit", systemImage: "pencil") }.tint(.gray)
                        }
                        .contextMenu {
                            Button { editing = s } label: { Label("Edit", systemImage: "pencil") }
                            Button(role: .destructive) { deletingWebDAV = s } label: { Label("Delete…", systemImage: "trash") }
                        }
                    }
                    Button { adding = true } label: { Label("Add WebDAV server", systemImage: "plus.circle.fill") }
                } header: { Text("WebDAV") } footer: {
                    Text("Real-Debrid, TorBox, Premiumize, Nextcloud, Synology, rclone serve webdav… Passwords are stored in the iOS Keychain.")
                }
                Section {
                    ForEach(mediaServers.servers) { s in
                        NavigationLink { MediaServerBrowser(server: s) } label: { MediaServerRow(server: s) }
                        .swipeActions(allowsFullSwipe: false) {
                            Button(role: .destructive) { deletingServer = s } label: { Label("Delete", systemImage: "trash") }
                            Button { editingServer = s } label: { Label("Edit", systemImage: "pencil") }.tint(.gray)
                        }
                        .contextMenu {
                            Button { editingServer = s } label: { Label("Edit", systemImage: "pencil") }
                            Button(role: .destructive) { deletingServer = s } label: { Label("Delete…", systemImage: "trash") }
                        }
                    }
                    Menu { addServerButtons(webDAV: false) } label: {
                        Label("Add SMB, Jellyfin or Plex", systemImage: "plus.circle.fill")
                    }
                } header: { Text("Shares and media servers") } footer: {
                    Text("SMB shares on a NAS or computer, Jellyfin and Plex servers. Passwords and tokens are stored in the iOS Keychain.")
                }
                Section {
                    NavigationLink { DownloadsView() } label: {
                        HStack {
                            Label("Downloads", systemImage: "arrow.down.circle")
                            Spacer()
                            if activeDownloads > 0 { Text("\(activeDownloads) active").font(.subheadline).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .brandListBackground()
            .onReceive(DownloadManager.shared.objectWillChange
                .throttle(for: .seconds(0.5), scheduler: DispatchQueue.main, latest: true)
                .receive(on: DispatchQueue.main)
                .prepend(())) { _ in
                let dm = DownloadManager.shared
                let n = dm.hasWork ? dm.active.count : 0
                if n != activeDownloads { activeDownloads = n }
            }
            // Room under the last row for the downloads pill (1.24.1).
            .downloadPillRoom()
            .navigationTitle("Network")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu { addServerButtons(webDAV: true) } label: { ToolbarGlyph("plus") }
                        .accessibilityLabel("Add server")
                        .accessibilityIdentifier("addServerMenu")
                }
            }
            .confirmationDialog("Delete \(deletingWebDAV?.name ?? "this server")?", isPresented: Binding(get: { deletingWebDAV != nil }, set: { if !$0 { deletingWebDAV = nil } }),
                                titleVisibility: .visible, presenting: deletingWebDAV) { s in
                Button("Delete Server", role: .destructive) { store.remove(s) }
            } message: { _ in
                Text("Its password, its place in your library and its unfinished downloads go too. Files you've already downloaded stay.")
            }
            .confirmationDialog("Delete \(deletingServer?.name ?? "this server")?", isPresented: Binding(get: { deletingServer != nil }, set: { if !$0 { deletingServer = nil } }),
                                titleVisibility: .visible, presenting: deletingServer) { s in
                Button("Delete Server", role: .destructive) { mediaServers.remove(s) }
            } message: { _ in
                Text("Its password or token and its place in your library go too. Files you've already downloaded stay.")
            }
            .onChange(of: store.servers.isEmpty && mediaServers.servers.isEmpty, initial: true) { _, none in ServersTip.noServers = none }
            .task {
                for await show in ServersTip().shouldDisplayUpdates {
                    withAnimation(.smooth) { serversTipShown = show }
                }
            }
            .onReceive(FirstRunRouter.shared.$request) { if $0 == .addServer, FirstRunRouter.shared.take(.addServer) { choosingKind = true } }
            .confirmationDialog("Add a Server", isPresented: $choosingKind, titleVisibility: .visible) {
                Button("WebDAV") { adding = true }
                ForEach(MediaServer.Kind.allCases) { k in
                    Button(k.title) { addingServer = k }
                }
            } message: {
                Text("WebDAV for debrid services, Nextcloud or rclone; SMB for a NAS or computer's shared folder; or a Jellyfin or Plex server.")
            }
            .sheet(isPresented: $adding) { ServerEditView(server: nil) }
            .sheet(item: $editing) { s in ServerEditView(server: s) }
            .sheet(item: $addingServer) { k in MediaServerEditView(kind: k, server: nil) }
            .sheet(item: $editingServer) { s in MediaServerEditView(kind: s.kind, server: s) }
            .navigationDestination(for: LibraryRoute.self) { LibraryRoute.destination($0) }
        }
    }

    /// The "+" menu's servers.
    @ViewBuilder private func addServerButtons(webDAV: Bool) -> some View {
        if webDAV {
            Button { adding = true } label: { Label("WebDAV server", systemImage: "externaldrive.connected.to.line.below") }
        }
        ForEach(MediaServer.Kind.allCases) { k in
            Button { addingServer = k } label: { Label(k.title, systemImage: k.icon) }
        }
    }
}

struct LocalFolderView: View {
    let url: URL
    let title: String
    @State private var items: [URL] = []
    @AppStorage("libraryView") private var libraryView = LibraryViewMode.grid.rawValue
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var kids = KidsProfile.shared

    /// In the kids profile no subfolders (nothing in them was rated, review
    /// 5 Nov) and only the files whose title it allows.
    private var folders: [URL] {
        guard !KidsProfile.isOnNow else { return [] }
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }
    private var media: [URL] {
        let files = LibraryOrganizer.sorted(items.filter { TitleParser.isMedia($0.lastPathComponent) })
        guard let limits = KidsProfile.shared.activeLimits else { return files }
        return files.filter { KidsRules.allows(LibraryMetaIndex.shared.meta(for: $0), limits: limits) }
    }
    @AppStorage("librarySort") private var librarySort: LibrarySort = .name
    @AppStorage("librarySortAsc") private var librarySortAsc = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zoomsFromTile) private var zooms

    var body: some View {
        GeometryReader { geo in
            let layout = PageLayout(width: geo.size.width)
            let margin = layout.margin
            let cols = layout.thumbColumns
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
                                    // Not in the kids profile (1.30.4): it took no passcode.
                                    if !kids.isOn {
                                        Button(role: .destructive) { pendingDelete = f } label: { Label("Delete", systemImage: "trash") }
                                    }
                                }
                                .modifier(DeleteQuestion(file: f, pending: $pendingDelete, delete: deleteFile))
                            }
                        }
                    } else {
                        LibraryList(files: media, mode: mode, pendingDelete: $pendingDelete, delete: deleteFile) { play($0) }
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

    /// Delete asks first, then goes through the library (its picture too, and
    /// Home is told). Until 1.20.3 the grid removed the file at once.
    @State private var pendingDelete: URL?
    private func deleteFile(_ f: URL) {
        LocalMediaStore.shared.delete(f)
        reload()
    }

    /// Its own title only, in episode order (1.30.4): a film alone, a show's
    /// episodes. The whole folder was the queue, every other film after it.
    private func play(_ u: URL) {
        let key = LibraryOrganizer.titleKey(u)
        let list = media.filter { LibraryOrganizer.titleKey($0) == key }.sorted(by: LibraryOrganizer.episodeOrder)
        let queue = list.map { f -> MediaItem in
            var m = MediaItem(url: f.path, title: TitleParser.clean(f.lastPathComponent), source: .local)
            m.historyKey = f.path
            return m
        }
        if let i = list.firstIndex(of: u) { PlayerPresenter.play(queue: queue, index: i) }
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
