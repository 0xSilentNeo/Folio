import SwiftUI
import UIKit

@main
struct FolioApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        SettingsKey.registerDefaults()
        // Before anything this launch writes: whether Folio was used before (WhatsNew.usedBefore).
        MainActor.assumeIsolated { WhatsNew.noteLaunch() }
        Diagnostics.shared.start()
        MainThreadLayout.install()
        MainThreadLayout.lab()
        EnergyMonitor.shared.start()
        UILab.start()
        PopLab.start()
        MainActor.assumeIsolated { LingerLab.startIfAsked() }
        MainActor.assumeIsolated { PiPTrace.watchScenes() }
        MPVFiles.bootstrap()
        // Reconnects to downloads that ran while the app was closed.
        MainActor.assumeIsolated { _ = DownloadManager.shared }
        // The airing tracker (1.21.0): its background refresh and the
        // notification delegate, which iOS needs set before launch ends.
        MainActor.assumeIsolated { AiringTracker.start() }
        // Folio's notifications (1.25.0): planned each time Folio leaves the
        // screen, cleared when it's back.
        MainActor.assumeIsolated { NotifyCenter.start() }
        if !["-uiTest", "-uiTestLibrary", "-labDiscover", "-shots"].contains(where: CommandLine.arguments.contains) { IMDbSource.warmUp() }
        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        UITabBar.appearance().scrollEdgeAppearance = tab
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(Theme.accent)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    /// A background download session has news while Folio was suspended or
    /// closed: iOS launches it and waits for the handler (URLSession docs).
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == DownloadEngine.identifier else { completionHandler(); return }
        DownloadEngine.shared.backgroundCompletionHandler = completionHandler
        MainActor.assumeIsolated { _ = DownloadManager.shared }
        _ = DownloadEngine.shared.session
    }

    func applicationWillTerminate(_ application: UIApplication) {
        MainActor.assumeIsolated { HistoryStore.shared.flush(wait: true) }
    }
}

struct RootView: View {
    @State private var tab = UserDefaults.standard.integer(forKey: SettingsKey.startupTab)
    @State private var splash = !CommandLine.arguments.contains("-noSplash")
    @AppStorage(SettingsKey.appearance) private var appearance = AppearanceMode.system.rawValue
    @ObservedObject private var kids = KidsProfile.shared
    /// What's new (1.22.0): once after an update, when the splash has gone.
    @State private var whatsNew = false

    var body: some View {
        ZStack {
            tabs
            if !splash { DownloadPillOverlay() }
            glassLab
            if splash { LaunchSplash { splash = false }.transition(.identity).zIndex(1) }
        }
        .background(AppearanceProbe(mode: appearance).frame(width: 1, height: 1))
        .toggleStyle(BrandSwitchStyle())
        .sheet(isPresented: $whatsNew) { WhatsNewSheet() }
        .onChange(of: splash) { _, on in if !on { showWhatsNew() } }
        // Handoff (1.22.0): a title page, or what was playing, from the other device.
        .onContinueUserActivity(HandoffActivity.titleType) { HandoffActivity.continueActivity($0) }
        .onContinueUserActivity(HandoffActivity.playingType) { HandoffActivity.continueActivity($0) }
        .onAppear {
            LaunchTiming.firstFrame()
            RootView.appearances += 1
            // More than once in one run: the root view was built again (a new
            // scene), and the launch splash with it.
            dlog("app", "root view appeared (\(RootView.appearances) in this run, splash \(splash ? "on" : "off"))")
            if !splash { showWhatsNew() }
            if kids.isOn && tab == 2 { tab = 0 }          // Network started on, but it's hidden
            HandoffActivity.labStart()
        }
    }
    @MainActor static var appearances = 0

    private func showWhatsNew() {
        guard WhatsNew.pending else { return }
        WhatsNew.pending = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { whatsNew = true }
    }

