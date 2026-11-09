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

    /// The tile's glyph, drawn filled where the symbol has a fill (1.26.3: Discover
    /// and Home's own tab glyphs, and ones that say what's inside, e.g. the
    /// engine's chip and the library's books).
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .notifications: "bell.badge"
        case .kids: "figure.and.child.holdinghands"
        case .playback: "play"
        case .audioSubtitles: "captions.bubble"
        case .skip: "forward.end"
        case .engine: "cpu"
        case .library: "books.vertical"
        case .discover: "sparkles.tv"
        case .downloads: "arrow.down.circle"
        case .trackedShows: "calendar.badge.clock"
        case .sync: "arrow.triangle.2.circlepath"
        case .importExport: "shippingbox"
        case .help: "stethoscope"
        case .about: "info.circle"
        }
    }

    /// The tile's colour, from Folio's palette (1.26.3), distinct within each
    /// section of the root. White glyphs on them are at least 4:1.
    var tint: Color {
        switch self {
        case .general, .help: SettingsPalette.graphite
        case .notifications, .discover: SettingsPalette.clay
        case .kids: SettingsPalette.plum
        case .playback, .trackedShows: SettingsPalette.brick
        case .audioSubtitles: SettingsPalette.ochre
        case .skip: SettingsPalette.sage
        case .engine, .downloads: SettingsPalette.slate
        case .library: SettingsPalette.pine
        case .sync: SettingsPalette.olive
        case .importExport: SettingsPalette.sand
        case .about: Theme.accent
        }
    }
}
