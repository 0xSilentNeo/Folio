import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var local = LocalMediaStore.shared
    @State private var showOpenURL = false
    @State private var addServer = false
    @State private var showAddFiles = false

    @State private var path: [LibraryRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { geo in
                let wide = geo.size.width > 700
                let margin: CGFloat = wide ? 28 : 20
                // A List (1.17.0) so library rows have the system's swipe actions
                // ("Adds custom swipe actions to a row in a list" — swipeActions docs);
                // the rest are plain full-width rows.
                List {
                    Group {
                        header(margin).padding(.top, 6)
                        if !history.continueWatching.isEmpty { continueWatching(width: geo.size.width, wide: wide, margin: margin).padding(.top, 30) }
                        if !local.files.isEmpty { libraryHeader(margin).padding(.top, 30) }
                        else { howToAdd(margin).padding(.top, history.continueWatching.isEmpty ? 70 : 40) }
                    }
                    .homeRow()
                    if !local.files.isEmpty { libraryRows(width: geo.size.width, margin: margin) }
                    Color.clear.frame(height: 28).homeRow()
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .environment(\.defaultMinListRowHeight, 0)
            }
            .background(HomeBackdrop().ignoresSafeArea())
            .background(TouchTracker.Host().frame(width: 0, height: 0).accessibilityHidden(true))
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { local.refresh() }
            .sheet(isPresented: $showOpenURL) { OpenURLSheet() }
            .sheet(isPresented: $addServer) { ServerEditView(server: nil) }
            .sheet(isPresented: $showAddFiles) { addFilesSheet }
            .background(PathWatch(path: $path, pending: pending) { openPending() })
            .navigationDestination(for: LibraryRoute.self) { route in destination(route) }
            .onChange(of: libraryView) { old, new in LibTrace.zoom.log("home layout \(old) → \(new)") }
        }
    }

    /// Pages open from list rows with the usual push (ListTransition.push).
    /// Those pages show the system bar: with it hidden, UIKit's swipe back
    /// doesn't start (lab, 28 Oct: an edge swipe on a pushed page with its
    /// own bar did nothing).
    private var listPushes: Bool {
        (LibraryViewMode(rawValue: libraryView) ?? .grid) != .grid && ListTransition.current == .push
    }

    /// Opens a page from Home: on top of Home, as a page of its own.
    ///
    /// Home's buttons are only there to tap when Home is what you see, so a
    /// path that isn't empty belongs to a page that went back and isn't on
    /// screen any more. SwiftUI drops it from the path once that page's move
    /// is over (28 Oct log: 62 ms after the page was gone). A title tapped
    /// before that opens then, as a page of its own:
    /// - 1.17.3 added it behind the old one ("home path 1 → 2: [mobland,
    ///   classroom]"), and SwiftUI kept the old page alive out of sight.
    /// - 1.17.4 replaced the old one (`path = [route]`), and SwiftUI reused
    ///   the old page for the new title: your 19:23 recording opens Classroom
    ///   with MobLand's title on it, and its page never ran onAppear.
    private func open(_ route: LibraryRoute) {
        if path.isEmpty { path.append(route); return }
        pending.route = route                     // the latest tap wins
        guard !pending.waiting else { return }
        pending.waiting = true
        dlog("nav", "home: \(route) opens when the page going back is gone (path \(path.count))")
        BackWatch.whenGone { gone in
            guard gone else {
                // The swipe back was let go: that page stays, and it's what you see.
                dlog("nav", "home: the page stayed; \(pending.route.map { "\($0)" } ?? "nothing") not opened")
                pending.route = nil
                pending.waiting = false
                return
            }
            // Normally SwiftUI empties the path first (onChange below).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { openPending(after: "SwiftUI kept the page in its path") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { openPending(after: "still waiting after 3 s") }
    }

    private func openPending(after why: String? = nil) {
        guard let r = pending.route else { return }
        pending.route = nil
        pending.waiting = false
        if let why { dlog("nav", "home: opening \(r) (\(why))") }
        path.append(r)
    }

    /// Logs each change of the path and opens a title that waited for a page
    /// going back (open(_:)). A view of its own: reading the path in Home's
    /// body made every page opening and closing redraw all of Home (28 Oct
    /// profile: Home's library worked out again at each).
    private struct PathWatch: View {
        @Binding var path: [LibraryRoute]
        let pending: PendingOpen
        let openPending: () -> Void
        var body: some View {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .onChange(of: path) { old, new in
                    dlog("nav", "home path \(old.count) → \(new.count): \(new)")
                    // Trace: where each zoom source of the page is, as it opens
                    // and for 2.5 s after it went back.
                    if new.count > old.count, let r = new.last, let id = r.zoomID { ZoomProbe.dump(id, "opening \(r)") }
                    if new.count < old.count, let r = old.last, let id = r.zoomID { ZoomProbe.timeline(id, "back from \(r)") }
                    if new.isEmpty, pending.route != nil { DispatchQueue.main.async { openPending() } }
                }
        }
    }

    /// A title tapped while a page was still going back (open(_:)).
    final class PendingOpen {
        var route: LibraryRoute?
        var waiting = false
    }
    @State private var pending = PendingOpen()

    /// Settings zooms out of its button, a title page out of its poster (iOS 18+).
    @ViewBuilder
    private func destination(_ route: LibraryRoute) -> some View {
        switch route {
        case .settings:
            SettingsView().zoomDestination("settings", in: zoomNS)
        case .group(let id):
            LibraryRoute.destination(route).zoomDestination(id, in: zoomNS, zoom: !listPushes)
        case .folder(let path):
            LibraryRoute.destination(route).zoomDestination("d|" + path, in: zoomNS, zoom: !listPushes)
        default:
            LibraryRoute.destination(route)
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
        .foregroundStyle(.primary)
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
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    FolioLeaf().frame(width: 30, height: 30).padding(.leading, -5)
                    Wordmark(size: 24)
                }
            }
            Spacer()
            Menu {
                Button { showAddFiles = true } label: { Label("Add files or folders", systemImage: "folder.badge.plus") }
                Button { showOpenURL = true } label: { Label("Open URL", systemImage: "link") }
                Button { pasteAndPlay() } label: { Label("Paste & play", systemImage: "doc.on.clipboard") }
                Divider()
                Button { addServer = true } label: { Label("Add WebDAV server", systemImage: "externaldrive.connected.to.line.below") }
            } label: {
                Image(systemName: "plus").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44).glassCircle()
            }
            .accessibilityLabel("Add")
            settingsLink
        }
        .padding(.horizontal, margin)
        .padding(.top, 8)
    }

    @Namespace private var zoomNS

    @ViewBuilder
    private var settingsLink: some View {
        // A button that pushes, not a NavigationLink: Home is a List, where a
        // NavigationLink turns its whole row into a link.
        if #available(iOS 18.0, *) {
            Button { open(.settings) } label: {
                Image(systemName: "gearshape").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44).glassCircle()
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Settings")
            .matchedTransitionSource(id: "settings", in: zoomNS)
        } else {
            Button { open(.settings) } label: {
                Image(systemName: "gearshape").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44).glassCircle()
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Settings")
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
        let cardW: CGFloat = wide ? 320 : min(340, width - margin * 2 - 44)
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Continue Watching", margin)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 20) {
                    ForEach(items) { e in
                        HeroCard(entry: e, height: cardW * 9 / 16 + 8)
                            .frame(width: cardW)
                            .onTapGesture { ContinueQueue.play(e.item) }
                            .contextMenu { historyMenu(e) }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, margin)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollClipDisabled()
            // Back from the player, the row starts at the card just watched.
            .id(items.first?.id)
        }
    }

    private func howToAdd(_ margin: CGFloat) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.accent)
            Text("Your library is empty").font(.headline)
            Text("Add videos from the Files app, paste a link with **+**, or copy files into\n**Files → On My iPhone → Folio → Media**.\nWebDAV servers like Real-Debrid live under Network.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            addFilesButton(large: true).padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, margin + 10)
        .padding(.vertical, 30)
    }

    // MARK: Library

    @AppStorage("libraryView") private var libraryView = LibraryViewMode.grid.rawValue
    @AppStorage("librarySort") private var librarySort: LibrarySort = .name
    @AppStorage("librarySortAsc") private var librarySortAsc = true
    @AppStorage(SettingsKey.openTitlePage) private var openTitlePage = true

    private var groups: [LibraryGroup] {
        LibraryOrganizer.groups(local.files, sort: librarySort, ascending: librarySortAsc)
    }

    @AppStorage(SettingsKey.tileArtwork) private var tileArtwork = "poster"

    @State private var pendingDelete: LibraryGroup?

    /// The delete question, attached to the title's own tile or row so it
    /// points at it (iOS shows confirmation dialogs as a popover from the view
    /// they're attached to).
    private func askToDelete<V: View>(_ g: LibraryGroup, _ v: V) -> some View {
        v.confirmationDialog(deleteQuestion(g),
                             isPresented: Binding(get: { pendingDelete?.id == g.id }, set: { if !$0, pendingDelete?.id == g.id { pendingDelete = nil } }),
                             titleVisibility: .visible) {
            Button("Delete", role: .destructive) { local.delete(g.folder.map { [$0] } ?? g.files) }
        }
    }

    private func deleteQuestion(_ g: LibraryGroup) -> String {
        if g.folder != nil { return "Delete the folder \(g.title) and its \(g.count) item\(g.count == 1 ? "" : "s") (\(g.size.byteString))?" }
        if g.count > 1 { return "Delete all \(g.count) episodes of \(g.title) (\(g.size.byteString))?" }
        return "Delete \(g.title) (\(g.size.byteString))?"
    }

    private func libraryHeader(_ margin: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Library").font(.title3.weight(.bold))
            Text("\(groups.count)").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            LibrarySortMenu(sort: $librarySort, ascending: $librarySortAsc)
            ViewModeMenu(mode: $libraryView)
        }
        .padding(.horizontal, margin)
        .padding(.bottom, 12)
    }

    /// Thumbnails: one row holding the grid. List and Details: one list row
    /// per title. 1.17.2: no swipe actions on Home (27 Oct report: swiping a
    /// title's card to delete it "doesn't look right"); a long press has
    /// the same actions (Delete asks first).
    @ViewBuilder
    private func libraryRows(width: CGFloat, margin: CGFloat) -> some View {
        let mode = LibraryViewMode(rawValue: libraryView) ?? .grid
        if mode == .grid {
            library(width: width, margin: margin).homeRow()
        } else {
            let posters = tileArtwork == "poster"
            let style = ListTransition.current
            ForEach(groups) { g in
                askToDelete(g, Group {
                    if let folder = g.folder {
                        folderLink(g, folder) { FolderRow(group: g, detail: mode == .details, zoom: style == .push ? nil : ZoomSource(g.id, zoomNS), zoomWholeRow: style == .row) }
                    } else {
                        groupLink(g) {
                            LibraryRow(file: g.nextUp, mode: mode, progress: history.entry(forURL: g.nextUp.path)?.progress,
                                       fixedTitle: g.isSeries ? g.title : nil, fixedSubtitle: g.isSeries ? seriesSubtitle(g) : nil,
                                       poster: posters, zoom: opensPage(g) && style != .push ? ZoomSource(g.id, zoomNS) : nil,
                                       zoomWholeRow: style == .row,
                                       size: g.size,
                                       watched: allWatched(g))
                        }
                    }
                })
                .padding(.horizontal, margin)
                .padding(.vertical, mode == .details ? 6 : 2)
                .homeRow()
            }
        }
    }

    /// Thumbnails view: the grid of tiles.
    private func library(width: CGFloat, margin: CGFloat) -> some View {
        let posters = tileArtwork == "poster"
        let cols = posters ? max(3, Int((width - margin * 2 + 14) / 124)) : max(2, Int((width - margin * 2 + 14) / 184))
        let groups = self.groups
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: cols), spacing: 18) {
            ForEach(groups) { g in
                askToDelete(g, Group {
                    if let folder = g.folder {
                        folderLink(g, folder) { FolderTile(group: g, poster: posters, zoom: ZoomSource(g.id, zoomNS)) }
                    } else {
                        groupLink(g) {
                            MediaTile(title: g.title, subtitle: g.isSeries ? seriesSubtitle(g) : g.files[0].pathExtension.uppercased(),
                                      key: g.nextUp.path, fileURL: g.nextUp, lookupName: g.nextUp.lastPathComponent,
                                      progress: history.entry(forURL: g.nextUp.path)?.progress,
                                      fixedTitle: g.isSeries ? g.title : nil, fixedSubtitle: g.isSeries ? seriesSubtitle(g) : nil,
                                      poster: posters, zoom: opensPage(g) ? ZoomSource(g.id, zoomNS) : nil,
                                      watched: allWatched(g), sizeBadge: g.size)
                        }
                    }
                })
            }
        }
        .padding(.horizontal, margin)
    }

    // Pushed through the path, not NavigationLink: inside a List a
    // NavigationLink row gets a disclosure chevron and the list's highlight.
    private func folderLink<L: View>(_ g: LibraryGroup, _ folder: URL, @ViewBuilder label: () -> L) -> some View {
        Button { if !TouchTracker.wasSwipe("home: folder") { open(.folder(folder.path)) } } label: { label() }
            .buttonStyle(PressStyle(scale: 0.97))
            .accessibilityLabel("\(g.title), folder, \(g.count) items, \(g.size.byteString)")
            .contextMenu {
                Button(role: .destructive) { pendingDelete = g } label: { Label("Delete folder", systemImage: "trash") }
            }
    }

    private func seriesSubtitle(_ g: LibraryGroup) -> String {
        let s = g.seasons.count
        return "\(g.count) episode\(g.count == 1 ? "" : "s")" + (s > 1 ? " · \(s) seasons" : "")
    }

    private func opensPage(_ g: LibraryGroup) -> Bool { openTitlePage || g.isSeries }

    /// The episodes a title page shows first: those of the season it opens on.
    private func firstEpisodes(_ g: LibraryGroup) -> [URL] {
        let season = TitleParser.parse(g.nextUp.lastPathComponent).season
        return Array(g.files.filter { season == nil || TitleParser.parse($0.lastPathComponent).season == season }.prefix(8))
    }

    private func allWatched(_ g: LibraryGroup) -> Bool { !g.files.isEmpty && g.files.allSatisfy { history.isWatched($0) } }

    @ViewBuilder
    private func groupLink<L: View>(_ g: LibraryGroup, @ViewBuilder label: () -> L) -> some View {
        Group {
            if opensPage(g) {
                // A swipe across a tile (no swipe actions on Home any more)
                // is not a tap: it neither opens the title nor plays it.
                Button { if !TouchTracker.wasSwipe("home: \(g.title)") { dlog("nav", "home: open \(g.title)"); open(.group(g.id)) } } label: { label() }
                    .buttonStyle(PressStyle(scale: 0.97, onPress: { ThumbLoader.prefetch(firstEpisodes(g)) }))
            } else {
                Button { if !TouchTracker.wasSwipe("home: \(g.title)") { playLocal(g.nextUp) } } label: { label() }
                    .buttonStyle(PressStyle(scale: 0.97))
            }
        }
        .contextMenu {
            Button { playLocal(g.nextUp) } label: { Label(g.isSeries ? "Play next episode" : "Play", systemImage: "play") }
            WatchedMenuItems(files: g.files, scope: g.isSeries ? .all : .one)
            Button(role: .destructive) { pendingDelete = g } label: { Label(g.isSeries ? "Delete all episodes" : "Delete", systemImage: "trash") }
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
        Button { ContinueQueue.play(e.item) } label: { Label(e.canResume ? "Resume" : "Play", systemImage: "play") }
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
        let group = groups.first { $0.files.contains(f) }
        let list = (group?.isSeries == true ? group!.files : LibraryOrganizer.sorted(local.files))
        let queue = list.map { u -> MediaItem in
            var m = MediaItem(url: u.path, title: TitleParser.clean(u.lastPathComponent), source: .local)
            m.historyKey = u.path
            let p = TitleParser.parse(u.lastPathComponent)
            if p.episode != nil { m.anime = AnimeHint(title: p.title, episode: p.episode) }
            return m
        }
        PlayerPresenter.play(queue: queue, index: list.firstIndex(of: f) ?? 0)
    }
}

