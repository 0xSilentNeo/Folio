import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var local = LocalMediaStore.shared
    @State private var showOpenURL = false
    @State private var addServer = false
    @State private var showAddFiles = false

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let wide = geo.size.width > 700
                let margin: CGFloat = wide ? 28 : 20
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        header(margin)
                        if !history.continueWatching.isEmpty { continueWatching(width: geo.size.width, wide: wide, margin: margin) }
                        if !local.files.isEmpty { library(width: geo.size.width, margin: margin) }
                        else { howToAdd(margin).padding(.top, history.continueWatching.isEmpty ? 40 : 10) }
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
            }
            .background(HomeBackdrop().ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { local.refresh() }
            .sheet(isPresented: $showOpenURL) { OpenURLSheet() }
            .sheet(isPresented: $addServer) { ServerEditView(server: nil) }
            .sheet(isPresented: $showAddFiles) { addFilesSheet }
        }
    }

    /// The Files browser, zooming out of the button that opened it (iOS 18+).
    @ViewBuilder
    private var addFilesSheet: some View {
        if #available(iOS 18.0, *) {
            AddFilesPicker { showAddFiles = false }
                .navigationTransition(.zoom(sourceID: "addfiles", in: zoomNS))
                .ignoresSafeArea()
        } else {
            AddFilesPicker { showAddFiles = false }.ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func addFilesButton(large: Bool) -> some View {
        let label = HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: large ? 16 : 14, weight: .bold))
            Text("Add files").font(.system(size: large ? 17 : 15, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, large ? 24 : 16)
        .frame(height: large ? 52 : 40)
        .glass(cornerRadius: large ? 26 : 20, interactive: true)
        if #available(iOS 18.0, *) {
            Button { showAddFiles = true } label: { label }
                .buttonStyle(PressStyle())
                .matchedTransitionSource(id: "addfiles", in: zoomNS)
        } else {
            Button { showAddFiles = true } label: { label }.buttonStyle(PressStyle())
        }
    }

    // MARK: Header

    private func header(_ margin: CGFloat) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(greeting).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Text("GlassPlayer").font(.system(size: 28, weight: .bold, design: .rounded))
            }
            Spacer()
            Menu {
                Button { showAddFiles = true } label: { Label("Add files", systemImage: "folder.badge.plus") }
                Button { showOpenURL = true } label: { Label("Open URL", systemImage: "link") }
                Button { pasteAndPlay() } label: { Label("Paste & play", systemImage: "doc.on.clipboard") }
                Divider()
                Button { addServer = true } label: { Label("Add WebDAV server", systemImage: "externaldrive.connected.to.line.below") }
            } label: {
                Image(systemName: "plus").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44).glassCircle()
            }
            settingsLink
        }
        .padding(.horizontal, margin)
        .padding(.top, 8)
    }

    @Namespace private var zoomNS

    @ViewBuilder
    private var settingsLink: some View {
        if #available(iOS 18.0, *) {
            NavigationLink {
                SettingsView().navigationTransition(.zoom(sourceID: "settings", in: zoomNS))
            } label: {
                Image(systemName: "gearshape").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44).glassCircle()
            }
            .buttonStyle(PressStyle())
            .matchedTransitionSource(id: "settings", in: zoomNS)
        } else {
            NavigationLink { SettingsView() } label: {
                Image(systemName: "gearshape").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44).glassCircle()
            }
            .buttonStyle(PressStyle())
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Late night"
        }
    }

    // MARK: Continue watching

    private func continueWatching(width: CGFloat, wide: Bool, margin: CGFloat) -> some View {
        let items = Array(history.continueWatching.prefix(12))
        let cardW: CGFloat = wide ? 320 : min(340, width - margin * 2 - 28)
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Continue Watching", margin)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(items) { e in
                        HeroCard(entry: e, height: cardW * 9 / 16 + 8)
                            .frame(width: cardW)
                            .onTapGesture { PlayerPresenter.play(e.item) }
                            .contextMenu { historyMenu(e) }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, margin)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollClipDisabled()
        }
    }

    private func howToAdd(_ margin: CGFloat) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.accent)
            Text("Your library is empty").font(.headline)
            Text("Add videos from the Files app, paste a link with **+**, or copy files into\n**Files → On My iPhone → GlassPlayer → Media**.\nWebDAV servers like Real-Debrid live under Network.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            addFilesButton(large: true).padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, margin + 10)
        .padding(.vertical, 30)
    }

    // MARK: Library

    @AppStorage("libraryView") private var libraryView = LibraryViewMode.grid.rawValue

    private func library(width: CGFloat, margin: CGFloat) -> some View {
        let cols = max(2, Int((width - margin * 2 + 14) / 184))
        let mode = LibraryViewMode(rawValue: libraryView) ?? .grid
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Library").font(.title3.weight(.bold))
                Text("\(local.files.count)").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                ViewModeMenu(mode: $libraryView)
                NavigationLink { LocalFolderView(url: MPVFiles.mediaDir, title: "Library") } label: {
                    HStack(spacing: 2) { Text("All"); Image(systemName: "chevron.right").font(.caption.weight(.bold)) }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, margin)
            if mode == .grid {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: cols), spacing: 18) {
                    ForEach(local.files.prefix(cols * 2), id: \.self) { f in
                        NavigationLink { TitleHeroView(file: f) } label: {
                            MediaTile(title: TitleParser.clean(f.lastPathComponent), subtitle: f.pathExtension.uppercased(),
                                      key: f.path, fileURL: f, lookupName: f.lastPathComponent,
                                      progress: history.entry(forURL: f.path)?.progress)
                        }
                        .buttonStyle(PressStyle(scale: 0.97))
                        .contextMenu {
                            Button { playLocal(f) } label: { Label("Play", systemImage: "play") }
                            Button(role: .destructive) { local.delete(f) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
                .padding(.horizontal, margin)
            } else {
                LibraryList(files: Array(local.files.prefix(mode == .list ? 8 : 5)), mode: mode) { playLocal($0) }
                    .padding(.horizontal, margin)
            }
        }
    }

    // MARK: Helpers

    private func sectionTitle(_ t: String, _ margin: CGFloat, trailing: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(t).font(.title3.weight(.bold))
            if let trailing { Text(trailing).font(.subheadline).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(.horizontal, margin)
    }

    private func sectionTitle<D: View>(_ t: String, _ margin: CGFloat, trailing: String?, @ViewBuilder destination: @escaping () -> D) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(t).font(.title3.weight(.bold))
            if let trailing { Text(trailing).font(.subheadline).foregroundStyle(.secondary) }
            Spacer()
            NavigationLink(destination: destination) {
                HStack(spacing: 2) { Text("All"); Image(systemName: "chevron.right").font(.caption.weight(.bold)) }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, margin)
    }

    @ViewBuilder
    private func historyMenu(_ e: HistoryEntry) -> some View {
        Button { PlayerPresenter.play(e.item) } label: { Label(e.canResume ? "Resume" : "Play", systemImage: "play") }
        Button { history.markWatched(e) } label: { Label("Mark as watched", systemImage: "checkmark.circle") }
        Button(role: .destructive) { history.remove(e) } label: { Label("Remove", systemImage: "trash") }
    }

    private func pasteAndPlay() {
        guard let s = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            FileOpener.showAlert("Nothing to play", "Copy a video link first, then tap Paste & play.")
            return
        }
        guard let u = URL(string: s), u.scheme != nil else {
            FileOpener.showAlert("Not a link", "The clipboard doesn't contain a URL.")
            return
        }
        PlayerPresenter.play(MediaItem(url: s, title: "", source: .url))
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

struct HomeBackdrop: View {
    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(colors: [Theme.accent.opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Color(red: 0.45, green: 0.35, blue: 1.0).opacity(0.12), .clear], center: .topTrailing, startRadius: 0, endRadius: 380)
        }
    }
}

