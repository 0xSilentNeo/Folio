import SwiftUI
import UIKit

/// Handoff between iPhone and iPad (1.22.0).
///
/// - A title page advertises `dev.silentneo.folio.title` while it's open:
///   a Discover title by its id (with the addon it came from, by the
///   addon's manifest id, never its address, which can hold a key), a
///   library file by its name.
/// - The player advertises `dev.silentneo.folio.playing` through
///   `playing(item:position:)` and `stopPlaying()`: a library file by its
///   name, anything else by its history key (and an addon item's ref, so
///   its title page can open when the item isn't on the other device).
/// - Continuing opens the title page in a sheet; a playing activity also
///   resumes at its position when the same item is there. In the kids
///   profile nothing starts playing by itself: the page, which checks the
///   rating, opens.
///
/// userInfo holds plist values only, with a format number (`v`) so a later
/// version can read what an earlier one sends and the other way round.
enum HandoffActivity {
    static let titleType = "dev.silentneo.folio.title"
    static let playingType = "dev.silentneo.folio.playing"
    static let format = 1

    struct Payload: Equatable {
        enum Target: Equatable {
            /// A Discover title: "tt…", "kitsu:…"; its kind, name, poster, and the addon's manifest id.
            case discover(id: String, type: String, name: String, poster: String?, addon: String?)
            /// A library file, by its name.
            case library(file: String, title: String)
            /// Something else that plays, by its history key (an addon item's ref when it has one).
            case item(key: String, title: String, addonRef: String?)
        }
        var target: Target
        /// Playing: where it was, and how long it is (0 when not known).
        var position: Double?
        var duration: Double?

        var title: String {
            switch target {
            case .discover(_, _, let name, _, _): return name
            case .library(_, let title), .item(_, let title, _): return title
            }
        }

        var userInfo: [String: Any] {
            var d: [String: Any] = ["v": HandoffActivity.format]
            switch target {
            case .discover(let id, let type, let name, let poster, let addon):
                d["kind"] = "discover"; d["id"] = id; d["type"] = type; d["name"] = name
                if let poster { d["poster"] = poster }
                if let addon { d["addon"] = addon }
            case .library(let file, let title):
                d["kind"] = "library"; d["file"] = file; d["name"] = title
            case .item(let key, let title, let ref):
                d["kind"] = "item"; d["key"] = key; d["name"] = title
                if let ref { d["ref"] = ref }
            }
            if let position { d["position"] = position }
            if let duration { d["duration"] = duration }
            return d
        }

        init(target: Target, position: Double? = nil, duration: Double? = nil) {
            self.target = target; self.position = position; self.duration = duration
        }

        /// nil for anything this version can't open (an unknown kind, a missing field).
        init?(userInfo: [AnyHashable: Any]?) {
            guard let u = userInfo, let kind = u["kind"] as? String else { return nil }
            let name = u["name"] as? String ?? ""
            switch kind {
            case "discover":
                guard let id = u["id"] as? String, !id.isEmpty else { return nil }
                target = .discover(id: id, type: u["type"] as? String ?? "movie", name: name.isEmpty ? id : name,
                                   poster: u["poster"] as? String, addon: u["addon"] as? String)
            case "library":
                guard let file = u["file"] as? String, !file.isEmpty, !file.contains("/") else { return nil }
                target = .library(file: file, title: name.isEmpty ? file : name)
            case "item":
                guard let key = u["key"] as? String, !key.isEmpty else { return nil }
                target = .item(key: key, title: name, addonRef: u["ref"] as? String)
            default:
                return nil
            }
            position = (u["position"] as? NSNumber)?.doubleValue
            duration = (u["duration"] as? NSNumber)?.doubleValue
        }

        /// What the player sends for the item it plays.
        static func playing(_ item: MediaItem, position: Double, duration: Double) -> Payload {
            let title = item.displayTitle
            let pos = position.isFinite ? max(0, position) : 0
            let dur = duration.isFinite && duration > 0 ? duration : nil
            if case .local = item.source {
                return Payload(target: .library(file: item.fileName, title: title), position: pos, duration: dur)
            }
            return Payload(target: .item(key: item.id, title: title, addonRef: item.addonRef), position: pos, duration: dur)
        }