// MARK: - Components

extension View {
    /// A full-width List row with no background, separator or insets: the
    /// page draws its own spacing (Home is a List for its swipe actions).
    func homeRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

/// Page background: the palette's cream (or ink) with a soft taupe glow in
/// the top corners, like light on paper.
struct HomeBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(colors: [Theme.taupe.opacity(scheme == .dark ? 0.10 : 0.38), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
            RadialGradient(colors: [(scheme == .dark ? Theme.graphite : Color.white).opacity(scheme == .dark ? 0.08 : 0.55), .clear], center: .topTrailing, startRadius: 0, endRadius: 380)
        }
    }
}

/// Watched-progress bar drawn over artwork: a white capsule on a dark track,
/// inset from the picture's edges so it always has picture around it. (Flush
/// with the bottom edge, the white bar merged with the cream page in light
/// mode — reported 25 Oct.)
struct ArtProgressBar: View {
    let progress: Double
    var height: CGFloat = 4
    var body: some View {
        GeometryReader { g in
            let inset = max(5, min(8, g.size.width * 0.05))
            let w = max(0, g.size.width - inset * 2)
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.45))
                Capsule().fill(.white).frame(width: max(height, w * min(1, max(0, progress))))
            }
            .frame(width: w, height: height)
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            .position(x: g.size.width / 2, y: g.size.height - inset - height / 2)
        }
        .allowsHitTesting(false)
    }
}

