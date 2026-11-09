import Foundation

/// The first launch after installing (1.27.0): Folio's best parts (servers,
/// addons, the player's gestures) were invisible to someone new, so a
/// welcome sheet with setup cards opens once, after the splash, and a few
/// tips come up later where they apply (FolioTips).
enum FirstRun {
    /// Set at launch (WhatsNew.noteLaunch, before anything is written).
    @MainActor static var pending = false

    /// A first install: What's New has never been shown and nothing an
    /// earlier launch leaves behind is there.
    static func isFirstInstall(lastShown: String?, usedBefore: Bool) -> Bool {
        lastShown == nil && !usedBefore
    }

    /// UI tests and the lab: no sheet or tips over what they look at.
    /// `-onboarding` shows the sheet anyway.
    static var automated: Bool {
        CommandLine.arguments.contains { $0 == "-noSplash" || $0.hasPrefix("-ui") || $0.hasPrefix("-lab") || $0.hasPrefix("-shots") || $0 == "-glassLab" }
    }

    static var forced: Bool { CommandLine.arguments.contains("-onboarding") }

    @MainActor
    static func decide(lastShown: String?, usedBefore: Bool) {
        pending = forced || (isFirstInstall(lastShown: lastShown, usedBefore: usedBefore) && !automated)
        if pending { dlog("app", "first run: the welcome sheet opens after the splash") }
    }
}

/// What a setup card asks for. The page that does it takes it when it's
/// there (a tab is built when first opened), then clears it.
@MainActor
final class FirstRunRouter: ObservableObject {
    static let shared = FirstRunRouter()

    enum Step: String, Identifiable, CaseIterable {
        case addFiles, addServer, addons
        var id: String { rawValue }
    }

    @Published var request: Step?

    /// Takes the request if it's `step`'s (on the next turn: it's read from
    /// its own publisher).
    func take(_ step: Step) -> Bool {
        guard request == step else { return false }
        DispatchQueue.main.async { if self.request == step { self.request = nil } }
        return true
    }
}
