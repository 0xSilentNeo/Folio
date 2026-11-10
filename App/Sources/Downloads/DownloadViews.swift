import Combine
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
    private var dm: DownloadManager { .shared }
    /// This file's download, as last seen (1.25.0). Until then each button
    /// watched the whole manager, so every row of a folder (and the Network
    /// tab) redrew on each progress tick of any download, about 5 times a second.
    @State private var d: DownloadItem?

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            guard let d else {
                let subs = siblings.filter { $0.isSubtitle && SubtitleMatch.belongs($0.name, to: item.name) }
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
        .onAppear(perform: look)
        .onReceive(DownloadManager.shared.objectWillChange
            .throttle(for: .seconds(0.4), scheduler: DispatchQueue.main, latest: true)
            .receive(on: DispatchQueue.main)) { _ in look() }
    }

    /// Redraws only when this file's state or whole percent changed.
    private func look() {
        let now = dm.item(for: item.url)
        func key(_ x: DownloadItem?) -> String? { x.map { "\($0.id)|\($0.state.rawValue)|\(Int($0.progress * 100))" } }
        if key(now) != key(d) { d = now }
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
/// Whether the Downloads page is on screen as a page (pushed from Network):
/// the pill stays away then, as it would sit on the page's own speed bar
/// (1.24.1). The sheet covers the pill by itself.
@MainActor
final class DownloadsPage: ObservableObject {
    static let shared = DownloadsPage()
    @Published private(set) var shown = 0
    func appeared() { shown += 1 }
    func disappeared() { shown = max(0, shown - 1) }
}

struct DownloadPillOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var dm: DownloadManager { DownloadManager.shared }
    @State private var snap = DownloadPillSnapshot.now()
    @ObservedObject private var page = DownloadsPage.shared
    @ObservedObject private var lift = DownloadPillLift.shared
    @State private var showing = false
    @Namespace private var ns

    var body: some View {
        VStack {
            Spacer()
            if snap.hasWork && page.shown == 0 {
                pill
                    .padding(.bottom, 74 + lift.lift)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.7)))
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: snap.hasWork && page.shown == 0)
        .onReceive(DownloadManager.shared.objectWillChange
            .throttle(for: .seconds(0.5), scheduler: DispatchQueue.main, latest: true)
            .receive(on: DispatchQueue.main)) { _ in
            let now = DownloadPillSnapshot.now()
            if now != snap { snap = now }
        }
        .animation(.smooth(duration: 0.3), value: lift.lift)
        .sheet(isPresented: $showing) {
            NavigationStack { DownloadsView(inSheet: true) }
                .modifier(ZoomSheet(id: "downloads", ns: ns))
        }
    }

    private var pill: some View {
        HStack(spacing: 10) {
            Button { showing = true } label: {
                HStack(spacing: 10) {
                    PulsingDot(active: snap.active > 0)
                    Text(snap.active == 0 ? "Waiting" : speedString(snap.speed)).font(.subheadline.weight(.bold).monospacedDigit())
                    Text("\(snap.active) file\(snap.active == 1 ? "" : "s")").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    Sparkline(values: snap.history).frame(width: 54, height: 20)
                }
                .padding(.leading, 16).frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Downloads, \(speedString(snap.speed))")
            Button {
                snap.active == 0 ? dm.resumeAll() : dm.pauseAll()
                snap = DownloadPillSnapshot.now()      // the icon at the tap, not at the next refresh
            } label: {
                Image(systemName: snap.active == 0 ? "play.fill" : "pause.fill").font(.system(size: 12, weight: .bold))
                    .frame(width: 30, height: 30).background(Theme.fill, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 7)
            .accessibilityLabel(snap.active == 0 ? "Resume all downloads" : "Pause all downloads")
        }
        .glass(cornerRadius: 22, interactive: true)
        .shadow(color: Theme.shadow, radius: 12, y: 6)
        .modifier(ZoomSource2(id: "downloads", ns: ns))
    }
}

/// Room at the bottom of a page's list for the downloads pill while it
/// shows (1.24.1). The pill floats over every tab (DownloadPillOverlay) and
/// no page left room for it, so the end of a list stopped under it (7 Nov,
/// Home in the simulator: the last row under the pill). The pill's bottom
/// sits 74 pt above the screen's safe area and it's 44 pt tall; a page's own
/// safe area already ends at the tab bar (iPhone 17 Pro Max, iOS 26.5
/// simulator: pill 803 to 848 pt, tab bar from 873 pt), so the extra room is
/// what's left above it, with a little air.
///
/// Put on the page's List or ScrollView itself: an inset around a tab's
/// NavigationStack doesn't reach the list inside it (tried on Home: the
/// room was there, above the tab bar, and the list's end still went under).
struct DownloadPillRoom: ViewModifier {
    @ObservedObject private var page = DownloadsPage.shared
    /// Whether the pill shows, noted only when it changes (1.24.1): the
    /// download manager announces each progress tick, many a second, and
    /// this sits on whole pages (Home, Discover, Search).
    @State private var working = DownloadManager.shared.hasWork
    static let height: CGFloat = 78

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if working && page.shown == 0 { Color.clear.frame(height: Self.height).allowsHitTesting(false) }
        }
        .onReceive(DownloadManager.shared.objectWillChange
            .throttle(for: .seconds(0.5), scheduler: DispatchQueue.main, latest: true)
            .receive(on: DispatchQueue.main)) { _ in
            let now = DownloadManager.shared.hasWork
            if now != working { working = now }
        }
    }
}