/// Watched mark (1.17.0): a small eye on a picture's corner.
struct WatchedBadge: View {
    var body: some View {
        Image(systemName: "eye.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(5)
            .background(.black.opacity(0.55), in: Circle())
            .padding(6)
            .accessibilityLabel("Watched")
    }
}

struct HeroCard: View {
    let entry: HistoryEntry
    var height: CGFloat = 230
    @StateObject private var thumb = ThumbLoader()

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // The picture fills the card and is cut to it; it never sets the
            // card's size. (1.16.0: a picture wider than the card widened the
            // card's contents, pushing the title and Resume off its left edge.)
            Color.clear
                .overlay {
                    if let img = thumb.image { Image(uiImage: img).resizable().scaledToFill() }
                    else { GeneratedArt(seed: entry.item.displayTitle) }
                }
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
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.hairline))
        // Text and glass sit on a dark scrim over the picture: dark in both appearances.
        .environment(\.colorScheme, .dark)
        .onAppear {
            if let ref = entry.item.addonRef {
                // Addon streams: the link's file name means nothing, and the
                // item's artwork is the portrait poster. Wide art by IMDb id.
                thumb.loadAddonArt(key: entry.item.id, ref: ref, fallback: entry.item.artwork)
            } else {
                thumb.load(key: entry.item.id, fileURL: entry.item.resolvedURL?.isFileURL == true ? entry.item.resolvedURL : nil,
                           artwork: entry.item.artwork, lookupName: entry.item.resolvedURL?.lastPathComponent ?? entry.item.title)
            }
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
    var fixedTitle: String? = nil
    var fixedSubtitle: String? = nil
    /// Portrait poster (library grid) instead of 16:9 art.
    var poster = false
    /// The title page zooms out of this tile's picture.
    var zoom: ZoomSource? = nil
    /// Right-aligned on the subtitle line (episode tiles: the file size).
    var trailingNote: String? = nil
    /// Every file behind the tile is watched: an eye on the picture.
    var watched = false
    /// Home's titles: their size on the picture, bottom right, as folder
    /// tiles have it (above the progress bar when there is one).
    var sizeBadge: Int64? = nil
    @StateObject private var thumb = ThumbLoader()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                Color.clear.aspectRatio(poster ? 2.0 / 3.0 : 16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        if let img = thumb.image { Image(uiImage: img).resizable().scaledToFill() }
                        else { GeneratedArt(seed: title) }
                    }
                    .clipped()
                if !watched, let progress, progress > 0.01 { ArtProgressBar(progress: progress) }
            }
            .overlay(alignment: .topTrailing) { if watched { WatchedBadge() } }
            .overlay(alignment: .bottomTrailing) {
                if let sizeBadge {
                    SizeBadge(size: sizeBadge)
                        .padding(poster ? 8 : 11)
                        .padding(.bottom, !watched && (progress ?? 0) > 0.01 ? 10 : 0)
                        .accessibilityHidden(true)      // read after the title instead (below)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: poster ? 12 : 16, style: .continuous))
            .zoomSource(zoom, cornerRadius: poster ? 12 : 16)
            Text(fixedTitle ?? thumb.meta?.name ?? title).font(.subheadline.weight(.semibold)).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                let line = fixedSubtitle ?? (poster ? nil : thumb.meta?.episodeTitle) ?? subtitle
                // VoiceOver: "Lab Show, 3 episodes, 83 KB" — the size badge sits
                // on the picture, so it would otherwise be read before the title.
                Text(line).lineLimit(1).accessibilityLabel(sizeBadge.map { "\(line), \($0.byteString)" } ?? line)
                if let trailingNote {
                    Spacer(minLength: 0)
                    Text(trailingNote).monospacedDigit().lineLimit(1).fixedSize()
                }
            }
            .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
        }
        .onAppear {
            LibTrace.image.log("tile \(title) appeared (loader #\(thumb.serial), picture \(thumb.image == nil ? "none yet" : "shown"))")
            thumb.load(key: key, fileURL: fileURL, artwork: artwork, lookupName: lookupName, art: poster ? .poster : .wide)
        }
        .onDisappear { LibTrace.image.log("tile \(title) disappeared (loader #\(thumb.serial))") }
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
                .foregroundStyle(Theme.onAccent)
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
                        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4])).foregroundStyle(.secondary)
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
            .brandListBackground()
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


