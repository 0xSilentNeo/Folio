import SwiftUI
import UIKit

/// folio://downloads (the downloads Live Activity, 1.22.0): the Downloads
/// screen as a sheet over whatever is on screen, as TrackingPresenter opens
/// a show's tracking page.
@MainActor
enum DownloadsPresenter {
    private static weak var shown: UIViewController?

    static func open() {
        Task { @MainActor in
            // Opened from the Lock Screen while Folio was closed: its window comes a moment later.
            var waited = 0
            while waited < 30, activeScene == nil {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            let scene = activeScene ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            guard let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first,
                  var top = window.rootViewController else {
                dlog("downloads", "no window to open the Downloads screen in")
                return
            }
            while let p = top.presentedViewController { top = p }
            // Already open (a second tap on the activity).
            if let shown, shown === top { return }
            dlog("downloads", "opening the Downloads screen from a link")
            let host = UIHostingController(rootView: AnyView(EmptyView()))
            host.rootView = AnyView(DownloadsSheet { [weak host] in host?.dismiss(animated: true) }.tint(Theme.accent))
            top.present(host, animated: true)
            shown = host
        }
    }

    private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
    }
}

private struct DownloadsSheet: View {
    let close: () -> Void

    var body: some View {
        NavigationStack {
            DownloadsView()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Done", action: close) }
                }
        }
        .toggleStyle(BrandSwitchStyle())
    }
}