extension View {
    func downloadPillRoom() -> some View { modifier(DownloadPillRoom()) }
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
        // From the pill's own shape, not its square (5 Nov).
        if #available(iOS 18.0, *) { content.matchedTransitionSource(id: id, in: ns) { $0.clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)) } } else { content }
    }
}

/// 1.25.0: the pulse starts whenever downloads start. It ran only from the
/// dot's first appearance, so a dot that appeared grey (all paused) stayed
/// still after Resume all.
struct PulsingDot: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        // Still with Reduce Motion on (1.27.0; it pulsed for as long as anything downloaded).
        if active && reduceMotion {
            Circle().fill(Theme.accent).frame(width: 8, height: 8)
        } else if active {
            Circle().fill(Theme.accent).frame(width: 8, height: 8)
                .phaseAnimator([false, true]) { dot, dim in
                    dot.opacity(dim ? 0.35 : 1).scaleEffect(dim ? 0.7 : 1)
                } animation: { _ in .easeInOut(duration: 0.7) }
        } else {
            Circle().fill(Color.secondary).frame(width: 8, height: 8)
        }
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
/// the speed card at the bottom.
///
/// A List since 1.24.1 (a ScrollView of every card and row until then):
/// - Its rows are made as they scroll in, and each row redraws only when its
///   own file changes (FileRow and PackageHeader are Equatable). Before, every
///   progress report (each running file twice a second, plus the speed once
///   a second) redrew every card and every row, finished ones included: 26
///   rows seven times a second while three files ran (7 Nov recordings:
///   scrolling and swiping stuttered).
/// - Folding a package removes its rows as rows: they leave in place. Until
///   1.24.1 the file list came and went as one block moved from its top edge
///   (move(edge: .top)), so a long package's files flew in from above the
///   screen, and the page jumped while the block changed size.
/// - Swipe actions are the system's (Delete, Remove, Cancel), with a full
///   swipe for the first, as in Mail and Files. Until 1.24.1 they were drawn
///   by hand (SwipeRow): the buttons stretched with the drag.
struct DownloadsView: View {
    var inSheet = false
    @ObservedObject private var dm = DownloadManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var filter: Filter = .all
    @State private var details = false
    @State private var confirmCancelAll = false
    /// A finished file to delete from the library, after asking.
    @State private var deleteAsk: DownloadItem?
    /// A package's question: cancel its unfinished files, or delete its files.
    @State private var packageAsk: PackageQuestion?
    /// Packages folded to their header (1.22.3), kept between launches.
    @State private var collapsed = DownloadCollapse.load()

    enum Filter: String, CaseIterable { case all = "All", active = "Active", queued = "Queued", done = "Done", failed = "Failed" }

