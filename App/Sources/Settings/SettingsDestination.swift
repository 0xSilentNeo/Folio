import SwiftUI

/// The page for a Settings route, with the shared Settings look.
struct SettingsDestination: View {
    let page: SettingsPage

    var body: some View {
        content.settingsPage()
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .general: GeneralSettings()
        case .notifications: NotifySettingsView()
        case .kids: KidsProfileSettings()
        case .playback: PlaybackSettings()
        case .audioSubtitles: SubtitleAudioSettings()
        case .skip: SkipSettings()
        case .engine: MPVSettings()
        case .library: LibrarySettings()
        case .discover: DiscoverSettings()
        case .downloads: DownloadSettingsView()
        case .trackedShows: TrackingView()
        case .sync: SyncSettingsView()
        case .importExport: PresetsView()
        case .help: AdvancedSettings()
        case .about: AboutSettings()
        }
    }
}
