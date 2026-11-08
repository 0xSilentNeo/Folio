import SwiftUI

/// The pages Settings' root opens (1.26.1), pushed by value onto Home's
/// stack (LibraryRoute.settingsPage) like every other page there: until
/// then each was a NavigationLink(destination:), outside the stack's path.
enum SettingsPage: String, Hashable, CaseIterable, Codable {
    case general, notifications, kids
    case playback, audioSubtitles, skip, engine
    case library, discover, downloads, trackedShows, sync
    case importExport, help, about

    var title: String {
        switch self {
        case .general: "General"
        case .notifications: "Notifications"
        case .kids: "Kids Profile"
        case .playback: "Playback"
        case .audioSubtitles: "Audio & Subtitles"
        case .skip: "Skip Intro & Credits"
        case .engine: "Video Engine (mpv)"
        case .library: "Library"
        case .discover: "Discover"
        case .downloads: "Downloads"
        case .trackedShows: "Tracked Shows"
        case .sync: "Sync"
        case .importExport: "Import & Export"
        case .help: "Help & Diagnostics"
        case .about: "About Folio"
        }
    }

    /// The tile's symbol, drawn filled.
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .notifications: "bell.badge"
        case .kids: "figure.and.child.holdinghands"
        case .playback: "play.rectangle"
        case .audioSubtitles: "captions.bubble"
        case .skip: "forward.end"
        case .engine: "slider.horizontal.3"
        case .library: "film.stack"
        case .discover: "sparkles.tv"
        case .downloads: "arrow.down.circle"
        case .trackedShows: "calendar.badge.clock"
        case .sync: "arrow.triangle.2.circlepath"
        case .importExport: "square.and.arrow.down.on.square"
        case .help: "stethoscope"
        case .about: "info.circle"
        }
    }

    /// Distinct hues within each section of the root.
    var color: Color {
        switch self {
        case .general, .help: .gray
        case .notifications, .trackedShows: .red
        case .kids: .indigo
        case .playback: .pink
        case .audioSubtitles, .sync: .orange
        case .skip: .purple
        case .engine: .teal
        case .library: .green
        case .discover: .cyan
        case .downloads, .importExport: .blue
        case .about: Theme.graphite
        }
    }
}