    struct PackageQuestion: Identifiable {
        enum Kind { case cancel, deleteFiles }
        let name: String
        let kind: Kind
        var id: String { name + (kind == .cancel ? "|c" : "|d") }
    }

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
        let list = packages
        let speeds = dm.itemSpeeds
        List {
            filters
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 0, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            if list.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                    Text(dm.items.isEmpty ? "Nothing downloaded yet" : "Nothing here").font(.headline)
                    if dm.items.isEmpty {
                        Text("Open a folder on a WebDAV server and tap the download button next to a file.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity).padding(.top, 60).padding(.horizontal, 20)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            ForEach(list) { p in
                let folded = collapsed.contains(p.name)
                Section {
                    PackageHeader(name: p.name, all: p.all, collapsed: folded,
                                  onToggle: { toggle(p) },
                                  onAsk: { packageAsk = PackageQuestion(name: p.name, kind: $0) })
                        .equatable()
                        .listRowSeparator(.hidden, edges: .bottom)
                        .listRowInsets(EdgeInsets(top: 14, leading: 14, bottom: 12, trailing: 14))
                    if !folded {
                        ForEach(p.shown) { d in
                            FileRow(item: d, speed: d.state == .running ? speeds[d.id] : nil,
                                    connections: d.state == .running ? dm.connectionCount(d) : 0)
                                .equatable()
                                .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 6))
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) { swipeActions(d) }
                                .contextMenu { menu(d) }
                        }
                    }
                }
                .listRowBackground(Theme.card)
                .listRowSeparatorTint(Theme.hairline)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(16)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        // Packages no longer listed are forgotten.
        .onAppear {
            collapsed = DownloadCollapse.prune(keeping: Set(dm.items.map(\.package)))
            if !inSheet { DownloadsPage.shared.appeared() }
        }
        .onDisappear { if !inSheet { DownloadsPage.shared.disappeared() } }
        .confirmationDialog("Cancel all downloads that haven't finished? What they've downloaded so far is deleted.", isPresented: $confirmCancelAll, titleVisibility: .visible) {
            Button("Cancel all downloads", role: .destructive) { dm.cancelUnfinished() }
            Button("Keep them", role: .cancel) {}
        }
        .confirmationDialog(deleteAsk.map { "Delete \($0.fileName) from your library?" } ?? "",
                            isPresented: Binding(get: { deleteAsk != nil }, set: { if !$0 { deleteAsk = nil } }),
                            titleVisibility: .visible, presenting: deleteAsk) { d in
            Button("Delete file", role: .destructive) { dm.remove(d.id, deleteFile: true) }
        }
        .confirmationDialog(packageAsk.map { $0.kind == .cancel
                                ? "Cancel the downloads of \($0.name) that haven't finished? What they've downloaded so far is deleted."
                                : "Delete the downloaded files of \($0.name) from your library?" } ?? "",
                            isPresented: Binding(get: { packageAsk != nil }, set: { if !$0 { packageAsk = nil } }),
                            titleVisibility: .visible, presenting: packageAsk) { q in
            if q.kind == .cancel {
                Button("Cancel downloads", role: .destructive) { dm.cancelUnfinished(package: q.name) }
            } else {
                Button("Delete files", role: .destructive) { dm.removeFinished(package: q.name, deleteFiles: true) }
            }
        }
        .modifier(SpeedBar(show: dm.hasWork || !dm.items.isEmpty) { speedCard.padding(.horizontal, 16).padding(.bottom, 8) })
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

    /// Swipe left (27 Oct report: no way to delete a download): Delete (asks
    /// first) and Remove from the list for a finished file; Cancel for one
    /// that hasn't finished (what it downloaded is deleted). A full swipe
    /// runs the first.
    @ViewBuilder
    private func swipeActions(_ d: DownloadItem) -> some View {
        if d.state == .done {
            Button { deleteAsk = d } label: { Label("Delete", systemImage: "trash") }
                .tint(.red)
            Button { dm.remove(d.id) } label: { Label("Remove", systemImage: "xmark") }
                .tint(.gray)
        } else {
            Button(role: .destructive) { dm.remove(d.id) } label: { Label("Cancel", systemImage: "xmark") }
        }
    }

