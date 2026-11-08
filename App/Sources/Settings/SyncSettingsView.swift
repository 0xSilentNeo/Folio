import SwiftUI

/// Settings → Sync (1.26.0; one row per service since 1.26.1): what you
/// finish can be marked watched on Trakt, AniList and MyAnimeList. Each row
/// says where the service stands and opens its own page.
struct SyncSettingsView: View {
    @ObservedObject private var center = SyncCenter.shared

    var body: some View {
        Form {
            Section {
                ForEach(SyncService.allCases) { s in
                    NavigationLink { SyncServiceView(service: s) } label: {
                        LabeledContent {
                            SyncStatusText(service: s)
                        } label: {
                            Label(s.name, systemImage: s.symbol)
                        }
                    }
                }
            } footer: {
                Text("When you finish a film or an episode, Folio can mark it watched there: Trakt gets films and episodes, AniList and MyAnimeList anime episodes. Nothing is sent until you connect one.")
            }
            if center.waiting > 0 {
                Section {
                    Label("\(center.waiting) waiting to be sent", systemImage: "clock.arrow.circlepath")
                } footer: {
                    Text("Sent when the service can be reached again.")
                }
            }
        }
        .brandListBackground()
        .navigationTitle("Sync")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Where a service stands, following its switch as it changes.
private struct SyncStatusText: View {
    let service: SyncService
    @ObservedObject private var center = SyncCenter.shared
    @AppStorage private var on: Bool

    init(service: SyncService) {
        self.service = service
        _on = AppStorage(wrappedValue: false, service.enabledKey)
    }

    var body: some View {
        if !center.isConnected(service) {
            Text("Off")
        } else if !on {
            Text("Paused")
        } else {
            let account = center.accounts[service] ?? ""
            Text(account.isEmpty ? "On" : account)
        }
    }
}
