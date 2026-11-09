import SwiftUI
import TipKit

/// Folio's tips (1.27.0), each where it applies and only while it's news:
/// addons on Discover once you've looked around it, servers on an empty
/// Network page, the player's gestures in your first plays. At most one an
/// hour; none in UI tests or the lab.
enum FolioTips {
    /// TipKit is set up. Unset, an event's donate() never returns (1.27.1:
    /// Discover waited on one before loading its grid, which stayed empty).
    nonisolated(unsafe) private(set) static var configured = false

    static func configure() {
        guard !FirstRun.automated || FirstRun.forced else { return }
        do {
            try Tips.configure([.displayFrequency(.hourly)])
            configured = true
        } catch {
            dlog("app", "tips not set up: \(error.localizedDescription)")
        }
    }

    /// Counts an event for a tip's rules, without anyone waiting on it.
    static func note(_ event: Tips.Event<Tips.EmptyDonation>) {
        guard configured else { return }
        Task { await event.donate() }
    }

    /// A gesture was used: its tip has done its job.
    static func gestureUsed() {
        PlayerGesturesTip().invalidate(reason: .actionPerformed)
    }
}

/// On Discover's addons button, once Discover has been opened twice with no
/// addon installed.
struct AddonsTip: Tip {
    @Parameter static var noAddons: Bool = true
    static let discoverOpened = Event(id: "discoverOpened")

    var title: Text { Text("Streams and Catalogs") }
    var message: Text? { Text("Addons bring streams, subtitles and more rows to Discover. Add one here.") }
    var image: Image? { Image(systemName: "puzzlepiece.extension") }

    var rules: [Rule] {
        #Rule(Self.$noAddons) { $0 == true }
        #Rule(Self.discoverOpened) { $0.donations.count >= 2 }
    }
}

/// At the top of Network while it has no servers.
struct ServersTip: Tip {
    @Parameter static var noServers: Bool = true

    var title: Text { Text("Play from Your Servers") }
    var message: Text? { Text("Add a NAS or computer over SMB or WebDAV, or a Jellyfin or Plex server, and browse it here.") }
    var image: Image? { Image(systemName: "externaldrive.connected.to.line.below") }

    var rules: [Rule] {
        #Rule(Self.$noServers) { $0 == true }
    }
}

/// In the player in your first plays after installing, until a gesture is used.
struct PlayerGesturesTip: Tip {
    @Parameter static var isNewUser: Bool = false
    static let played = Event(id: "played")

    var title: Text { Text("Gestures") }
    var message: Text? { Text("Double-tap a side to skip, swipe sideways to seek, swipe at the left or right edge for brightness or volume, hold to speed up.") }
    var image: Image? { Image(systemName: "hand.tap") }

    var rules: [Rule] {
        #Rule(Self.$isNewUser) { $0 == true }
        #Rule(Self.played) { $0.donations.count >= 1 }
    }

    var options: [any TipOption] { [MaxDisplayCount(3)] }
}