    /// `-glassLab`: the Liquid Glass morph test screen over everything (CI only).
    @ViewBuilder
    private var glassLab: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), CommandLine.arguments.contains("-glassLab") { GlassLab().zIndex(2) }
        #endif
    }

    /// The search tab's text (1.22.4), and the page it was opened from,
    /// which it searches (1.22.5).
    @State private var searchText = ""
    @State private var searchFrom = 0

    private var tabs: some View {
        tabView
        .onChange(of: kids.isOn) { _, on in if on && tab == 2 { tab = 0 } }
        // The search searches the page it's opened from; a new page, a new search.
        .onChange(of: tab) { old, new in
            // How smoothly a tab switch (and its zoom) goes, in the report (1.23.1).
            if new != 3 { HitchProbe.start("tab", "tab \(old) → \(new)", seconds: 0.8) }
            guard new == 3, old != 3 else { return }
            HitchProbe.start("search", "search opened from tab \(old)")
            if SearchScope(fromTab: old) != SearchScope(fromTab: searchFrom) { searchText = "" }
            searchFrom = old
        }
        .onOpenURL(perform: handle)
        .onReceive(HomeRouter.shared.showHome) { tab = 0 }
        .alert("Add this addon?", isPresented: Binding(get: { linkAddon != nil }, set: { if !$0 { linkAddon = nil } }), presenting: linkAddon) { target in
            Button("Add") { installLinkedAddon(target) }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text("A link asks Folio to add the addon at \(URL(string: target)?.host ?? target). Addons can see what you search for and play.")
        }
        .alert("Play this stream?", isPresented: Binding(get: { linkPlay != nil }, set: { if !$0 { linkPlay = nil } }), presenting: linkPlay) { target in
            Button("Play") { PlayerPresenter.play(MediaItem(url: target, title: "", source: .url)) }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text("A link asks Folio to play a stream from \(URL(string: target)?.host ?? "another app").")
        }
        .alert("Couldn't add the addon", isPresented: Binding(get: { linkError != nil }, set: { if !$0 { linkError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(linkError ?? "") }
    }

    /// iOS 18 and later: the search is a tab of its own (1.22.4), which iOS 26
    /// draws as the round button beside the tab bar that opens into the
    /// search field, as in Apple's apps. It searches your library, your
    /// servers' files and titles on IMDb and the addons (AddonSearchView).
    /// Until 1.22.4 each had its own search behind a button.
    @ViewBuilder
    private var tabView: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: $tab) {
                Tab("Home", systemImage: "play.rectangle.fill", value: 0) { HomeView().tabZoom() }
                Tab("Discover", systemImage: "sparkles.tv", value: 1) { DiscoverView().tabZoom() }
                // Not in the kids profile (1.22.0): servers play anything on them.
                if !kids.isOn {
                    Tab("Network", systemImage: "externaldrive.connected.to.line.below", value: 2) { NetworkView().tabZoom() }
                }
                Tab(value: 3, role: .search) { SearchTabView(query: $searchText, scope: SearchScope(fromTab: searchFrom)) }
            }
            .modifier(TabBarSearchField())
        } else {
            TabView(selection: $tab) {
                HomeView().tabZoom()
                    .tabItem { Label("Home", systemImage: "play.rectangle.fill") }
                    .tag(0)
                DiscoverView().tabZoom()
                    .tabItem { Label("Discover", systemImage: "sparkles.tv") }
                    .tag(1)
                if !kids.isOn {
                    NetworkView().tabZoom()
                        .tabItem { Label("Network", systemImage: "externaldrive.connected.to.line.below") }
                        .tag(2)
                }
                SearchTabView(query: $searchText, scope: SearchScope(fromTab: searchFrom))
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    .tag(3)
            }
        }
    }

    /// An addon a folio:// link asked for, waiting for a yes. Until 1.20.2
    /// a link from any web page added it silently (review, 2 Nov), and a
    /// failure was dropped.
    @State private var linkAddon: String?
    @State private var linkError: String?
    /// A stream a folio://play link asked for, waiting for a yes (1.23.0).
    @State private var linkPlay: String?

    private func installLinkedAddon(_ target: String) {
        tab = 1
        Task {
            do { try await AddonStore.shared.install(target) } catch {
                dlog("open", "addon from a link not added: \(error.localizedDescription)")
                linkError = error.localizedDescription
            }
        }
    }

    /// What a folio://play link may hand to mpv: network streams, not mpv's
    /// own protocols (edl://, lavfi://, a local path).
    private static let playableSchemes: Set<String> = ["http", "https", "rtsp", "rtmp", "smb", "sftp", "ftp"]

    private func handle(_ url: URL) {
        // What the link does, not the link: an addon's address carries its
        // debrid key, percent-encoded past the log's filter (review, 5 Nov).
        dlog("open", "onOpenURL \(url.isFileURL ? url.lastPathComponent : "\(url.scheme ?? "?")://\(url.host ?? "")")")
        // Kids profile: nothing from outside the app (a widget, a link, a file
        // or script from another app) opens, plays or installs; the profile's
        // own screens decide what plays.
        if KidsProfile.isOnNow {
            dlog("open", "kids profile: \(url.isFileURL ? "file" : "link") not opened")
            FileOpener.showAlert("Kids profile", "Folio is in the kids profile. Leave it from the badge on Home to open this.")
            return
        }
        if url.isFileURL {
            if url.pathExtension.lowercased() == "lua" {
                _ = try? MPVFiles.importItem(from: url, into: MPVFiles.scriptsDir)
                tab = 0
                return
            }
            if ["glsl", "hook"].contains(url.pathExtension.lowercased()) {
                _ = try? MPVFiles.importItem(from: url, into: MPVFiles.shadersDir)
                tab = 0
                return
            }
            FileOpener.open([url])
            return
        }
        // folio://play?url=<encoded>, folio://addon?url=<manifest>, folio://continue?id=<history id>
        guard url.scheme?.lowercased() == "folio", let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let target = comps.queryItems?.first(where: { $0.name == "url" })?.value
        switch url.host?.lowercased() {
        case "addon":
            guard let target else { return }
            linkAddon = target
        case "play":
            guard let target, let s = URL(string: target)?.scheme?.lowercased(), Self.playableSchemes.contains(s) else {
                dlog("open", "folio://play with a link Folio doesn't play: \(target.flatMap { URL(string: $0)?.scheme } ?? "no scheme")")
                return
            }
            // Asked first, as an addon link is: any app, web page, Shortcut
            // or QR code can open folio://play (review, 5 Nov).
            linkPlay = target
        case "continue":
            // The Continue Watching widget (1.20.3): plays the entry as Home's
            // card does. The widget's copy can be a moment behind; an entry
            // removed since then is only logged. With next=1 (the Episode
            // widget, 1.24.0): the episode after it.
            guard let id = ContinueLink.id(from: url), let entry = HistoryStore.shared.entry(for: id) else {
                dlog("open", "folio://continue for an entry that's no longer in the history")
                return
            }
            if ContinueLink.wantsNext(url) { ContinueQueue.playNext(entry.item) } else { ContinueQueue.play(entry.item) }
        case "track":
            // folio://track?id=<tracked show id>: a new-episode notification
            // or the Airing widget (1.21.0) opens the show's tracking page;
            // without an id (1.24.0), the Tracking list.
            TrackingPresenter.open(TrackLink.id(from: url))
        case "aired":
            // The Out now widget's Play (1.24.0): the episode, found again now.
            EpisodeFinder.open(url)
        case "library":
            // The Pick for tonight widget's Play (1.24.0).
            WidgetOpen.libraryFile(url)
        case "release":
            // New on your server (1.24.0): the release's folder on Home.
            WidgetOpen.release(url)
        case "home":
            // A widget with nothing to show yet (1.24.0): Folio on Home.
            tab = 0
        case "downloads":
            // folio://downloads: the downloads Live Activity (1.22.0) and widget (1.24.0).
            DownloadsPresenter.open()
        case "title":
            // A title's page (1.25.0; the notifications open it themselves).
            NotifyCenter.openTitle(url)
        case "libtitle":
            // A library title's page (1.25.0).
            NotifyCenter.openLibraryTitle(url)
        default:
            dlog("open", "folio:// link with an unknown action: \(url.host ?? "none")")
        }
    }
}