        /// A Discover title: its meta id and kind from an addon ref ("series|tt0944947|tt0944947:1:3").
        static func discover(fromRef ref: String, name: String) -> Payload? {
            let parts = ref.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, !parts[1].isEmpty else { return nil }
            return Payload(target: .discover(id: parts[1], type: parts[0].isEmpty ? "movie" : parts[0], name: name, poster: nil, addon: nil))
        }
    }

    // MARK: Title pages

    static func fill(_ a: NSUserActivity, _ p: Payload) {
        a.title = p.title
        a.userInfo = p.userInfo
        a.requiredUserInfoKeys = Set(["v", "kind"])
        a.isEligibleForHandoff = true
        a.isEligibleForSearch = false
        a.isEligibleForPrediction = false
    }

    // MARK: Playing (called by the player)

    /// The video playing now; called as it plays (each call updates the
    /// same activity while the item is the same).
    @MainActor
    static func playing(item: MediaItem, position: Double, duration: Double = 0) {
        let p = Payload.playing(item, position: position, duration: duration)
        if let a = current, currentKey == item.id {
            a.userInfo = p.userInfo
            a.needsSave = true
        } else {
            current?.invalidate()
            let a = NSUserActivity(activityType: playingType)
            fill(a, p)
            a.becomeCurrent()
            current = a
            currentKey = item.id
            dlog("handoff", "advertising \(item.displayTitle) playing")
        }
        HandoffState.shared.playing = true
    }

    /// The player closed: the title page under it advertises itself again.
    @MainActor
    static func stopPlaying() {
        guard current != nil else { HandoffState.shared.playing = false; return }
        current?.invalidate()
        current = nil
        currentKey = nil
        HandoffState.shared.playing = false
        dlog("handoff", "playing activity ended")
    }

    @MainActor private static var current: NSUserActivity?
    @MainActor private static var currentKey: String?

    // MARK: Continuing

    @MainActor
    static func continueActivity(_ a: NSUserActivity) {
        guard let p = Payload(userInfo: a.userInfo) else {
            dlog("handoff", "\(a.activityType): nothing Folio can open in it")
            return
        }
        let playing = a.activityType == playingType
        dlog("handoff", "continuing \(playing ? "playing" : "title") \(p.title)" + (p.position.map { String(format: " at %.0f s", $0) } ?? ""))
        Task { @MainActor in await open(p, play: playing) }
    }

    /// Lab: what continuing an activity does, in one simulator (there's no
    /// second device there). `-labHandoff=title|library|playing:<id or file
    /// name>[@seconds]`, a few seconds after launch.
    @MainActor
    static func labStart() {
        guard let arg = CommandLine.arguments.first(where: { $0.hasPrefix("-labHandoff=") }) else { return }
        let spec = String(arg.dropFirst("-labHandoff=".count))
        guard let colon = spec.firstIndex(of: ":") else { return }
        let kind = String(spec[..<colon])
        var value = String(spec[spec.index(after: colon)...])
        var position: Double?
        if let at = value.lastIndex(of: "@"), let s = Double(value[value.index(after: at)...]) { position = s; value = String(value[..<at]) }
        let p: Payload
        switch kind {
        case "title": p = Payload(target: .discover(id: value, type: "movie", name: value, poster: nil, addon: nil))
        default: p = Payload(target: .library(file: value, title: value), position: position)
        }
        let a = NSUserActivity(activityType: kind == "playing" ? playingType : titleType)
        a.userInfo = p.userInfo
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { continueActivity(a) }
    }