struct HeroCard: View {
    let entry: HistoryEntry
    var height: CGFloat = 230
    @StateObject private var thumb = ThumbLoader()

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let img = thumb.image { Image(uiImage: img).resizable().scaledToFill() }
                else { GeneratedArt(seed: entry.item.displayTitle) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                Text(thumb.meta?.name ?? entry.item.displayTitle).font(.headline.weight(.bold)).lineLimit(1)
                let line = [entry.item.subtitle, thumb.meta?.episodeTitle].compactMap { $0 }.first ?? thumb.meta?.synopsis
                if let line { Text(line).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1) }
                HStack(spacing: 12) {
                    Label("Resume", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .glass(cornerRadius: 20, interactive: true)
                    VStack(alignment: .leading, spacing: 5) {
                        ProgressView(value: entry.progress).tint(.white)
                        Text("\(PlayerModel.format(max(0, entry.duration - entry.position))) left")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.75))
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(14)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .onAppear {
            thumb.load(key: entry.item.id, fileURL: entry.item.resolvedURL?.isFileURL == true ? entry.item.resolvedURL : nil,
                       artwork: entry.item.artwork, lookupName: entry.item.resolvedURL?.lastPathComponent ?? entry.item.title)
        }
    }
}

struct MediaTile: View {
    let title: String
    let subtitle: String
    let key: String
    let fileURL: URL?
    var artwork: String? = nil
    var lookupName: String? = nil
    let progress: Double?
    @StateObject private var thumb = ThumbLoader()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        if let img = thumb.image { Image(uiImage: img).resizable().scaledToFill() }
                        else { GeneratedArt(seed: title) }
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
            Text(thumb.meta?.name ?? title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(thumb.meta?.episodeTitle ?? subtitle).font(.caption2.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
        }
        .onAppear { thumb.load(key: key, fileURL: fileURL, artwork: artwork, lookupName: lookupName) }
    }
}