/// A folder of different titles (1.15.0, #10/#11): four of its own pictures in
/// a 2 × 2 grid on a see-through card, the folder's total size at the bottom
/// right, its name and item count under it.
struct FolderTile: View {
    let group: LibraryGroup
    /// The library shows posters (portrait cells) or frames (16:9 cells).
    var poster: Bool
    var zoom: ZoomSource? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(poster ? 2.0 / 3.0 : 16.0 / 9.0, contentMode: .fit)
                .overlay { FolderCollage(files: Array(group.files.prefix(4)), poster: poster, gap: poster ? 4 : 6, cell: poster ? 7 : 9) .padding(poster ? 5 : 7) }
                .overlay(alignment: .bottomTrailing) { SizeBadge(size: group.size).padding(poster ? 8 : 11) }
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: poster ? 12 : 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: poster ? 12 : 18, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                .zoomSource(zoom, cornerRadius: poster ? 12 : 18)
            Text(group.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text("\(group.count) item\(group.count == 1 ? "" : "s")").font(.caption2.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
        }
        .onAppear { LibTrace.image.log("folder tile \(group.title) appeared") }
        .onDisappear { LibTrace.image.log("folder tile \(group.title) disappeared") }
    }
}

/// List / details mode: the collage as the row's picture, size on the right.
struct FolderRow: View {
    let group: LibraryGroup
    let detail: Bool
    var zoom: ZoomSource? = nil
    var zoomWholeRow = false

