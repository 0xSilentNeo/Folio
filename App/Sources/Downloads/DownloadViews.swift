import SwiftUI

// MARK: - Row button (WebDAV folders)

/// On the right of a WebDAV file row, vertically centred: download, then a
/// ring that fills (tap to pause / resume), then a check.
struct DownloadButton: View {
    let item: DAVItem
    let server: WebDAVServer
    let package: String
    /// Subtitle files in the same folder; the ones that match come along.
    var siblings: [DAVItem] = []
    @ObservedObject private var dm = DownloadManager.shared

    var body: some View {
        let d = dm.item(for: item.url)
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            guard let d else {
                let base = (item.name as NSString).deletingPathExtension.lowercased()
                let subs = siblings.filter { $0.isSubtitle && $0.name.lowercased().hasPrefix(base) }
                dm.enqueue([item] + subs, server: server, package: package)
                return
            }
            switch d.state {
            case .running, .queued: dm.pause(d.id)
            case .paused, .failed: dm.resume(d.id)
            case .done: break
            }
        } label: {
            ZStack {
                Circle().fill(d?.state == .done ? Theme.accent : Theme.fill)
                if let d, d.state != .done {
                    Circle().stroke(Theme.hairline, lineWidth: 3).padding(4)
                    Circle().trim(from: 0, to: max(0.02, d.progress))
                        .stroke(d.state == .failed ? Color.orange : Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90)).padding(4)
                        .animation(.linear(duration: 0.4), value: d.progress)
                }
                Image(systemName: icon(d)).font(.system(size: d == nil ? 14 : 11, weight: .bold))
                    .foregroundStyle(d?.state == .done ? Theme.onAccent : (d?.state == .failed ? Color.orange : .primary))
            }
            .frame(width: 36, height: 36)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label(d))
    }

    private func icon(_ d: DownloadItem?) -> String {
        guard let d else { return "arrow.down" }
        switch d.state {
        case .running: return "pause.fill"
        case .queued: return "clock"
        case .paused: return "play.fill"
        case .failed: return "arrow.clockwise"
        case .done: return "checkmark"
        }
    }

    private func label(_ d: DownloadItem?) -> String {
        guard let d else { return "Download" }
        switch d.state {
        case .running: return "Downloading \(Int(d.progress * 100)) percent, pause"
        case .queued: return "Queued, pause"
        case .paused: return "Paused, resume download"
        case .failed: return "Download failed, retry"
        case .done: return "Downloaded"
        }
    }
}

// MARK: - Floating speed pill

/// Bottom of the screen while anything downloads: speed, file count, a
/// sparkline and pause / resume. Tap: the Downloads screen.
struct DownloadPillOverlay: View {
    @ObservedObject private var dm = DownloadManager.shared
    @State private var showing = false
    @Namespace private var ns

    var body: some View {
        VStack {
            Spacer()
            if dm.hasWork {
                pill
                    .padding(.bottom, 74)
                    .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.7)))
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: dm.hasWork)
        .sheet(isPresented: $showing) {
            NavigationStack { DownloadsView(inSheet: true) }
                .modifier(ZoomSheet(id: "downloads", ns: ns))
        }
    }

    private var pill: some View {
        HStack(spacing: 10) {
            Button { showing = true } label: {
                HStack(spacing: 10) {
                    PulsingDot(active: !dm.active.isEmpty)
                    Text(dm.active.isEmpty ? "Waiting" : speedString(dm.speed)).font(.subheadline.weight(.bold).monospacedDigit())
                    Text("\(dm.active.count) file\(dm.active.count == 1 ? "" : "s")").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    Sparkline(values: dm.speedHistory).frame(width: 54, height: 20)
                }
                .padding(.leading, 16).frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Downloads, \(speedString(dm.speed))")
            Button {
                dm.active.isEmpty ? dm.resumeAll() : dm.pauseAll()
            } label: {
                Image(systemName: dm.active.isEmpty ? "play.fill" : "pause.fill").font(.system(size: 12, weight: .bold))
                    .frame(width: 30, height: 30).background(Theme.fill, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 7)
            .accessibilityLabel(dm.active.isEmpty ? "Resume all downloads" : "Pause all downloads")
        }
        .glass(cornerRadius: 22, interactive: true)
        .shadow(color: Theme.shadow, radius: 12, y: 6)
        .modifier(ZoomSource2(id: "downloads", ns: ns))
    }
}

/// The sheet zooms out of the pill (as Add files does from its button).
private struct ZoomSheet: ViewModifier {
    let id: String
    let ns: Namespace.ID
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) { content.navigationTransition(.zoom(sourceID: id, in: ns)) } else { content }
    }
}
private struct ZoomSource2: ViewModifier {
    let id: String
    let ns: Namespace.ID
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) { content.matchedTransitionSource(id: id, in: ns) } else { content }
    }
}