    @ViewBuilder
    private func menu(_ d: DownloadItem) -> some View {
        if d.state == .done, d.isMedia {
            Button { FileRow.play(d) } label: { Label("Play", systemImage: "play") }
        }
        if d.state == .running || d.state == .queued { Button { dm.pause(d.id) } label: { Label("Pause", systemImage: "pause") } }
        if d.state == .paused || d.state == .failed { Button { dm.resume(d.id) } label: { Label(d.state == .failed ? "Retry" : "Resume", systemImage: "arrow.clockwise") } }
        Button(role: .destructive) { dm.remove(d.id) } label: { Label(d.state == .done ? "Remove from list" : "Cancel", systemImage: "xmark") }
        if d.state == .done {
            Button(role: .destructive) { deleteAsk = d } label: { Label("Delete file", systemImage: "trash") }
        }
    }

    /// Folds a package to its header, or opens it again.
    private func toggle(_ p: Package) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy(duration: 0.3)) { collapsed = DownloadCollapse.toggle(p.name) }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases, id: \.self) { f in
                    let on = filter == f
                    Button { withAnimation(.snappy(duration: 0.3)) { filter = f } } label: {
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
        .scrollClipDisabled()
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
        // Card colour inside the glass (1.24.1): the rows passing under it
        // no longer read through it.
        .background(Theme.card.opacity(0.78), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
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

/// The speed card under the list. On iOS 26 a scroll view's own bar
/// (safeAreaBar, 1.24.1): rows passing under the card fade and blur behind
/// it, as under the system's toolbars. Until then a plain inset, and the
/// rows' text showed through the glass (7 Nov screenshot: a file name
/// across "25.2 MB/s · 3 active").
private struct SpeedBar<Bar: View>: ViewModifier {
    let show: Bool
    @ViewBuilder let bar: () -> Bar

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .safeAreaBar(edge: .bottom) { if show { bar() } }
                .scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            content.safeAreaInset(edge: .bottom) { if show { bar() } }
        }
        #else
        content.safeAreaInset(edge: .bottom) { if show { bar() } }
        #endif
    }
}

/// A package's first row: its picture, name, what's in and how much, its
/// pause or resume button and its menu, and the bar. A tap on the name folds
/// the package or opens it again.
private struct PackageHeader: View, Equatable {
    let name: String
    let all: [DownloadItem]
    /// Folded to its header (1.22.3).
    let collapsed: Bool
    var onToggle: () -> Void
    var onAsk: (DownloadsView.PackageQuestion.Kind) -> Void
    @StateObject private var thumb = ThumbLoader()

    static func == (a: PackageHeader, b: PackageHeader) -> Bool {
        a.name == b.name && a.collapsed == b.collapsed && a.all == b.all
    }

    var body: some View {
        let dm = DownloadManager.shared
        let total = all.reduce(Int64(0)) { $0 + $1.expected }
        let got = all.reduce(Int64(0)) { $0 + min($1.received, $1.expected) }
        let done = all.filter { $0.state == .done }.count
        let running = all.contains { $0.state == .running || $0.state == .queued }
        let resumable = all.contains { $0.state == .paused || $0.state == .failed }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                // The header up to the buttons folds the card (its own
                // buttons and menu keep their taps).
                Button(action: onToggle) {
                    HStack(spacing: 12) {
                        Color.clear.frame(width: 48, height: 48)
                            .overlay { if let img = thumb.image { Image(uiImage: img).resizable().scaledToFill() } else { GeneratedArt(seed: name) } }
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(name).font(.headline).lineLimit(1)
                                Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                            }
                            Text("\(got.byteString) of \(total.byteString) · \(done)/\(all.count) files").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(name), \(done) of \(all.count) files")
                .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
                .accessibilityHint(collapsed ? "Shows its files" : "Hides its files")
                .accessibilityIdentifier("downloads.package.\(name)")
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
        }
        .onAppear {
            if let first = all.first(where: \.isMedia) {
                thumb.load(key: first.url.absoluteString, fileURL: nil, artwork: nil, lookupName: first.fileName, art: .poster, points: 48)
            }
        }
    }

    /// Everything for the package in one place (27 Oct report: there was no
    /// visible way to delete downloads, paused or running).
    private func packageMenu(running: Bool, resumable: Bool, done: Int) -> some View {
        let dm = DownloadManager.shared
        return Menu {
            if running { Button { dm.pausePackage(name) } label: { Label("Pause all", systemImage: "pause") } }
            if resumable { Button { dm.resumePackage(name) } label: { Label("Resume all", systemImage: "play") } }
            if done > 0 {
                Button { dm.removeFinished(package: name, deleteFiles: false) } label: { Label("Remove finished from the list", systemImage: "checkmark.circle") }
                Button(role: .destructive) { onAsk(.deleteFiles) } label: { Label("Delete downloaded files", systemImage: "trash") }
            }
            if all.contains(where: { $0.state != .done }) {
                Button(role: .destructive) { onAsk(.cancel) } label: { Label("Cancel downloads", systemImage: "xmark.circle") }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .bold))
                .frame(width: 36, height: 36).menuLabelCircle()
                .contentShape(Circle())
        }
        // Glass on the menu, as the library's round menus (1.22.3): it opens
        // from a circle, not from the label's square.
        .glassMenuCircle()
        .accessibilityLabel("More for \(name)")
    }
}