    var body: some View {
        HStack(spacing: 12) {
            FolderCollage(files: Array(group.files.prefix(4)), poster: false, gap: 3, cell: 5)
                .padding(4)
                .frame(width: detail ? 150 : 78, height: detail ? 84 : 44)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: detail ? 12 : 8, style: .continuous))
                .zoomSource(zoomWholeRow ? nil : zoom, cornerRadius: detail ? 12 : 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("Folder · \(group.count) item\(group.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(group.size.byteString).font(.caption2.weight(.medium).monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(detail ? 8 : 6)
        .background(RoundedRectangle(cornerRadius: detail ? 16 : 12, style: .continuous).fill(Theme.card))
        .zoomSource(zoomWholeRow ? zoom : nil, cornerRadius: detail ? 16 : 12)
    }
}

struct FolderCollage: View {
    let files: [URL]
    let poster: Bool
    let gap: CGFloat
    let cell: CGFloat

    var body: some View {
        let cols = [GridItem(.flexible(), spacing: gap), GridItem(.flexible(), spacing: gap)]
        GeometryReader { geo in
            let h = (geo.size.height - gap) / 2
            LazyVGrid(columns: cols, spacing: gap) {
                ForEach(0..<4, id: \.self) { i in
                    Group {
                        if i < files.count { FolderThumb(file: files[i], poster: poster) } else { Theme.fill }
                    }
                    .frame(height: max(0, h))
                    .clipShape(RoundedRectangle(cornerRadius: cell, style: .continuous))
                }
            }
        }
    }
}

private struct FolderThumb: View {
    let file: URL
    let poster: Bool
    @StateObject private var thumb = ThumbLoader()
    var body: some View {
        Color.clear
            .overlay {
                if let img = thumb.image { Image(uiImage: img).resizable().scaledToFill() } else { GeneratedArt(seed: file.lastPathComponent) }
            }
            .clipped()
            .onAppear { thumb.load(key: file.path, fileURL: file, artwork: nil, lookupName: file.lastPathComponent, art: poster ? .poster : .wide) }
    }
}

/// A total size on a picture, bottom right (folder and title tiles).
struct SizeBadge: View {
    let size: Int64
    var body: some View {
        Text(size.byteString)
            .font(.caption2.weight(.bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .environment(\.colorScheme, .dark)
    }
}