struct GeneratedArt: View {
    let seed: String
    var body: some View {
        let h = Double(abs(seed.hashValue % 360)) / 360
        ZStack {
            LinearGradient(colors: [Color(hue: h, saturation: 0.5, brightness: 0.42),
                                    Color(hue: (h + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.16)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "film").font(.system(size: 28, weight: .light)).foregroundStyle(.white.opacity(0.25))
        }
    }
}

struct PrimaryChip: View {
    let icon: String
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.accent, in: Capsule())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}

struct SourceCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let host: String?
    var dashed = false
    @StateObject private var brand = BrandIconLoader()

    init(title: String, subtitle: String, icon: String, host: String?, dashed: Bool = false) {
        self.title = title; self.subtitle = subtitle; self.icon = icon; self.host = host; self.dashed = dashed
    }

    init(server: WebDAVServer) {
        self.init(title: server.name, subtitle: server.base?.host ?? server.baseURL, icon: "externaldrive.connected.to.line.below", host: server.base?.host)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                if let img = brand.image {
                    Image(uiImage: img).resizable().scaledToFit().frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Image(systemName: icon).font(.system(size: 18, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: 150, alignment: .leading)
        .padding(14)
        .background(Theme.card.opacity(dashed ? 0.4 : 1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            if dashed {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4])).foregroundStyle(.white.opacity(0.25))
            }
        }
        .onAppear { brand.load(host: host) }
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    @StateObject private var thumb = ThumbLoader()

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let img = thumb.image { Image(uiImage: img).resizable().scaledToFill() }
                else { GeneratedArt(seed: entry.item.displayTitle) }
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(thumb.meta?.name ?? entry.item.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: icon)
                    if let s = entry.item.subtitle ?? thumb.meta?.episodeTitle { Text(s).lineLimit(1) }
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
        .onAppear {
            thumb.load(key: entry.item.id, fileURL: nil, artwork: entry.item.artwork,
                       lookupName: entry.item.resolvedURL?.lastPathComponent ?? entry.item.title)
        }
    }

    private var icon: String {
        switch entry.item.source {
        case .webdav: return "externaldrive.connected.to.line.below"
        case .addon: return "puzzlepiece.extension"
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
                        .onDrop(of: [.url, .text], isTargeted: nil) { providers in
                            if let p = providers.first {
                                _ = p.loadObject(ofClass: URL.self) { u, _ in
                                    if let u { DispatchQueue.main.async { url = u.absoluteString } }
                                }
                            }
                            return true
                        }
                    Button("Paste") { url = UIPasteboard.general.string ?? "" }
                } header: { Text("Stream URL") } footer: { Text("HTTP(S), HLS (.m3u8), DASH, RTSP, RTMP, FTP, SMB and SFTP.") }
                Section("Optional headers") {
                    TextField("User-Agent", text: $userAgent).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Referer", text: $referer).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
            .navigationTitle("Open URL")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(!url.isEmpty)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Play") {
                        var m = MediaItem(url: url.trimmingCharacters(in: .whitespacesAndNewlines), title: "", source: .url)
                        if !userAgent.isEmpty { m.headers["User-Agent"] = userAgent }
                        if !referer.isEmpty { m.headers["Referer"] = referer }
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { PlayerPresenter.play(m) }
                    }
                    .disabled(URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme == nil)
                }
            }
        }
    }
}