/// One file of a package. Equatable (1.24.1): it redraws when its own file,
/// speed or connections change, not on every report of another file.
private struct FileRow: View, Equatable {
    let item: DownloadItem
    /// Bytes per second while it runs (DownloadManager.itemSpeeds), 1.24.1.
    let speed: Double?
    let connections: Int

    var body: some View {
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
        .padding(.vertical, 10)
        .frame(minHeight: 61)
    }

    /// "74.5 MB of 1.52 GB · 8.4 MB/s · 8 connections": a running file's
    /// own speed (1.24.1) beside its bytes, so the total under the list can
    /// be seen shared out.
    private var meta: String {
        switch item.state {
        case .running:
            var parts = ["\(item.received.byteString) of \(item.expected.byteString)"]
            if let speed, speed >= 1 { parts.append(speedString(speed)) }
            if connections > 1 { parts.append("\(connections) connections") }
            return parts.joined(separator: " · ")
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
        let dm = DownloadManager.shared
        switch item.state {
        case .running, .queued: dm.pause(item.id)
        case .paused, .failed: dm.resume(item.id)
        case .done: Self.play(item)
        }
    }

    static func play(_ item: DownloadItem) {
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

// MARK: - Folded packages

/// The packages folded to their header on the Downloads screen (1.22.3),
/// by name, kept in UserDefaults between launches.
enum DownloadCollapse {
    static let key = "downloadsCollapsedPackages"

    static func load(_ d: UserDefaults = .standard) -> Set<String> { Set(d.stringArray(forKey: key) ?? []) }

    /// Folds `name` or opens it again; returns all folded ones.
    @discardableResult
    static func toggle(_ name: String, in d: UserDefaults = .standard) -> Set<String> {
        var s = load(d)
        if s.remove(name) == nil { s.insert(name) }
        store(s, d)
        return s
    }

    /// Forgets the ones no longer on the list; returns those left.
    @discardableResult
    static func prune(keeping names: Set<String>, in d: UserDefaults = .standard) -> Set<String> {
        let s = load(d)
        let kept = s.intersection(names)
        if kept != s { store(kept, d) }
        return kept
    }

    private static func store(_ s: Set<String>, _ d: UserDefaults) {
        if s.isEmpty { d.removeObject(forKey: key) } else { d.set(s.sorted(), forKey: key) }
    }
}

// MARK: - Settings

struct DownloadSettingsView: View {
    @AppStorage(SettingsKey.downloadConcurrent) private var concurrent = 2
    @AppStorage(SettingsKey.downloadParts) private var parts = 8
    @AppStorage(SettingsKey.downloadAutoStart) private var autoStart = true
    @AppStorage(SettingsKey.downloadSaveTo) private var saveTo = "folder"
    @AppStorage(SettingsKey.downloadSkipExisting) private var skipExisting = true
    @AppStorage(SettingsKey.downloadNotify) private var notify = true
    @AppStorage(SettingsKey.downloadCellular) private var cellular = false
    @AppStorage(SettingsKey.downloadPauseLowPower) private var lowPower = true
    @AppStorage(SettingsKey.downloadOnlyCharging) private var charging = false
    @AppStorage(SettingsKey.downloadRetries) private var retries = 3
    @AppStorage(SettingsKey.downloadNextEpisodes) private var nextEpisodes = 0
    @AppStorage(SettingsKey.downloadDeleteWatched) private var deleteWatched = 0
    /// The Delete watched value waiting for a yes, and the yes.
    @State private var askDelete: Int?
    @State private var askingDelete = false
    @State private var deleteConfirmed = false
    @AppStorage(SettingsKey.liveActivities) private var liveActivities = true

    var body: some View {
        Form {
            Section {
                Stepper(value: $concurrent, in: 1...6) { LabeledContent("Simultaneous downloads", value: "\(concurrent)") }
                Stepper(value: $parts, in: 1...8) { LabeledContent("Connections per file", value: "\(parts)") }
                Toggle("Start automatically", isOn: $autoStart)
            } header: { Text("Queue") } footer: {
                Text("Connections: a file downloads over up to that many connections at once when the server allows it. One that finishes early takes over half of the biggest part left, and one far slower than the others starts again. That helps most with a server that is slow per connection. Start automatically off: a tapped file waits, paused, until you start it on the Downloads screen.")
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
                Stepper(value: $retries, in: 0...10) { LabeledContent("Retries on error", value: "\(retries)") }
            } header: { Text("Network & battery") } footer: {
                Text("Folio downloads files itself, not through iOS's background downloads. On iOS 26 and later they carry on in the background with iOS's own progress on the Lock Screen and in the Dynamic Island; its stop button pauses them. On older iOS they pause a little after you leave Folio and carry on when you're back. A paused file continues where it stopped.")
            }
            // 1.22.0: AutoDownload and WatchedCleanup.
            Section {
                Picker("Download next episodes", selection: $nextEpisodes) {
                    Text("Off").tag(0)
                    Text("Next 1").tag(1)
                    Text("Next 2").tag(2)
                    Text("Next 3").tag(3)
                }
                Picker("Delete watched downloads", selection: $deleteWatched) {
                    Text("Off").tag(0)
                    Text("After 1 day").tag(1)
                    Text("After 7 days").tag(7)
                }
            } header: { Text("Automatic") } footer: {
                Text("Next episodes: when you've watched most of an episode from a WebDAV server, or one downloaded from it, the next ones in its folder download, on Wi-Fi only. Delete: a downloaded video you've finished leaves your library that long after you finished it, with its subtitles; turning it on also removes the ones finished longer ago than that. Files you added yourself are never deleted.")
            }
            Section {
                Toggle("Live Activities", isOn: $liveActivities)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Downloads, on the Lock Screen and in the Dynamic Island. What's playing shows in Control Center and on the Lock Screen.")
                    if liveActivities && LiveActivities.blockedBySystem {
                        Text("They're turned off for Folio in iOS Settings → Folio.")
                    }
                }
            }
        }
        .brandListBackground()
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: concurrent) { _, _ in DownloadManager.shared.settingsChanged() }
        .onChange(of: lowPower) { _, _ in DownloadManager.shared.settingsChanged() }
        .onChange(of: charging) { _, _ in DownloadManager.shared.settingsChanged() }
        .onChange(of: liveActivities) { _, _ in LiveActivities.settingChanged() }
        // Turning it on deletes finished downloads at once: asked first (1.26.1).
        .onChange(of: deleteWatched) { old, new in
            if old == 0, new > 0, !deleteConfirmed {
                askDelete = new
                askingDelete = true
                deleteWatched = 0
                return
            }
            deleteConfirmed = false
            if new > 0 { WatchedCleanup.run() }
        }
        .confirmationDialog("Delete watched downloads?", isPresented: $askingDelete, titleVisibility: .visible, presenting: askDelete) { days in
            Button(days == 1 ? "Delete After 1 Day" : "Delete After \(days) Days", role: .destructive) {
                deleteConfirmed = true
                deleteWatched = days
            }
        } message: { days in
            Text("Downloaded videos you finished more than \(days == 1 ? "a day" : "\(days) days") ago are deleted now, and others that long after you finish them. Files you added yourself are never deleted.")
        }
    }
}
