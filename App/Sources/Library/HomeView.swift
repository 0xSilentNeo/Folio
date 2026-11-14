import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var local = LocalMediaStore.shared
    @ObservedObject private var servers = ServerStore.shared
    @ObservedObject private var indexSummaries = IndexSummaries.shared
    @ObservedObject private var kids = KidsProfile.shared
    @ObservedObject private var metaIndex = LibraryMetaIndex.shared
    @State private var showOpenURL = false
    @State private var editingServer: WebDAVServer?
    @State private var showAddFiles = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var path: [LibraryRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { geo in
                // Margins, columns and card sizes by the page's width (1.30.0, PageLayout).
                let layout = PageLayout(width: geo.size.width)
                let margin = layout.margin
                // A List (1.17.0) so library rows have the system's swipe actions
                // ("Adds custom swipe actions to a row in a list" — swipeActions docs);
                // the rest are plain full-width rows.
                let shown = groups
                List {
                    Group {
                        header(margin).padding(.top, 6)
                        // News from Folio (1.30.3): nothing unless there is some.
                        AnnouncementBanner()
                        if !continueItems.isEmpty { continueWatching(layout).padding(.top, 30) }
                        // Tracked shows' episodes out now or in the next 7 days (1.21.0); nothing when none.
                        // Not in the kids profile: they're the grown-ups' shows.
                        if !kids.isOn { AiringRow(margin: margin) }
                        if hasLibrary { libraryHeader(margin, count: shown.count).padding(.top, 30) }
                        else if realDebrid != nil { compactHowToAdd(margin).padding(.top, 24) }
                        else { howToAdd(margin).padding(.top, continueItems.isEmpty ? 70 : 40) }
                    }
                    .homeRow()
                    if hasLibrary { libraryRows(shown, layout: layout) }
                    if hasLibrary && shown.isEmpty { filteredOut(margin).homeRow() }
                    if let rd = realDebridSummary {
                        RealDebridSection(summary: rd, margin: margin, seeAllAction: { openRealDebrid(nil) }, open: { openRealDebrid($0) })
                            .padding(.top, 30)
                            .homeRow()
                            .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .move(edge: .bottom)))
                    } else if let rd = realDebrid {
                        // Until its first check works: what's happening, not nothing.
                        RealDebridStatusRow(server: rd, summary: indexSummaries.all[rd.id], margin: margin) { editingServer = rd }
                            .padding(.top, 30)
                            .homeRow()
                    }
                    Color.clear.frame(height: 28).homeRow()
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                // Room under the last row for the downloads pill (1.24.1).
                .downloadPillRoom()
                .scrollIndicators(.hidden)
                .environment(\.defaultMinListRowHeight, 0)
                .animation(.smooth(duration: 0.35), value: realDebridSummary != nil)
            }
            .background(HomeBackdrop().ignoresSafeArea())
            .background(TouchTracker.Host().frame(width: 0, height: 0).accessibilityHidden(true))
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { local.refresh() }
            .sheet(isPresented: $showOpenURL) { OpenURLSheet() }
            .sheet(item: $editingServer) { ServerEditView(server: $0) }
            .sheet(isPresented: $showAddFiles) { addFilesSheet }
            // The welcome's "Add Your Videos" (1.27.0).
            .onReceive(FirstRunRouter.shared.$request) { if $0 == .addFiles, FirstRunRouter.shared.take(.addFiles) { showAddFiles = true } }
            .sheet(item: $pick) { PickForMeSheet(candidates: $0.candidates) { playFilm($0) } }
            // Every title's metadata, for the filters, the kids profile and Pick (LibraryMetaIndex).
            .task(id: local.files) { metaIndex.update(local.files) }
            .background(PathWatch(path: $path, pending: pending, layout: layoutGeneration) { openPending() })
            .navigationDestination(for: LibraryRoute.self) { route in destination(route) }
            // Folio went to the background with the kids profile on: Settings
            // and every page opened from it go, so none stays usable without
            // the passcode; opening Settings again asks (1.26.1). Not when the
            // profile is turned on, on its own page.
            .onChange(of: kids.backgroundedAt) {
                guard kids.isOn, let i = path.firstIndex(where: { if case .settings = $0 { return true }; return false }) else { return }
                path.removeSubrange(i...)
            }
            .onAppear {
                LaunchTiming.homeAppeared()
                if let r = HomeRouter.shared.take() { open(r) }
            }
            // A widget's link to a release's folder (1.24.0, HomeRouter).
            .onReceive(HomeRouter.shared.routes) { _ in if let r = HomeRouter.shared.take() { open(r) } }
            // The Real-Debrid section's library, checked again in the
            // background (again when the account is added or changed).
            .task(id: realDebrid.map(LibraryIndex.account)) { if let rd = realDebrid { LibraryIndexStore.shared.refreshIfNeeded(rd) } }
            .onChange(of: libraryView) { old, new in
                layoutGeneration += 1
                LibTrace.zoom.log("home layout \(old) → \(new) (zoom ids now \(layoutGeneration)|…)")
            }
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
        LibTrace.title.event("open", "home opens \(route.logName)")
        if path.isEmpty { path.append(route); return }
        pending.route = route                     // the latest tap wins
        guard !pending.waiting else { return }
        pending.waiting = true
        dlog("nav", "home: \(route.logName) opens when the page going back is gone (path \(path.count))")
        BackWatch.whenGone { gone in
            guard gone else {
                // The swipe back was let go: that page stays, and it's what you see.
                dlog("nav", "home: the page stayed; \(pending.route.map(\.logName) ?? "nothing") not opened")
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
        if let why { dlog("nav", "home: opening \(r.logName) (\(why))") }
        path.append(r)
    }

    /// Logs each change of the path and opens a title that waited for a page
    /// going back (open(_:)). A view of its own: reading the path in Home's
    /// body made every page opening and closing redraw all of Home (28 Oct
    /// profile: Home's library worked out again at each).
    private struct PathWatch: View {
        @Binding var path: [LibraryRoute]
        let pending: PendingOpen
        let layout: Int
        let openPending: () -> Void
        var body: some View {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .onChange(of: path) { old, new in
                    dlog("nav", "home path \(old.count) → \(new.count): \(new.map(\.logName))")
                    // Trace: where each zoom source of the page is, as it opens
                    // and for 2.5 s after it went back.
                    if new.count > old.count, let r = new.last, let id = r.zoomID { ZoomProbe.dump(HomeView.zoomID(id, layout), "opening \(r.logName)") }
                    if new.count < old.count, let r = old.last, let id = r.zoomID { ZoomProbe.timeline(HomeView.zoomID(id, layout), "back from \(r.logName)") }
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

    /// The id a title's tile or row zooms with: its group id, in the current
    /// layout's generation. Home is a List (a UICollectionView), and a row
    /// removed when you switch layouts stays in it as a hidden cell, still
    /// registered as a zoom source with the same id (lab run, 30 Oct: after
    /// Details → Thumbnails, "2 source(s) for s|lab show: (20, 588, 362, 112)
    /// hidden (ListCollectionViewCell isHidden); (145, 457, 112, 168)
    /// visible"). The zoom then grew from and shrank into that hidden
    /// Details row — the card your 30 Oct recording shows floating over
    /// the grid — instead of the tile. A new generation at each switch means
    /// a left-over row never has the id the page zooms with.
    @State private var layoutGeneration = 0
    private func zoomID(_ id: String) -> String { Self.zoomID(id, layoutGeneration) }
    static func zoomID(_ id: String, _ generation: Int) -> String { "\(generation)|\(id)" }

    /// Settings zooms out of its button, a title page out of its poster (iOS 18+).
    @ViewBuilder
    private func destination(_ route: LibraryRoute) -> some View {
        switch route {
        case .settings:
            SettingsView().zoomDestination("settings", in: zoomNS)
        case .group(let id):
            LibraryRoute.destination(route).zoomDestination(zoomID(id), in: zoomNS, zoom: !listPushes)
        case .folder(let path):
            LibraryRoute.destination(route).zoomDestination(zoomID("d|" + path), in: zoomNS, zoom: !listPushes)
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
                .matchedTransitionSource(id: "addfiles", in: zoomNS) { $0.clipShape(RoundedRectangle(cornerRadius: large ? 26 : 20, style: .continuous)) }
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
                    // Never broken over two lines (1.30.3): with the kids
                    // badge beside the buttons it had no room for one.
                    Wordmark(size: 24).lineLimit(1).fixedSize()
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            if kids.isOn { KidsBadge() }
            // As on Discover (1.28.4): the list is as much Home's as Discover's.
            WatchlistSheetButton()
            Menu {
                Button { showAddFiles = true } label: { Label("Add files or folders", systemImage: "folder.badge.plus") }
                // The kids profile plays what the library and Discover let through, not any link.
                if !kids.isOn {
                    Button { showOpenURL = true } label: { Label("Open URL", systemImage: "link") }
                    Button { pasteAndPlay() } label: { Label("Paste & play", systemImage: "doc.on.clipboard") }
                }
            } label: {
                Image(systemName: "plus").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44).menuLabelCircle()
            }
            .glassMenuCircle()
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
            // The zoom starts from the circle (a rounded rectangle half as round
            // as it is wide: the only shape a zoom source takes). Without a
            // shape it started from the button's square for a moment (5 Nov).
            .matchedTransitionSource(id: "settings", in: zoomNS) { $0.clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)) }
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

    /// Continue Watching; in the kids profile, only library files it allows
    /// (an addon or server item's rating isn't known here).
    private var continueItems: [HistoryEntry] {
        let all = history.continueWatching
        guard let limits = kids.activeLimits else { return all }
        return all.filter { e in
            // By the file's name (the index's key), not resolvedURL: that looks on disk, at each redraw.
            guard case .local = e.item.source else { return false }
            return KidsRules.allows(metaIndex.meta(for: URL(fileURLWithPath: e.item.historyKey ?? e.item.url)), limits: limits)
        }
    }

    private func continueWatching(_ layout: PageLayout) -> some View {
        let items = Array(continueItems.prefix(12))
        let margin = layout.margin
        let cardW = layout.continueCardWidth
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Continue Watching", margin)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 20) {
                    ForEach(items) { e in
                        HeroCard(entry: e, height: cardW * 9 / 16 + 8)
                            .frame(width: cardW)
                            .pointerHover(cornerRadius: 22)
                            .onTapGesture { ContinueQueue.play(e.item) }
                            // Each card's own menu (1.25.0): `.contextMenu` in Home's
                            // List belongs to the whole row, as tiles' did before 1.24.1.
                            .tileContextMenu(cornerRadius: 22) { historyActions(e) }
                            // One button to VoiceOver, its menu as actions (1.27.0: five
                            // separate pieces, and the long-press menu out of reach).
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { ContinueQueue.play(e.item) }
                            .modifier(MenuAccessibility(actions: historyActions(e)))
                            .accessibilityIdentifier("continue:" + e.item.title)
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

    /// With a Real-Debrid account on Home, an empty library is one line, so
    /// the Real-Debrid section starts high on the screen instead of below a
    /// page of instructions (user request, 3 Nov).
    private func compactHowToAdd(_ margin: CGFloat) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your library is empty").font(.subheadline.weight(.semibold))
                Text("Add videos from Files, or paste a link with +.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            addFilesButton(large: false)
        }
        .padding(.horizontal, margin)
    }

    // MARK: Library

    /// The Real-Debrid account, when one is added with a user name. Not in
    /// the kids profile: its library is the grown-ups'.
    private var realDebrid: WebDAVServer? { kids.isOn ? nil : servers.servers.first(where: RealDebrid.isRealDebrid) }

    /// Home's Real-Debrid section (RealDebridSection.swift): shown when the
    /// last check of the library worked; kept while offline; gone on a
    /// refused login.
    private var realDebridSummary: LibraryIndexStore.Summary? {
        guard let rd = realDebrid, let s = indexSummaries.all[rd.id], s.refreshed != nil, !s.unauthorized else { return nil }
        return s
    }

    /// Library is your own files only (1.20.0); Real-Debrid has its own
    /// section below it.
    private var hasLibrary: Bool { !local.files.isEmpty }

    /// A release (its folder, as the Real-Debrid library opens it), or See
    /// all (nil: the library).
    private func openRealDebrid(_ release: LibraryIndexStore.Summary.Release?) {
        guard !TouchTracker.wasSwipe("home: Real-Debrid"), let rd = realDebrid else { return }
        open(release.map { LibraryRoute.webdavFolder(rd.id.uuidString, $0.url, $0.name) } ?? LibraryRoute.webdav(rd.id.uuidString))
    }

    @AppStorage("libraryView") private var libraryView = LibraryViewMode.grid.rawValue
    @AppStorage("librarySort") private var librarySort: LibrarySort = .name
    @AppStorage("librarySortAsc") private var librarySortAsc = true
    @AppStorage(SettingsKey.openTitlePage) private var openTitlePage = true
    @AppStorage(SettingsKey.libraryFilterWatch) private var filterWatch = LibraryFilter.Watch.all.rawValue
    @AppStorage(SettingsKey.libraryFilterGenre) private var filterGenre = ""
    @AppStorage(SettingsKey.libraryFilterYear) private var filterYear = ""
    /// The films the sheet picks from, as they were when the button was
    /// tapped (in the sheet's item: a separate state read only by the
    /// sheet's content came through empty the first time).
    @State private var pick: PickRequest?
    struct PickRequest: Identifiable {
        let id = UUID()
        let candidates: [PickForMe.Candidate]
    }

    /// Every title in the library, sorted.
    private var allGroups: [LibraryGroup] {
        LibraryOrganizer.groups(local.files, sort: librarySort, ascending: librarySortAsc)
    }

    /// What the kids profile lets through (everything when it's off).
    private var kidsGroups: [LibraryGroup] {
        guard let limits = kids.activeLimits else { return allGroups }
        return allGroups.filter { metaIndex.kidsAllow($0, limits) }
    }

    private var filter: LibraryFilter { LibraryFilter(watch: filterWatch, genre: filterGenre, year: filterYear) }

    /// The library as Home shows it: the kids profile's titles, then the filters.
    private var groups: [LibraryGroup] {
        let f = filter, list = kidsGroups
        guard f.isActive else { return list }
        return list.filter { f.matches(any: metaIndex.facts(of: $0)) }
    }

    private func clearFilters() {
        withAnimation(.smooth(duration: 0.3)) { filterWatch = LibraryFilter.Watch.all.rawValue; filterGenre = ""; filterYear = "" }
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
        if let folder = g.folder {
            // Everything in it is deleted, so everything is counted (it used to
            // count only the videos). Listed only when the question is asked.
            guard pendingDelete?.id == g.id else { return "" }
            let c = Self.contents(of: folder)
            return "Delete the folder \(g.title) and the \(c.count) file\(c.count == 1 ? "" : "s") in it (\(c.size.byteString))?"
        }
        if g.count > 1 { return "Delete all \(g.count) episodes of \(g.title) (\(g.size.byteString))?" }
        return "Delete \(g.title) (\(g.size.byteString))?"
    }

    private static func contents(of folder: URL) -> (count: Int, size: Int64) {
        var count = 0, size: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys)
        while let f = files?.nextObject() as? URL {
            guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            count += 1
            size += Int64(v.fileSize ?? 0)
        }
        return (count, size)
    }

    private func libraryHeader(_ margin: CGFloat, count: Int) -> some View {
        let options = metaIndex.filterOptions(of: kidsGroups)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Library").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
                Text("\(count)").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button { pickSomething() } label: {
                    Image(systemName: "dice").font(.system(size: 15, weight: .semibold)).frame(width: 40, height: 40).glassCircle()
                }
                .buttonStyle(PressStyle())
                .foregroundStyle(.primary)
                .accessibilityLabel("Pick something for me")
                .accessibilityIdentifier("pickForMe")
                LibraryFilterMenu(watch: $filterWatch, genre: $filterGenre, year: $filterYear,
                                  genres: options.genres, years: options.years, loading: !metaIndex.complete)
                LibrarySortMenu(sort: $librarySort, ascending: $librarySortAsc)
                ViewModeMenu(mode: $libraryView)
            }
            if filter.isActive { LibraryFilterChip(summary: filter.summary, clear: clearFilters) }
        }
        .padding(.horizontal, margin)
        .padding(.bottom, 12)
    }

    /// Nothing left to show: the filters (or the kids profile) say why.
    private func filteredOut(_ margin: CGFloat) -> some View {
        let hiddenByKids = allGroups.count - kidsGroups.count
        let message: String
        if filter.isActive {
            message = filter.emptyMessage(kidsHidden: hiddenByKids)
        } else if !metaIndex.complete {
            message = "Checking your library's ratings for the kids profile…"
        } else {
            message = "The kids profile hides every title here: they're rated above \(KidsRules.summary(kids.limits)), or Folio doesn't know their ratings."
        }
        return LibraryFilterEmpty(message: message, clear: filter.isActive ? clearFilters : nil)
            .padding(.horizontal, margin)
    }

    // MARK: Pick something for me (1.22.0)

    /// Films not started yet (and, in the kids profile, allowed), as the picker weighs them.
    private var pickCandidates: [PickForMe.Candidate] {
        let limits = kids.activeLimits
        return local.files.compactMap { f in
            guard LibraryOrganizer.titleKey(f).hasPrefix("f|") else { return nil }       // films, not episodes
            let e = history.entry(forURL: f.path)
            guard LibraryFilter.watchState(watched: [e?.isFinished == true], resumable: [e?.canResume == true]) == .unwatched else { return nil }
            let meta = metaIndex.meta(for: f)
            if let limits, !KidsRules.allows(meta, limits: limits) { return nil }
            return PickForMe.Candidate(file: f, added: LibraryOrganizer.info(f).date, hasMeta: meta?.poster != nil || meta?.description != nil)
        }
    }

    private func pickSomething() {
        pick = PickRequest(candidates: pickCandidates)
    }

    /// The picked film on its own.
    private func playFilm(_ f: URL) {
        var m = MediaItem(url: f.path, title: TitleParser.clean(f.lastPathComponent), source: .local)
        m.historyKey = f.path
        PlayerPresenter.play(m)
    }

    /// Thumbnails: rows of tiles. List and Details: one list row per title.
    /// 1.17.2 took Home's swipe actions out (27 Oct report: swiping a title's
    /// card to delete it "doesn't look right"); 1.24.1 brings them back on
    /// List and Details ("Swipe to delete is not working anymore", 7 Nov),
    /// the system's own (deleteSwipe, watchedSwipe). Thumbnails have none:
    /// a long press has the same actions.
    @ViewBuilder
    private func libraryRows(_ groups: [LibraryGroup], layout: PageLayout) -> some View {
        let mode = LibraryViewMode(rawValue: libraryView) ?? .grid
        let margin = layout.margin
        if mode == .grid {
            library(groups, layout: layout)
        } else {
            let posters = tileArtwork == "poster"
            let style = ListTransition.current
            let menu = MenuShape(cornerRadius: mode == .details ? 16 : 12)
            ForEach(groups) { g in
                askToDelete(g, Group {
                    if let folder = g.folder {
                        folderLink(g, folder, menu: menu) { FolderRow(group: g, detail: mode == .details, zoom: style == .push ? nil : ZoomSource(zoomID(g.id), zoomNS), zoomWholeRow: style == .row) }
                    } else {
                        groupLink(g, menu: menu) {
                            LibraryRow(file: g.nextUp, mode: mode, progress: history.entry(forURL: g.nextUp.path)?.progress,
                                       fixedTitle: g.isSeries ? g.title : nil, fixedSubtitle: g.isSeries ? seriesSubtitle(g) : nil,
                                       poster: posters, zoom: opensPage(g) && style != .push ? ZoomSource(zoomID(g.id), zoomNS) : nil,
                                       zoomWholeRow: style == .row,
                                       size: g.size,
                                       watched: allWatched(g))
                        }
                    }
                })
                .accessibilityIdentifier("home:" + g.title)
                .padding(.horizontal, margin)
                .padding(.vertical, mode == .details ? 6 : 2)
                .homeRow()
                .swipeActions(edge: .trailing, allowsFullSwipe: false) { deleteSwipe(g) }
                .swipeActions(edge: .leading, allowsFullSwipe: true) { watchedSwipe(g) }
            }
        }
    }

    /// Thumbnails view: the tiles in rows, each row a list row of its own.
    ///
    /// Until 1.20.1 one list row held a LazyVGrid with every tile: a lazy
    /// grid inside Home's List, itself a lazy collection view that sizes
    /// each row as a whole. The 31 Oct and 2 Nov reports show "Mixed", the
    /// fourth tile, drawn in the first row over Classroom of the Elite and
    /// past the screen's edge, smaller than the other tiles, after the
    /// player was closed in landscape, where the grid has 6 columns (3
    /// upright on that phone). The lab never reproduced it, so the exact
    /// path inside SwiftUI is unproven; the lazy grid was the one part of
    /// Home that kept a layout of its own across a change of columns. Now a
    /// row of tiles is a plain HStack of equal columns, each in its own list
    /// row, and a different column count makes new rows.
    @ViewBuilder
    private func library(_ groups: [LibraryGroup], layout: PageLayout) -> some View {
        let posters = tileArtwork == "poster"
        let width = layout.width, margin = layout.margin
        let cols = posters ? layout.posterColumns : layout.thumbColumns
        ForEach(TileRow.rows(groups, columns: cols)) { row in
            HStack(alignment: .top, spacing: 14) {
                ForEach(row.groups) { g in
                    gridTile(g, posters: posters)
                        .frame(maxWidth: .infinity)
                        .modifier(GridProbe(name: g.title))
                        .accessibilityIdentifier("home:" + g.title)
                }
                // The last row's empty columns keep its tiles as wide as the rest.
                ForEach(row.groups.count..<cols, id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                }
            }
            .coordinateSpace(.named(GridProbe.space))
            .modifier(GridProbe(name: "row \(row.index) of \(cols) columns for \(Int(width)) pt", inWindow: true))
            .padding(.horizontal, margin)
            .padding(.bottom, row.isLast ? 0 : 18)
            .homeRow()
        }
    }

    @ViewBuilder
    private func gridTile(_ g: LibraryGroup, posters: Bool) -> some View {
        // Each tile its own menu (1.24.1): a row of tiles is one List row.
        let menu = MenuShape(cornerRadius: posters ? 12 : 16, outset: 8)
        askToDelete(g, Group {
            if let folder = g.folder {
                folderLink(g, folder, menu: menu) { FolderTile(group: g, poster: posters, zoom: ZoomSource(zoomID(g.id), zoomNS)) }
            } else {
                groupLink(g, menu: menu) {
                    MediaTile(title: g.title, subtitle: g.isSeries ? seriesSubtitle(g) : g.files[0].pathExtension.uppercased(),
                              key: g.nextUp.path, fileURL: g.nextUp, lookupName: g.nextUp.lastPathComponent,
                              progress: history.entry(forURL: g.nextUp.path)?.progress,
                              fixedTitle: g.isSeries ? g.title : nil, fixedSubtitle: g.isSeries ? seriesSubtitle(g) : nil,
                              poster: posters, zoom: opensPage(g) ? ZoomSource(zoomID(g.id), zoomNS) : nil,
                              watched: allWatched(g), sizeBadge: g.size)
                }
            }
        })
    }

    /// A title's long-press menu (Home's tiles and rows), built when it
    /// opens: Play, Mark … as watched / unwatched (whichever applies now,
    /// both when some are), Delete (asks first).
    private func menuActions(_ g: LibraryGroup) -> [TileMenuAction] {
        if g.folder != nil {
            return [TileMenuAction(title: "Delete folder", systemImage: "trash", destructive: true) { pendingDelete = g }]
        }
        let watched = g.files.filter { history.isWatched($0) }.count
        let offers = WatchedMenuItems.offers(watched: watched, total: g.files.count)
        let all = g.isSeries ? "all " : ""
        var a = [TileMenuAction(title: g.isSeries ? "Play next episode" : "Play", systemImage: "play") { playLocal(g.nextUp) }]
        if offers.markWatched {
            a.append(TileMenuAction(title: "Mark \(all)as watched", systemImage: "eye") { history.setWatched(g.files, true) })
        }
        if offers.markUnwatched {
            a.append(TileMenuAction(title: "Mark \(all)as unwatched", systemImage: "eye.slash") { history.setWatched(g.files, false) })
        }
        a.append(TileMenuAction(title: g.isSeries ? "Delete all episodes" : "Delete", systemImage: "trash", destructive: true) { pendingDelete = g })
        return a
    }

    /// List and Details (1.24.1, back after 1.17.2 took them out): swipe left
    /// to delete (it asks first, so the row stays put: red by tint, not the
    /// destructive role), right for watched / unwatched.
    @ViewBuilder
    private func deleteSwipe(_ g: LibraryGroup) -> some View {
        Button { pendingDelete = g } label: { Label("Delete", systemImage: "trash") }.tint(.red)
    }

    @ViewBuilder
    private func watchedSwipe(_ g: LibraryGroup) -> some View {
        if g.folder == nil {
            if allWatched(g) {
                Button { history.setWatched(g.files, false) } label: { Label("Unwatched", systemImage: "eye.slash") }.tint(.gray)
            } else {
                Button { history.setWatched(g.files, true) } label: { Label("Watched", systemImage: "eye") }.tint(Theme.swipeTint)
            }
        }
    }

    // Pushed through the path, not NavigationLink: inside a List a
    // NavigationLink row gets a disclosure chevron and the list's highlight.
    private func folderLink<L: View>(_ g: LibraryGroup, _ folder: URL, menu: MenuShape, @ViewBuilder label: () -> L) -> some View {
        Button { if !TouchTracker.wasSwipe("home: folder") { open(.folder(folder.path)) } } label: {
            label().tileContextMenu(cornerRadius: menu.cornerRadius, outset: menu.outset) { menuActions(g) }
        }
        .buttonStyle(PressStyle(scale: 0.97))
        .accessibilityLabel("\(g.title), folder, \(g.count) items, \(g.size.byteString)")
        .modifier(MenuAccessibility(actions: menuActions(g)))
    }

    /// Where a title's long-press menu lifts from (1.24.1): the tile's or the
    /// row's corners, and room around a tile. The menu sits in the button's
    /// label so the title stays one button for VoiceOver and the UI tests
    /// (outside it, "home:Lab Show" became a container nothing could tap).
    struct MenuShape {
        var cornerRadius: CGFloat
        var outset: CGFloat = 0
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

    private func allWatched(_ g: LibraryGroup) -> Bool { LibraryGroup.allWatched(g.files) }

    @ViewBuilder
    private func groupLink<L: View>(_ g: LibraryGroup, menu: MenuShape, @ViewBuilder label: () -> L) -> some View {
        let label = label().tileContextMenu(cornerRadius: menu.cornerRadius, outset: menu.outset) { menuActions(g) }
        Group {
            if opensPage(g) {
                // A swipe across a tile is not a tap: it neither opens the
                // title nor plays it.
                Button { if !TouchTracker.wasSwipe("home: \(g.title)") { dlog("nav", "home: open \(g.title)"); open(.group(g.id)) } } label: { label }
                    .buttonStyle(PressStyle(scale: 0.97, onPress: {
                        let mode = LibraryViewMode(rawValue: UserDefaults.standard.string(forKey: "heroView") ?? "") ?? .grid
                        ThumbLoader.prefetch(firstEpisodes(g), points: LibraryList.picturePoints(mode))
                        ThumbLoader.prefetchHero(g.nextUp)
                    }))
            } else {
                Button { if !TouchTracker.wasSwipe("home: \(g.title)") { playLocal(g.nextUp) } } label: { label }
                    .buttonStyle(PressStyle(scale: 0.97))
            }
        }
        .modifier(MenuAccessibility(actions: menuActions(g)))
    }

    // MARK: Helpers

    private func sectionTitle(_ t: String, _ margin: CGFloat, trailing: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(t).font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
            if let trailing { Text(trailing).font(.subheadline).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(.horizontal, margin)
    }

    private func historyActions(_ e: HistoryEntry) -> [TileMenuAction] {
        [TileMenuAction(title: e.canResume ? "Resume" : "Play", systemImage: "play") { ContinueQueue.play(e.item) },
         TileMenuAction(title: "Mark as watched", systemImage: "checkmark.circle") { history.markWatched(e) },
         TileMenuAction(title: "Remove", systemImage: "trash", destructive: true) { history.remove(e) }]
    }

    private func pasteAndPlay() {
        // Nothing to paste: said without reading it, so no "allow paste"
        // prompt for an empty clipboard (1.24.1).
        guard UIPasteboard.general.hasStrings || UIPasteboard.general.hasURLs,
              let s = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
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
        let group = allGroups.first { $0.files.contains(f) }
        // A show's episodes; anything else on its own (1.27.0: a single file
        // got the whole library as its playlist, so Up Next offered another
        // show and the player didn't close at its end).
        let list = LibraryMetaIndex.shared.kidsQueue(group?.isSeries == true ? group!.files : [f], keeping: f)
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

/// The long-press menu's actions for VoiceOver (1.24.1): the UIKit menu
/// over a tile isn't an accessibility element.
private struct MenuAccessibility: ViewModifier {
    let actions: [TileMenuAction]

    func body(content: Content) -> some View {
        content.accessibilityActions {
            ForEach(actions) { a in Button(a.title, action: a.handler) }
        }
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
    /// The line under a Continue Watching title, the same for every source:
    /// "S1 · E24 · Higashi Village and Nishino Village" for an episode, the
    /// synopsis for a film — never a raw release name. Until 1.19.0 it was
    /// whatever the item carried: a WebDAV file's folder name ("[AnoZu]
    /// Daemons of the Shadow Realm S01 1080p…"), an addon's "S1 · E24 —
    /// title", or a library file's bare episode title (30 Oct screenshots).
    static func line(_ item: MediaItem, meta: MediaMeta?) -> String? {
        let p = parts(item, meta: meta)
        if let number = p.number { return ([number] + [p.title].compactMap { $0 }).joined(separator: " · ") }
        return meta?.synopsis
    }

    /// The line's two parts (1.24.0, for the widgets): "S1 · E24" (nil for a
    /// film) and the episode's title.
    static func parts(_ item: MediaItem, meta: MediaMeta?) -> (number: String?, title: String?) {
        var season: Int?, episode: Int?, title: String?
        if let ref = item.addonRef {
            // The addon episode's label (MetaVideo.label): "S1 · E24 — title",
            // or just the title when the addon gives no season and episode.
            let label = item.subtitle ?? ""
            let video = ref.split(separator: "|", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            let parts = label.components(separatedBy: " — ")
            if let m = parts[0].firstMatch(of: #/^S(\d+) · E(\d+)$/#) {
                season = Int(m.1); episode = Int(m.2)
                title = parts.dropFirst().joined(separator: " — ")
            } else {
                // The video id: "tt…:S:E" (IMDb), "kitsu:<id>:<episode>" and
                // "mal:<id>:<episode>" (no season: one entry per season).
                let v = video.split(separator: ":")
                if v.count == 3, v[0].hasPrefix("tt") { season = Int(v[1]); episode = Int(v[2]) }
                else if v.count == 3, v[0] == "kitsu" || v[0] == "mal" { episode = Int(v[2]) }
                if label != video { title = label }
            }
            if title?.isEmpty == true { title = nil }
        } else {
            let p = TitleParser.parse(item.fileName)
            season = meta?.episodeSeason ?? p.season
            episode = meta?.episodeNumber ?? p.episode
            if episode != nil, season == nil { season = 1 }
        }
        title = meta?.episodeTitle ?? title ?? ReleaseName.file(item.fileName)?.episodeTitle
        guard let episode else { return (nil, nil) }
        return (season.map { "S\($0) · E\(episode)" } ?? "E\(episode)", title)
    }

    let entry: HistoryEntry
    var height: CGFloat = 230
    @StateObject private var thumb = ThumbLoader()
    /// The card's width (16:9 of its height): the picture's longest side.
    private var points: CGFloat { (height - 8) * 16 / 9 }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // The picture fills the card and is cut to it; it never sets the
            // card's size. (1.16.0: a picture wider than the card widened the
            // card's contents, pushing the title and Resume off its left edge.)
            Color.clear
                .overlay {
                    if let img = thumb.image ?? ThumbLoader.cached(key: entry.item.id, points: points) { Image(uiImage: img).resizable().scaledToFill() }
                    else { GeneratedArt(seed: entry.item.displayTitle) }
                }
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                Text(thumb.meta?.name ?? entry.item.displayTitle).font(.headline.weight(.bold)).lineLimit(1)
                if let line = Self.line(entry.item, meta: thumb.meta) { Text(line).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1) }
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
        // The card keeps its height (1.24.1): at the largest text sizes its
        // title, line and Resume row were taller and wider than it, and cut.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.hairline))
        // Text and glass sit on a dark scrim over the picture: dark in both appearances.
        .environment(\.colorScheme, .dark)
        .onAppear {
            if let ref = entry.item.addonRef {
                // Addon streams: the link's file name means nothing, and the
                // item's artwork is the portrait poster. Wide art by IMDb id.
                thumb.loadAddonArt(key: entry.item.id, ref: ref, fallback: entry.item.artwork, points: points)
            } else {
                thumb.load(key: entry.item.id, fileURL: entry.item.resolvedURL?.isFileURL == true ? entry.item.resolvedURL : nil,
                           artwork: entry.item.artwork, lookupName: entry.item.resolvedURL?.lastPathComponent ?? entry.item.title, points: points)
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
    /// False where the tile's accessibility value says "Watched" (1.30.0, episode lists).
    var watchedSpoken = true
    /// Home's titles: their size on the picture, bottom right, as folder
    /// tiles have it (above the progress bar when there is one).
    var sizeBadge: Int64? = nil
    @StateObject private var thumb = ThumbLoader()

    /// The picture's longest side: a poster tile is ~112 × 168 pt on a
    /// phone, a 16:9 tile ~184 pt wide.
    static func points(poster: Bool) -> CGFloat { poster ? 168 : 184 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                Color.clear.aspectRatio(poster ? 2.0 / 3.0 : 16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        // A tile made again (Home redrawn, a page gone back) has its picture from its first frame.
                        if let img = thumb.image ?? ThumbLoader.cached(key: key, art: poster ? .poster : .wide, points: Self.points(poster: poster)) {
                            Image(uiImage: img).resizable().scaledToFill()
                        } else { GeneratedArt(seed: title) }
                    }
                    .clipped()
                if !watched, let progress, progress > 0.01 { ArtProgressBar(progress: progress) }
            }
            .overlay(alignment: .topTrailing) { if watched { WatchedBadge().accessibilityHidden(!watchedSpoken) } }
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
            thumb.load(key: key, fileURL: fileURL, artwork: artwork, lookupName: lookupName, art: poster ? .poster : .wide, points: Self.points(poster: poster))
        }
        .onDisappear { LibTrace.image.log("tile \(title) disappeared (loader #\(thumb.serial))") }
    }
}

struct GeneratedArt: View {
    let seed: String
    var body: some View {
        // A fixed hash (FNV-1a): `hashValue` is seeded per launch, so a
        // title's placeholder colour changed every time the app opened.
        let h = Int(seed.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 } % UInt32(SettingsPalette.all.count))
        // Folio's earthy colours (1.27.0), darkened towards the corner: any hue
        // on the wheel gave bright greens and purples next to the cream.
        ZStack {
            SettingsPalette.all[h]
            LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
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
                    // The system's paste button (1.24.1): no "allow paste" prompt.
                    PasteButton(payloadType: String.self) { strings in
                        if let s = strings.first { url = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
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


/// One row of Home's Thumbnails grid (HomeView.library). Its id holds the
/// column count, so turning the phone to a layout with another count makes
/// new rows rather than refilling the old ones.
struct TileRow: Identifiable {
    let id: String
    let index: Int
    let groups: [LibraryGroup]
    let isLast: Bool

    static func rows(_ groups: [LibraryGroup], columns: Int) -> [TileRow] {
        let n = max(1, columns)
        return stride(from: 0, to: groups.count, by: n).enumerated().map { i, start in
            let slice = Array(groups[start..<min(start + n, groups.count)])
            return TileRow(id: "\(n)|" + slice.map(\.id).joined(separator: "|"), index: i,
                           groups: slice, isLast: start + n >= groups.count)
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
                .overlay { FolderCollage(files: group.collageFiles, poster: poster, gap: poster ? 4 : 6, cell: poster ? 7 : 9, probe: group.title) .padding(poster ? 5 : 7) }
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
            FolderCollage(files: group.collageFiles, poster: false, gap: 3, cell: 5)
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

/// A folder's four pictures in a 2 × 2 grid, sized from the space it's
/// given. A `Grid` with fixed cells, not a `LazyVGrid`: Apple's LazyVGrid
/// page says to use a lazy grid for "a large, vertically scrollable
/// collection" and "only … if profiling your app shows that a Grid view
/// performs poorly". Until 1.20.0 it was a LazyVGrid, and after a trip to
/// landscape and back it kept its landscape width: the grid runs found the
/// folder tile 122 pt wide in a 111 pt column (the landscape collage, 117
/// pt, plus its 5 pt inset), drawing past the tile.
struct FolderCollage: View {
    let files: [URL]
    let poster: Bool
    let gap: CGFloat
    let cell: CGFloat
    /// Trace: the folder's name, to log where the collage's grid is drawn
    /// against the space it was given (LibTrace.layout).
    var probe: String? = nil

    var body: some View {
        GeometryReader { geo in
            let w = max(0, (geo.size.width - gap) / 2), h = max(0, (geo.size.height - gap) / 2)
            Grid(horizontalSpacing: gap, verticalSpacing: gap) {
                ForEach(0..<2, id: \.self) { row in
                    GridRow {
                        ForEach(0..<2, id: \.self) { column in
                            picture(row * 2 + column)
                                .frame(width: w, height: h)
                                .clipShape(RoundedRectangle(cornerRadius: cell, style: .continuous))
                        }
                    }
                }
            }
            .modifier(GridProbe(name: "collage grid of \(probe ?? "?")"))
        }
        .modifier(GridProbe(name: "collage space of \(probe ?? "?")"))
    }

    @ViewBuilder
    private func picture(_ i: Int) -> some View {
        if i < files.count { FolderThumb(file: files[i], poster: poster) } else { Theme.fill }
    }
}

private struct FolderThumb: View {
    let file: URL
    let poster: Bool
    @StateObject private var thumb = ThumbLoader()
    var body: some View {
        Color.clear
            .overlay {
                // The memory copy first (1.24.1): collages showed gradients for a frame when rebuilt.
                if let img = thumb.image ?? ThumbLoader.cached(key: file.path, art: poster ? .poster : .wide, points: 100) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else { GeneratedArt(seed: file.lastPathComponent) }
            }
            .clipped()
            .onAppear { thumb.load(key: file.path, fileURL: file, artwork: nil, lookupName: file.lastPathComponent, art: poster ? .poster : .wide, points: 100) }
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
