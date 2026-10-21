import SwiftUI

struct NetworkView: View {
    @ObservedObject private var store = ServerStore.shared
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

                Section("Files") {
                    NavigationLink {
                        LocalFolderView(url: MPVFiles.mediaDir, title: "Library")
                    } label: { Label("On this device", systemImage: "iphone") }
                    NavigationLink {
                        LocalFolderView(url: MPVFiles.screenshotsDir, title: "Screenshots")
                    } label: { Label("Screenshots", systemImage: "camera") }
                }
            }
            .navigationTitle("Network")
            .sheet(isPresented: $adding) { ServerEditView(server: nil) }
            .sheet(item: $editing) { s in ServerEditView(server: s) }
        }
    }
}

struct LocalFolderView: View {
    let url: URL
    let title: String
    @State private var items: [URL] = []

    var body: some View {
        List {
            ForEach(items, id: \.self) { u in
                let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir == true {
                    NavigationLink { LocalFolderView(url: u, title: u.lastPathComponent) } label: {
                        Label(u.lastPathComponent, systemImage: "folder.fill")
                    }
                } else {
                    Button {
                        let media = items.filter { TitleParser.isMedia($0.lastPathComponent) }
                        let queue = media.map { f -> MediaItem in
                            var m = MediaItem(url: f.path, title: TitleParser.clean(f.lastPathComponent), source: .local)
                            m.historyKey = f.path
                            return m
                        }
                        if let i = media.firstIndex(of: u) { PlayerPresenter.play(queue: queue, index: i) }
                    } label: {
                        Label(u.lastPathComponent, systemImage: TitleParser.isMedia(u.lastPathComponent) ? "film" : "doc")
                    }
                    .disabled(!TitleParser.isMedia(u.lastPathComponent))
                }
            }
            .onDelete { idx in
                for i in idx { try? FileManager.default.removeItem(at: items[i]) }
                reload()
            }
            if items.isEmpty {
                Text("Empty. Copy files here with the Files app (On My iPhone → GlassPlayer → \(title)).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(title)
        .onAppear(perform: reload)
        .refreshable { reload() }
        .onReceive(LocalMediaStore.shared.$files) { _ in reload() }
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
