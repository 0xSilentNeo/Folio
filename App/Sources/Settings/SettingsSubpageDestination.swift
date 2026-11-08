import SwiftUI

/// The page for a SettingsSubpage route, with the shared Settings look.
struct SettingsSubpageDestination: View {
    let page: SettingsSubpage

    var body: some View {
        content.settingsPage()
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .rememberedShows: RememberedShowsView()
        case .audioLanguages: AudioLanguagesPage()
        case .subtitleLanguages: SubtitleLanguagesPage()
        case .scripts: ScriptsView()
        case .shaders: ShadersView()
        case .scriptOptions: ScriptOptsView()
        case .commands: CommandsEditorView()
        case .playbackLog: LogView()
        case .config(let url, let title, let mono): ConfigEditorView(url: url, title: title, monospaced: mono)
        case .diagnostics: DiagnosticsView()
        case .addons: AddonsManagerView()
        case .syncService(let s): SyncServiceView(service: s)
        case .notifyGroup(let g): NotifyGroupView(group: g)
        case .notifySounds: NotifySoundsList()
        case .notifySound(let g): NotifySoundPicker(group: g)
        case .notifyCity: NotifyCityView()
        case .notifySent: NotifyLogView()
        case .notifyTest: NotifyTestView()
        }
    }
}
