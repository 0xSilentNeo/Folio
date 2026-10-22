import SwiftUI
import UIKit

@main
struct GlassPlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        SettingsKey.registerDefaults()
        Diagnostics.shared.start()
        UILab.start()
        MPVFiles.bootstrap()
        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        UITabBar.appearance().scrollEdgeAppearance = tab
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    func applicationWillTerminate(_ application: UIApplication) {
        MainActor.assumeIsolated { HistoryStore.shared.flush() }
    }
}

struct RootView: View {
    @State private var tab = 0

    var body: some View {
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
