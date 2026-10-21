import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var local = LocalMediaStore.shared
    @ObservedObject private var servers = ServerStore.shared
    @State private var showOpenURL = false
    @State private var addServer = false
    @State private var heroIndex = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    if !history.continueWatching.isEmpty { hero }
                    quickActions
                    if !local.files.isEmpty { recentlyAdded }
                    sources
                    if history.recent.count > 0 { recentlyPlayed }
                    if history.entries.isEmpty && local.files.isEmpty { welcome }
                }
                .padding(.vertical, 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { local.refresh() }
            .sheet(isPresented: $showOpenURL) { OpenURLSheet() }
            .sheet(isPresented: $addServer) { ServerEditView(server: nil) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting.uppercased())
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent).tracking(1.2)
                Text("What are we watching?")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
            }
            Spacer()
            Menu {
                Button { FileOpener.pickAndPlay() } label: { Label("Open file", systemImage: "folder") }
                Button { showOpenURL = true } label: { Label("Open URL", systemImage: "link") }
                Button { pasteAndPlay() } label: { Label("Paste & play", systemImage: "doc.on.clipboard") }
                Button { addServer = true } label: { Label("Add WebDAV server", systemImage: "server.rack") }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 42, height: 42)
                    .glassCircle()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Late night"
        }
    }

    // MARK: Hero (continue watching)

    private var hero: some View {
        let items = Array(history.continueWatching.prefix(8))
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Continue Watching")
            TabView(selection: $heroIndex) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, e in
                    HeroCard(entry: e)
                        .padding(.horizontal, 20)
                        .tag(i)
                        .onTapGesture { PlayerPresenter.play(e.item) }
                        .contextMenu { historyMenu(e) }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: items.count > 1 ? .automatic : .never))
            .frame(height: 236)
        }
    }

    // MARK: Quick actions

    private var quickActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Chip(icon: "folder.fill", title: "Open File") { FileOpener.pickAndPlay() }
                Chip(icon: "link", title: "Stream URL") { showOpenURL = true }
                Chip(icon: "doc.on.clipboard", title: "Paste & Play") { pasteAndPlay() }
                Chip(icon: "server.rack", title: "Add Server") { addServer = true }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: Recently added (on this device)

    private var recentlyAdded: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("On This Device", trailing: "\(local.files.count)")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 16) {
                ForEach(local.files.prefix(8), id: \.self) { f in
                    Button { playLocal(f) } label: {
                        MediaTile(title: TitleParser.clean(f.lastPathComponent),
                                  subtitle: f.pathExtension.uppercased(),
                                  key: f.path, fileURL: f, artwork: nil,
                                  progress: history.entry(forURL: f.path)?.progress)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { playLocal(f) } label: { Label("Play", systemImage: "play") }
                        Button(role: .destructive) { local.delete(f) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .padding(.horizontal, 20)
            if local.files.count > 8 {
                NavigationLink {
                    LocalFolderView(url: MPVFiles.mediaDir, title: "On This Device")
                } label: {
                    Text("Show all \(local.files.count)").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: Sources

    private var sources: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Sources")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(servers.servers) { s in
                        NavigationLink {
                            if let url = WebDAVClient(server: s).url(forPath: s.rootPath) {
                                WebDAVBrowserView(server: s, url: url, title: s.name)
                            }
                        } label: {
                            SourceCard(title: s.name, subtitle: s.base?.host ?? "", icon: "server.rack", tint: Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    NavigationLink {
                        LocalFolderView(url: MPVFiles.mediaDir, title: "On This Device")
                    } label: {
                        SourceCard(title: "This iPhone", subtitle: "Files → GlassPlayer", icon: "iphone", tint: .blue)
                    }
                    .buttonStyle(.plain)
                    Button { addServer = true } label: {
                        SourceCard(title: "Add server", subtitle: "Real-Debrid, NAS…", icon: "plus", tint: .gray)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: Recently played

    private var recentlyPlayed: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Recently Played")
            VStack(spacing: 10) {
                ForEach(history.recent.prefix(6)) { e in
                    Button { PlayerPresenter.play(e.item) } label: { HistoryRow(entry: e) }
                        .buttonStyle(.plain)
                        .contextMenu { historyMenu(e) }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "sparkles.tv").font(.largeTitle).foregroundStyle(Theme.gradient)
            Text("Everything mpv can play").font(.title3.weight(.bold))
            Text("Open a file, paste a link, connect Real-Debrid or a NAS over WebDAV, or browse what's on Netflix, Prime and more in Discover.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(cornerRadius: 24)
        .padding(.horizontal, 20)
    }

    // MARK: Helpers

    private func sectionTitle(_ t: String, trailing: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(t).font(.title3.weight(.bold))
            if let trailing { Text(trailing).font(.subheadline).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private func historyMenu(_ e: HistoryEntry) -> some View {
        Button { PlayerPresenter.play(e.item) } label: { Label(e.canResume ? "Resume" : "Play", systemImage: "play") }
        Button { history.markWatched(e) } label: { Label("Mark as watched", systemImage: "checkmark.circle") }
        Button(role: .destructive) { history.remove(e) } label: { Label("Remove", systemImage: "trash") }
    }

    private func pasteAndPlay() {
        if let s = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), URL(string: s)?.scheme != nil {
            PlayerPresenter.play(MediaItem(url: s, title: "", source: .url))
        }
    }

    private func playLocal(_ f: URL) {
        let queue = local.files.map { u -> MediaItem in
            var m = MediaItem(url: u.path, title: TitleParser.clean(u.lastPathComponent), source: .local)
            m.historyKey = u.path
            let p = TitleParser.parse(u.lastPathComponent)
            if p.episode != nil { m.anime = AnimeHint(title: p.title, episode: p.episode) }
            return m
        }
        PlayerPresenter.play(queue: queue, index: local.files.firstIndex(of: f) ?? 0)
    }
}

// MARK: - Components

struct HeroCard: View {
    let entry: HistoryEntry
    @StateObject private var thumb = ThumbLoader()

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let img = thumb.image {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    GeneratedArt(seed: entry.item.displayTitle)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.item.displayTitle).font(.title3.weight(.bold)).lineLimit(2)
                if let s = entry.item.subtitle { Text(s).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1) }
                HStack(spacing: 10) {
                    Label("Resume", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .glass(cornerRadius: 18, interactive: true)
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: entry.progress).tint(.white)
                        Text("\(PlayerModel.format(max(0, entry.duration - entry.position))) left")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(16)
        }
        .frame(height: 210)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .onAppear { thumb.load(key: entry.item.id, fileURL: entry.item.resolvedURL?.isFileURL == true ? entry.item.resolvedURL : nil, artwork: entry.item.artwork) }
    }
}

struct MediaTile: View {
    let title: String
    let subtitle: String
    let key: String
    let fileURL: URL?
    let artwork: String?
    let progress: Double?
    @StateObject private var thumb = ThumbLoader()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        if let img = thumb.image {
                            Image(uiImage: img).resizable().scaledToFill()
                        } else {
                            GeneratedArt(seed: title)
                        }
                    }
                    .clipped()
                if let progress, progress > 0.01 {
                    GeometryReader { g in
                        Rectangle().fill(Theme.accent).frame(width: g.size.width * progress, height: 3)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(subtitle).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
        }
        .onAppear { thumb.load(key: key, fileURL: fileURL, artwork: artwork) }
    }
}

/// Deterministic gradient art for items without a thumbnail.
struct GeneratedArt: View {
    let seed: String
    var body: some View {
        let h = Double(abs(seed.hashValue % 360)) / 360
        ZStack {
            LinearGradient(colors: [Color(hue: h, saturation: 0.55, brightness: 0.45),
                                    Color(hue: (h + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.18)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(String(seed.prefix(1)).uppercased())
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.18))
        }
    }
}

struct Chip: View {
    let icon: String
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
                Text(title).font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .glass(cornerRadius: 20, interactive: true)
        }
        .buttonStyle(.plain)
    }
}

struct SourceCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: 150, alignment: .leading)
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    @StateObject private var thumb = ThumbLoader()

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let img = thumb.image {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    GeneratedArt(seed: entry.item.displayTitle)
                }
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.item.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: icon)
                    if let s = entry.item.subtitle { Text(s).lineLimit(1) }
                    Text(entry.updated, style: .relative)
                }
                .font(.caption).foregroundStyle(.secondary)
                if entry.duration > 0 && !entry.isFinished {
                    ProgressView(value: entry.progress).tint(Theme.accent).scaleEffect(x: 1, y: 0.6, anchor: .leading)
                }
            }
            Spacer(minLength: 0)
            if entry.isFinished { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
        }
        .padding(8)
        .background(Theme.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear { thumb.load(key: entry.item.id, fileURL: nil, artwork: entry.item.artwork) }
    }

    private var icon: String {
        switch entry.item.source {
        case .webdav: return "server.rack"
        case .addon: return "puzzlepiece.extension.fill"
        case .local: return "iphone"
        case .url: return "link"
        }
    }
}

struct OpenURLSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var userAgent = ""
    @State private var referer = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://, rtsp://, smb://, ftp://…", text: $url, axis: .vertical)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Paste") { url = UIPasteboard.general.string ?? "" }
                } header: { Text("Stream URL") } footer: { Text("HTTP(S), HLS (.m3u8), DASH, RTSP, RTMP, FTP, SMB and SFTP.") }
                Section("Optional headers") {
                    TextField("User-Agent", text: $userAgent).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Referer", text: $referer).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
            .navigationTitle("Open URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Play") {
                        var m = MediaItem(url: url.trimmingCharacters(in: .whitespacesAndNewlines), title: "", source: .url)
                        if !userAgent.isEmpty { m.headers["User-Agent"] = userAgent }
                        if !referer.isEmpty { m.headers["Referer"] = referer }
                        dismiss()
                        PlayerPresenter.play(m)
                    }
                    .disabled(url.isEmpty)
                }
            }
        }
    }
}
