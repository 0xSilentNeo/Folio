import AppIntents
import Foundation

// The now-playing Live Activity's buttons (1.22.0). Built into both Folio and
// FolioWidget: the widget needs the types to draw the buttons, and iOS runs
// a LiveActivityIntent in the app's process when the app has it too. There
// it tells the player, which listens for NowPlayingCommand.notification.

enum NowPlayingCommand {
    static let notification = Notification.Name("folio.nowPlaying.command")
    /// userInfo["command"]: "toggle", "back" or "forward".
    static let key = "command"

    @MainActor
    static func post(_ command: String) {
        NotificationCenter.default.post(name: notification, object: nil, userInfo: [key: command])
    }
}

struct NowPlayingToggleIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    // Only the activity's button: not offered in Shortcuts or Siri.
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        NowPlayingCommand.post("toggle")
        return .result()
    }
}

struct NowPlayingBackIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Back 10 Seconds"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        NowPlayingCommand.post("back")
        return .result()
    }
}

struct NowPlayingForwardIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Forward 10 Seconds"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        NowPlayingCommand.post("forward")
        return .result()
    }
}
