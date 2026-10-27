import SwiftUI
import UIKit

@main
struct GlassPlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        SettingsKey.registerDefaults()
        Diagnostics.shared.start()
        MainThreadLayout.install()
        EnergyMonitor.shared.start()
        UILab.start()
        PopLab.start()
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
        .onAppear { LaunchTiming.firstFrame() }
    }

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
    }

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
        // glassplayer://play?url=<encoded>  or  glassplayer://addon?url=<manifest>
        guard url.scheme == "glassplayer", let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let target = comps.queryItems?.first(where: { $0.name == "url" })?.value else { return }
        switch url.host {
        case "addon":
            Task { try? await AddonStore.shared.install(target) }
            tab = 1
        default:
            PlayerPresenter.play(MediaItem(url: target, title: "", source: .url))
        }
    }
}