    @MainActor
    private static func open(_ p: Payload, play: Bool) async {
        let kids = KidsProfile.isOnNow
        switch p.target {
        case .discover(let id, let type, let name, let poster, let addon):
            let m = MetaItem(id: id, type: type, name: name, poster: poster, description: nil, releaseInfo: nil, imdbRating: nil, genres: nil)
            let source = addon.flatMap { a in AddonStore.shared.active.first { $0.manifest.id == a } }
            HandoffPresenter.present(AnyView(MetaDetailView(preview: m, sourceAddon: source)))
        case .library(let fileName, let title):
            let files = await ContinueQueue.libraryFiles()
            guard let file = files.first(where: { $0.lastPathComponent == fileName }) else {
                FileOpener.showAlert("Not on this \(UIDevice.current.model)",
                                     "“\(title)” is in the library on your other device, not in this one's.")
                return
            }
            HandoffPresenter.present(AnyView(TitleHeroView(file: file)))
            guard play, !kids, let position = p.position else { return }
            var item = MediaItem(url: file.path, title: TitleParser.clean(file.lastPathComponent), source: .local)
            item.historyKey = file.path
            let parsed = TitleParser.parse(file.lastPathComponent)
            if parsed.episode != nil { item.anime = AnimeHint(title: parsed.title, episode: parsed.episode) }
            resume(item, at: position, duration: p.duration)
        case .item(let key, let title, let ref):
            let entry = HistoryStore.shared.entry(for: key)
            let page = ref.flatMap { Payload.discover(fromRef: $0, name: title) }
            if case .discover(let id, let type, let name, _, _)? = page?.target {
                let m = MetaItem(id: id, type: type, name: name, poster: entry?.item.artwork, description: nil, releaseInfo: nil, imdbRating: nil, genres: nil)
                HandoffPresenter.present(AnyView(MetaDetailView(preview: m, sourceAddon: nil)))
            }
            guard let entry else {
                if page == nil {
                    FileOpener.showAlert("Not on this \(UIDevice.current.model)",
                                         "“\(title.isEmpty ? "This video" : title)” hasn't been played on this \(UIDevice.current.model.lowercased()) yet, so Folio can't find it here.")
                }
                return
            }
            guard play, !kids, let position = p.position else { return }
            resume(entry.item, at: position, duration: p.duration ?? (entry.duration > 0 ? entry.duration : nil))
        }
    }

    /// Plays from where the other device was: the history takes its place
    /// first (the player resumes from the history), then it plays as
    /// Continue Watching does, with the rest of its season queued.
    @MainActor
    private static func resume(_ item: MediaItem, at position: Double, duration: Double?) {
        let existing = HistoryStore.shared.entry(for: item.id)
        HistoryStore.shared.record(existing?.item ?? item, position: position, duration: duration ?? existing?.duration ?? 0)
        // After the page's sheet is up, so the player opens over it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { ContinueQueue.play(existing?.item ?? item) }
    }
}

/// Whether the player advertises what it plays: title pages step back meanwhile.
@MainActor
final class HandoffState: ObservableObject {
    static let shared = HandoffState()
    @Published var playing = false
}

extension View {
    /// A title page's Handoff (HandoffActivity), while the player isn't advertising its own.
    func handoffTitle(_ payload: HandoffActivity.Payload?) -> some View {
        modifier(HandoffTitle(payload: payload))
    }
}

private struct HandoffTitle: ViewModifier {
    let payload: HandoffActivity.Payload?
    @ObservedObject private var state = HandoffState.shared
    func body(content: Content) -> some View {
        content.userActivity(HandoffActivity.titleType, isActive: payload != nil && !state.playing) { a in
            if let payload { HandoffActivity.fill(a, payload) }
        }
    }
}

/// A title page from another device, in a sheet over whatever is open.
@MainActor
enum HandoffPresenter {
    private static weak var shown: UIViewController?

    static func present(_ page: AnyView) {
        Task { @MainActor in
            // Continued while Folio was closed: its window comes a moment later.
            var waited = 0
            while waited < 30, activeScene == nil {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            guard var top = PlayerPresenter.topViewController() else {
                dlog("handoff", "no window to open the title in")
                return
            }
            if let p = PlayerPresenter.current { p.closePlayer(animated: false); top = PlayerPresenter.topViewController() ?? top }
            let host = UIHostingController(rootView: AnyView(EmptyView()))
            host.rootView = AnyView(HandoffSheet(page: page) { [weak host] in host?.dismiss(animated: true) }.tint(Theme.accent))
            if let shown, shown === top, let under = shown.presentingViewController {
                shown.dismiss(animated: false) { under.present(host, animated: true); Self.shown = host }
            } else {
                top.present(host, animated: true)
                shown = host
            }
        }
    }

    private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
    }
}

private struct HandoffSheet: View {
    let page: AnyView
    let close: () -> Void
    var body: some View {
        NavigationStack {
            page
                .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Done", action: close).fontWeight(.semibold) } }
                .navigationDestination(for: LibraryRoute.self) { LibraryRoute.destination($0) }
        }
        .toggleStyle(BrandSwitchStyle())
    }
}