struct PulsingDot: View {
    let active: Bool
    @State private var on = false
    var body: some View {
        Circle().fill(active ? Theme.accent : Color.secondary).frame(width: 8, height: 8)
            .opacity(active && on ? 0.35 : 1).scaleEffect(active && on ? 0.7 : 1)
            .animation(active ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default, value: on)
            .onAppear { on = true }
    }
}

struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { g in
            let maxV = max(values.max() ?? 1, 1)
            Path { p in
                for (i, v) in values.enumerated() {
                    let x = g.size.width * CGFloat(i) / CGFloat(max(1, values.count - 1))
                    let y = g.size.height * (1 - CGFloat(v / maxV)) * 0.9 + 1
                    i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

func speedString(_ bps: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .file) + "/s"
}

// MARK: - Downloads screen

/// Packages (one per server folder) with their files, filters at the top and
/// the speed card at the bottom — laid out like GetRekt's Downloads screen.
struct DownloadsView: View {
    var inSheet = false
    @ObservedObject private var dm = DownloadManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var filter: Filter = .all
    @State private var details = false
    /// The file row whose swipe actions are open.
    @State private var openRow: String?
    @State private var confirmCancelAll = false

    enum Filter: String, CaseIterable { case all = "All", active = "Active", queued = "Queued", done = "Done", failed = "Failed" }

    private func matches(_ d: DownloadItem, _ f: Filter) -> Bool {
        switch f {
        case .all: return true
        case .active: return d.state == .running || (d.state == .paused && d.received > 0)
        case .queued: return d.state == .queued || (d.state == .paused && d.received == 0)
        case .done: return d.state == .done
        case .failed: return d.state == .failed
        }
    }

    struct Package: Identifiable { let name: String; let all: [DownloadItem]; let shown: [DownloadItem]; var id: String { name } }

    private var packages: [Package] {
        var order: [String] = []
        var by: [String: [DownloadItem]] = [:]
        for d in dm.items {
            if by[d.package] == nil { order.append(d.package) }
            by[d.package, default: []].append(d)
        }
        return order.reversed().compactMap { n in
            let all = by[n]!
            let shown = all.filter { matches($0, filter) }
            return shown.isEmpty ? nil : Package(name: n, all: all, shown: shown)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                filters
                if packages.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                        Text(dm.items.isEmpty ? "Nothing downloaded yet" : "Nothing here").font(.headline)
                        if dm.items.isEmpty {
                            Text("Open a folder on a WebDAV server and tap the download button next to a file.")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.top, 60).padding(.horizontal, 20)
                }
                ForEach(packages) { p in PackageCard(name: p.name, all: p.all, shown: p.shown, openRow: $openRow) }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 120)
        }
        .scrollIndicators(.hidden)
        .confirmationDialog("Cancel all downloads that haven't finished? What they've downloaded so far is deleted.", isPresented: $confirmCancelAll, titleVisibility: .visible) {
            Button("Cancel all downloads", role: .destructive) { dm.cancelUnfinished() }
            Button("Keep them", role: .cancel) {}
        }
        .safeAreaInset(edge: .bottom) { if dm.hasWork || !dm.items.isEmpty { speedCard.padding(.horizontal, 16).padding(.bottom, 8) } }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Downloads")
        .toolbar {
            if inSheet {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { dm.resumeAll() } label: { Label("Resume all", systemImage: "play") }
                    Button { dm.pauseAll() } label: { Label("Pause all", systemImage: "pause") }
                    Button { dm.clearFinished() } label: { Label("Clear finished", systemImage: "checkmark.circle") }
                    if dm.items.contains(where: { $0.state != .done }) {
                        Button(role: .destructive) { confirmCancelAll = true } label: { Label("Cancel all downloads", systemImage: "xmark.circle") }
                    }
                } label: { ToolbarGlyph("ellipsis") }
                .accessibilityLabel("More")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { DownloadSettingsView() } label: { ToolbarGlyph("slider.horizontal.3") }
                    .accessibilityLabel("Download settings")
            }
        }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases, id: \.self) { f in
                    let on = filter == f
                    Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { filter = f } } label: {
                        HStack(spacing: 6) {
                            Text(f.rawValue)
                            Text("\(dm.items.filter { matches($0, f) }.count)").opacity(0.6)
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(on ? Theme.onAccent : .primary)
                        .padding(.horizontal, 14).frame(height: 34)
                        .background(on ? Theme.accent : Theme.fill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 4)
    }

    private var speedCard: some View {
        let running = dm.active
        let left = dm.items.filter { $0.state != .done }.reduce(Int64(0)) { $0 + max(0, $1.expected - $1.received) }
        let total = dm.items.reduce(Int64(0)) { $0 + $1.expected }
        let got = dm.items.reduce(Int64(0)) { $0 + min($1.received, $1.expected) }
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { details.toggle() } } label: {
                    HStack(spacing: 10) {
                        PulsingDot(active: !running.isEmpty)
                        Text(running.isEmpty ? (dm.hasWork ? "Waiting" : "Idle") : speedString(dm.speed)).font(.subheadline.weight(.bold).monospacedDigit())
                        Text("\(running.count) active").font(.subheadline).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Sparkline(values: dm.speedHistory).frame(width: 70, height: 22)
                    }
                    .padding(.leading, 16).frame(height: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(details ? "Hides the details" : "Shows progress, remaining and time left")
                Button { running.isEmpty ? dm.resumeAll() : dm.pauseAll() } label: {
                    Image(systemName: running.isEmpty ? "play.fill" : "pause.fill").font(.system(size: 13, weight: .bold))
                        .frame(width: 34, height: 34).background(Theme.fill, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 9)
                .accessibilityLabel(running.isEmpty ? "Resume all" : "Pause all")
            }
            if details {
                HStack {
                    stat("Progress", total > 0 ? "\(Int(Double(got) / Double(total) * 100))%" : "—")
                    stat("Remaining", left.byteString)
                    stat("Time left", dm.speed > 1 ? Self.duration(Double(left) / dm.speed) : "—")
                }
                .padding(.horizontal, 16).padding(.bottom, 14)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .glass(cornerRadius: 26)
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Text(v).font(.subheadline.weight(.bold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func duration(_ s: Double) -> String {
        let t = Int(s)
        return t >= 3600 ? "\(t / 3600)h \(t % 3600 / 60)m" : "\(t / 60)m \(t % 60)s"
    }
}

private struct PackageCard: View {
    let name: String
    let all: [DownloadItem]
    let shown: [DownloadItem]
    @Binding var openRow: String?
    @ObservedObject private var dm = DownloadManager.shared
    @StateObject private var thumb = ThumbLoader()
    @State private var ask: Question?

    /// Questions before anything is deleted.
    enum Question: Identifiable { case cancel, deleteFiles; var id: Int { self == .cancel ? 0 : 1 } }

    var body: some View {
        let total = all.reduce(Int64(0)) { $0 + $1.expected }
        let got = all.reduce(Int64(0)) { $0 + min($1.received, $1.expected) }
        let done = all.filter { $0.state == .done }.count
        let running = all.contains { $0.state == .running || $0.state == .queued }
        let resumable = all.contains { $0.state == .paused || $0.state == .failed }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Color.clear.frame(width: 48, height: 48)
                    .overlay { if let img = thumb.image { Image(uiImage: img).resizable().scaledToFill() } else { GeneratedArt(seed: name) } }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.headline).lineLimit(1)
                    Text("\(got.byteString) of \(total.byteString) · \(done)/\(all.count) files").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 0)
                if running || resumable {
                    Button { running ? dm.pausePackage(name) : dm.resumePackage(name) } label: {
                        Image(systemName: running ? "pause.fill" : "play.fill").font(.system(size: 13, weight: .bold))
                            .frame(width: 36, height: 36).background(Theme.fill, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(running ? "Pause \(name)" : "Resume \(name)")
                } else {
                    Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(Theme.accent)
                }
                packageMenu(running: running, resumable: resumable, done: done)
            }
            ThinBar(progress: total > 0 ? Double(got) / Double(total) : 0, height: 4)
            VStack(spacing: 0) {
                ForEach(shown) { d in
                    Divider().overlay(Theme.hairline)
                    FileRow(item: d, openRow: $openRow)
                }
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: Theme.shadow.opacity(0.5), radius: 10, y: 4)
        .confirmationDialog(ask == .cancel ? "Cancel the downloads of \(name) that haven't finished? What they've downloaded so far is deleted."
                                               : "Delete the downloaded files of \(name) from your library?",
                            isPresented: Binding(get: { ask != nil }, set: { if !$0 { ask = nil } }), titleVisibility: .visible) {
            if ask == .cancel {
                Button("Cancel downloads", role: .destructive) { dm.cancelUnfinished(package: name) }
            } else {
                Button("Delete files", role: .destructive) { dm.removeFinished(package: name, deleteFiles: true) }
            }
        }
        .onAppear {
            if let first = all.first(where: \.isMedia) {
                thumb.load(key: first.url.absoluteString, fileURL: nil, artwork: nil, lookupName: first.fileName, art: .poster, points: 48)
            }
        }
    }
}

private extension PackageCard {
    /// Everything for the package in one place (27 Oct report: there was no
    /// visible way to delete downloads, paused or running).
    func packageMenu(running: Bool, resumable: Bool, done: Int) -> some View {
        Menu {
            if running { Button { dm.pausePackage(name) } label: { Label("Pause all", systemImage: "pause") } }
            if resumable { Button { dm.resumePackage(name) } label: { Label("Resume all", systemImage: "play") } }
            if done > 0 {
                Button { dm.removeFinished(package: name, deleteFiles: false) } label: { Label("Remove finished from the list", systemImage: "checkmark.circle") }
                Button(role: .destructive) { ask = .deleteFiles } label: { Label("Delete downloaded files", systemImage: "trash") }
            }
            if all.contains(where: { $0.state != .done }) {
                Button(role: .destructive) { ask = .cancel } label: { Label("Cancel downloads", systemImage: "xmark.circle") }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .bold))
                .frame(width: 36, height: 36).background(Theme.fill, in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel("More for \(name)")
    }
}

private struct FileRow: View {
    let item: DownloadItem
    @Binding var openRow: String?
    @ObservedObject private var dm = DownloadManager.shared
    @State private var confirmDelete = false

    /// Swipe left (27 Oct report: no way to delete a download): Cancel for
    /// one that hasn't finished (what it downloaded is deleted), Delete
    /// (asks first) and Remove from the list for a finished one.
    private var swipe: [SwipeAction] {
        if item.state == .done {
            return [SwipeAction(title: "Delete", icon: "trash", tint: .red) { confirmDelete = true },
                    SwipeAction(title: "Remove", icon: "xmark", tint: .gray) { dm.remove(item.id) }]
        }
        return [SwipeAction(title: "Cancel", icon: "xmark", tint: .red) { dm.remove(item.id) }]
    }

    var body: some View {
        SwipeRow(id: item.id.uuidString, openID: $openRow, actions: swipe) { row }
            .confirmationDialog("Delete \(item.fileName) from your library?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete file", role: .destructive) { dm.remove(item.id, deleteFile: true) }
            }
    }

    private var row: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.fileName).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(meta).font(.caption2).foregroundStyle(item.state == .failed ? Color.orange : .secondary).lineLimit(1).monospacedDigit()
                if item.state != .done { ThinBar(progress: item.progress, height: 3, tint: item.state == .failed ? .orange : Theme.accent) }
            }
            Spacer(minLength: 0)
            Button { act() } label: {
                Image(systemName: icon).font(.system(size: 13, weight: .bold))
                    .foregroundStyle(item.state == .failed ? Color.orange : (item.state == .done ? Theme.accent : .primary))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(item.state == .done && !item.isMedia)
            .accessibilityLabel(actionLabel)
        }
        .frame(minHeight: 61)
        .background(Theme.card)
        .contextMenu {
            if item.state == .done, item.isMedia {
                Button { play() } label: { Label("Play", systemImage: "play") }
            }
            if item.state == .running || item.state == .queued { Button { dm.pause(item.id) } label: { Label("Pause", systemImage: "pause") } }
            if item.state == .paused || item.state == .failed { Button { dm.resume(item.id) } label: { Label(item.state == .failed ? "Retry" : "Resume", systemImage: "arrow.clockwise") } }
            Button(role: .destructive) { dm.remove(item.id) } label: { Label(item.state == .done ? "Remove from list" : "Cancel", systemImage: "xmark") }
            if item.state == .done {
                Button(role: .destructive) { dm.remove(item.id, deleteFile: true) } label: { Label("Delete file", systemImage: "trash") }
            }
        }
    }

    private var meta: String {
        switch item.state {
        case .running: return "\(item.received.byteString) of \(item.expected.byteString)"
        case .queued: return "Queued · \(item.expected.byteString)" + (item.held ? " · waiting" : "")
        case .paused: return "Paused · \(item.received.byteString) of \(item.expected.byteString)"
        case .failed: return item.error ?? "Failed"
        case .done: return "\(item.expected.byteString) · in your library"
        }
    }

    private var icon: String {
        switch item.state {
        case .running: return "pause.fill"
        case .queued: return "clock"
        case .paused: return "play.fill"
        case .failed: return "arrow.clockwise"
        case .done: return item.isMedia ? "play.circle.fill" : "checkmark"
        }
    }

    private var actionLabel: String {
        switch item.state {
        case .running, .queued: return "Pause \(item.fileName)"
        case .paused: return "Resume \(item.fileName)"
        case .failed: return "Retry \(item.fileName)"
        case .done: return "Play \(item.fileName)"
        }
    }

    private func act() {
        switch item.state {
        case .running, .queued: dm.pause(item.id)
        case .paused, .failed: dm.resume(item.id)
        case .done: play()
        }
    }

    private func play() {
        var m = MediaItem(url: item.destination.path, title: TitleParser.clean(item.fileName), source: .local)
        m.historyKey = item.destination.path
        PlayerPresenter.play(m)
    }
}

struct ThinBar: View {
    let progress: Double
    var height: CGFloat = 4
    var tint: Color = Theme.accent
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fill)
                Capsule().fill(tint).frame(width: max(height, g.size.width * min(1, max(0, progress))))
                    .animation(.linear(duration: 0.4), value: progress)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Settings

struct DownloadSettingsView: View {
    @AppStorage(SettingsKey.downloadConcurrent) private var concurrent = 2
    @AppStorage(SettingsKey.downloadAutoStart) private var autoStart = true
    @AppStorage(SettingsKey.downloadSaveTo) private var saveTo = "folder"
    @AppStorage(SettingsKey.downloadSkipExisting) private var skipExisting = true
    @AppStorage(SettingsKey.downloadNotify) private var notify = true
    @AppStorage(SettingsKey.downloadCellular) private var cellular = false
    @AppStorage(SettingsKey.downloadPauseLowPower) private var lowPower = true
    @AppStorage(SettingsKey.downloadOnlyCharging) private var charging = false
    @AppStorage(SettingsKey.downloadRetries) private var retries = 3

    var body: some View {
        Form {
            Section {
                Stepper("Simultaneous downloads: \(concurrent)", value: $concurrent, in: 1...6)
                Toggle("Start automatically", isOn: $autoStart)
            } header: { Text("Queue") } footer: {
                Text("Off: a tapped file waits, paused, until you start it on the Downloads screen. More than two at once rarely helps on one WebDAV server.")
            }
            Section("Saving") {
                Picker("Save to", selection: $saveTo) {
                    Text("Library · folder per show").tag("folder")
                    Text("Library").tag("root")
                }
                Toggle("Skip files already downloaded", isOn: $skipExisting)
                Toggle("Notify when finished", isOn: $notify)
                    .onChange(of: notify) { _, on in if on { DownloadManager.askForNotifications() } }
            }
            Section {
                Toggle("Use mobile data", isOn: $cellular)
                Toggle("Pause in Low Power Mode", isOn: $lowPower)
                Toggle("Only while charging", isOn: $charging)
                Stepper("Retries on error: \(retries)", value: $retries, in: 0...10)
            } header: { Text("Network & battery") } footer: {
                Text("Downloads carry on in the background (iOS decides how fast while Folio isn't open). A paused file continues where it stopped. There is no speed limit: iOS doesn't let background downloads be slowed down.")
            }
        }
        .brandListBackground()
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
    }
}
