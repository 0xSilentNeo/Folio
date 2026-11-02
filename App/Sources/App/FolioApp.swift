import SwiftUI
import UIKit

@main
struct FolioApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        SettingsKey.registerDefaults()
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
        MainActor.assumeIsolated { HistoryStore.shared.flush() }
    }
}

struct RootView: View {
    @State private var tab = UserDefaults.standard.integer(forKey: SettingsKey.startupTab)
    @State private var splash = !CommandLine.arguments.contains("-noSplash")
    @AppStorage(SettingsKey.appearance) private var appearance = AppearanceMode.system.rawValue

    var body: some View {
        ZStack {
            tabs
            if !splash { DownloadPillOverlay() }
            glassLab
            if splash { LaunchSplash { splash = false }.transition(.identity).zIndex(1) }
        }
        .background(AppearanceProbe(mode: appearance).frame(width: 1, height: 1))
        .toggleStyle(BrandSwitchStyle())
        .onAppear {
            LaunchTiming.firstFrame()
            RootView.appearances += 1
            // More than once in one run: the root view was built again (a new
            // scene), and the launch splash with it.
            dlog("app", "root view appeared (\(RootView.appearances) in this run, splash \(splash ? "on" : "off"))")
        }
    }
    @MainActor static var appearances = 0

    /// `-glassLab`: the Liquid Glass morph test screen over everything (CI only).
    @ViewBuilder
    private var glassLab: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), CommandLine.arguments.contains("-glassLab") { GlassLab().zIndex(2) }
        #endif
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "play.rectangle.fill") }
                .tag(0)
            DiscoverView()
                .tabItem { Label("Discover", systemImage: "sparkles.tv") }
                .tag(1)
            NetworkView()
                .tabItem { Label("Network", systemImage: "externaldrive.connected.to.line.below") }
                .tag(2)
        }
        .onOpenURL(perform: handle)
        .alert("Add this addon?", isPresented: Binding(get: { linkAddon != nil }, set: { if !$0 { linkAddon = nil } }), presenting: linkAddon) { target in
            Button("Add") { installLinkedAddon(target) }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text("A link asks Folio to add the addon at \(URL(string: target)?.host ?? target). Addons can see what you search for and play.")
        }
        .alert("Couldn't add the addon", isPresented: Binding(get: { linkError != nil }, set: { if !$0 { linkError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(linkError ?? "") }
    }

    /// An addon a folio:// link asked for, waiting for a yes. Until 1.20.2
    /// a link from any web page added it silently (review, 2 Nov), and a
    /// failure was dropped.
    @State private var linkAddon: String?
    @State private var linkError: String?

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
        dlog("open", "onOpenURL \(url.isFileURL ? url.lastPathComponent : url.absoluteString)")
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
        // folio://play?url=<encoded>  or  folio://addon?url=<manifest>
        guard url.scheme?.lowercased() == "folio", let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let target = comps.queryItems?.first(where: { $0.name == "url" })?.value else { return }
        switch url.host?.lowercased() {
        case "addon":
            linkAddon = target
        case "play":
            guard let s = URL(string: target)?.scheme?.lowercased(), Self.playableSchemes.contains(s) else {
                dlog("open", "folio://play with a link Folio doesn't play: \(URL(string: target)?.scheme ?? "no scheme")")
                return
            }
            PlayerPresenter.play(MediaItem(url: target, title: "", source: .url))
        default:
            dlog("open", "folio:// link with an unknown action: \(url.host ?? "none")")
        }
    }
}
