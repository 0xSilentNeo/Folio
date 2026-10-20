import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @ObservedObject private var history = HistoryStore.shared
    @State private var showOpenURL = false
    @State private var showFilePicker = false
    @State private var localFiles: [URL] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    quickActions
                    if !history.continueWatching.isEmpty {
                        section("Continue Watching") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 14) {
                                    ForEach(history.continueWatching.prefix(20)) { e in
                                        ContinueCard(entry: e)
                                            .onTapGesture { PlayerPresenter.play(e.item) }
                                            .contextMenu { historyMenu(e) }
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                    if !localFiles.isEmpty {
                        section("On This Device") {
                            VStack(spacing: 8) {
                                ForEach(localFiles, id: \.self) { f in
                                    Button { playLocal(f) } label: { LocalFileRow(url: f, entry: history.entry(forURL: f.path)) }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button(role: .destructive) {
                                                try? FileManager.default.removeItem(at: f)
                                                refreshLocal()
                                            } label: { Label("Delete file", systemImage: "trash") }
                                        }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    if !history.recent.isEmpty {
                        section("History") {
                            VStack(spacing: 8) {
                                ForEach(history.recent.prefix(25)) { e in
                                    Button { PlayerPresenter.play(e.item) } label: { HistoryRow(entry: e) }
                                        .buttonStyle(.plain)
                                        .contextMenu { historyMenu(e) }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    if history.entries.isEmpty && localFiles.isEmpty {
                        welcome
                    }
                }
                .padding(.vertical, 12)
            }
            .background(Theme.background)
            .navigationTitle("GlassPlayer")
            .onAppear(perform: refreshLocal)
            .sheet(isPresented: $showOpenURL) { OpenURLSheet() }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.movie, .audiovisualContent, .audio, .item], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result, !urls.isEmpty else { return }
                let items: [MediaItem] = urls.map { u in
                    _ = u.startAccessingSecurityScopedResource()
                    var m = MediaItem(url: u.path, title: TitleParser.clean(u.lastPathComponent), source: .local)
                    m.bookmark = try? u.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                    m.historyKey = "file:" + u.lastPathComponent
                    return m
                }
                PlayerPresenter.play(queue: items, index: 0)
            }
        }
    }

    private var quickActions: some View {
        HStack(spacing: 12) {
            ActionTile(icon: "folder.fill", title: "Open File") { showFilePicker = true }
            ActionTile(icon: "link", title: "Open URL") { showOpenURL = true }
            ActionTile(icon: "doc.on.clipboard", title: "Paste & Play") {
                if let s = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), URL(string: s)?.scheme != nil {
                    PlayerPresenter.play(MediaItem(url: s, title: "", source: .url))
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Welcome").font(.title2.weight(.bold))
            Text("Play anything mpv can: open a file, paste a link, add a WebDAV server (Real-Debrid, TorBox, NAS) under Network, or install addons under Discover.")
                .foregroundStyle(.secondary)
            Text("Files you copy into GlassPlayer → Media in the Files app show up here. Your mpv.conf, scripts and shaders live in GlassPlayer → mpv.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func historyMenu(_ e: HistoryEntry) -> some View {
        Button { PlayerPresenter.play(e.item) } label: { Label(e.canResume ? "Resume" : "Play", systemImage: "play") }
        Button { history.markWatched(e) } label: { Label("Mark as watched", systemImage: "checkmark.circle") }
        Button(role: .destructive) { history.remove(e) } label: { Label("Remove from history", systemImage: "trash") }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.bold)).padding(.horizontal, 16)
            content()
        }
    }

    private func refreshLocal() {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: MPVFiles.mediaDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        localFiles = items.filter { TitleParser.isMedia($0.lastPathComponent) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func playLocal(_ f: URL) {
        let queue = localFiles.map { u -> MediaItem in
            var m = MediaItem(url: u.path, title: TitleParser.clean(u.lastPathComponent), source: .local)
            m.historyKey = u.path
            let p = TitleParser.parse(u.lastPathComponent)
            if p.episode != nil { m.anime = AnimeHint(title: p.title, episode: p.episode) }
            return m
        }
        PlayerPresenter.play(queue: queue, index: localFiles.firstIndex(of: f) ?? 0)
    }
}

struct ActionTile: View {
    let icon: String
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon).font(.title3.weight(.semibold)).foregroundStyle(Theme.accent)
                Text(title).font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }
}

struct ContinueCard: View {
    let entry: HistoryEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                if let art = entry.item.artwork {
                    PosterImage(url: art, aspect: 16.0 / 9.0, cornerRadius: 16)
                } else {
                    RoundedRectangle(cornerRadius: 16).fill(Theme.gradient.opacity(0.35))
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .overlay(Image(systemName: "play.circle.fill").font(.system(size: 34)).foregroundStyle(.white.opacity(0.85)))
                }
                GeometryReader { g in
                    VStack {
                        Spacer()
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.25))
                            Capsule().fill(Theme.accent).frame(width: g.size.width * entry.progress)
                        }
                        .frame(height: 4)
                    }
                }
                .padding(10)
            }
            .frame(width: 240)
            Text(entry.item.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(entry.item.subtitle ?? "\(PlayerModel.format(entry.duration - entry.position)) left")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 240)
        .contentShape(Rectangle())
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Theme.card)
                Image(systemName: icon).foregroundStyle(Theme.accent)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.item.displayTitle).font(.subheadline.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    if let s = entry.item.subtitle { Text(s).lineLimit(1) }
                    Text(entry.updated, style: .relative)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if entry.isFinished {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
            } else if entry.duration > 0 {
                ProgressView(value: entry.progress).tint(Theme.accent).frame(width: 44)
            }
        }
        .padding(10)
        .background(Theme.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
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

struct LocalFileRow: View {
    let url: URL
    let entry: HistoryEntry?
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Theme.card)
                Image(systemName: "film").foregroundStyle(.white.opacity(0.8))
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(TitleParser.clean(url.lastPathComponent)).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(url.lastPathComponent).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let entry, entry.canResume { ProgressView(value: entry.progress).tint(Theme.accent).frame(width: 44) }
        }
        .padding(10)
        .background(Theme.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
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
                    TextField("https://, rtsp://, smb://, ftp://, magnet-free links…", text: $url, axis: .vertical)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Paste") { url = UIPasteboard.general.string ?? "" }
                } header: { Text("Stream URL") } footer: { Text("Anything ffmpeg/mpv can open: HTTP(S), HLS (.m3u8), DASH, RTSP, RTMP, FTP, SMB, SFTP.") }
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
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { PlayerPresenter.play(m) }
                    }
                    .disabled(url.isEmpty)
                }
            }
        }
    }
}
