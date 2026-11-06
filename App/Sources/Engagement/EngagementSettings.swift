import SwiftUI
import UserNotifications

/// Settings → Reminders (1.24.0): the engagement notifications on or off,
/// what they're like, and notifications allowed for Folio when they aren't.
/// Nothing asks for permission until you tap Allow here.
struct EngagementSettings: View {
    @AppStorage(SettingsKey.engageNotes) private var on = true
    @State private var status: UNAuthorizationStatus?
    @Environment(\.scenePhase) private var phase

    private var allowed: Bool { status.map { [.authorized, .provisional, .ephemeral].contains($0) } ?? true }

    var body: some View {
        Form {
            Section {
                Explained("Now and then a line about what you're watching: an episode left paused, a film nearly done, a late night, a new episode out. Cheeky, sometimes a little dark. At most one a day, never between 10 pm and 9 am, and made on this iPhone from what you've watched; nothing is sent anywhere.") {
                    Toggle("Reminders to keep watching", isOn: $on)
                        .accessibilityIdentifier("engageToggle")
                }
                if on, !allowed {
                    if status == .notDetermined {
                        Button("Allow notifications") {
                            Task {
                                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                                await refresh()
                            }
                        }
                    } else {
                        Button("Allow notifications in Settings") {
                            if let u = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(u) }
                        }
                    }
                }
            } footer: {
                if on, !allowed { Text("Notifications are off for Folio, so these can't come.") }
            }
            if on {
                Section {
                    ForEach(Self.examples, id: \.self) { Text($0).font(.subheadline) }
                } header: { Text("For example") } footer: {
                    Text("New-episode and finished-download notifications speak the same way while this is on.")
                }
            }
        }
        .brandListBackground()
        .navigationTitle("Reminders")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .onChange(of: phase) { _, p in if p == .active { Task { await refresh() } } }
        .onChange(of: on) { _, v in
            dlog("engage", "reminders \(v ? "on" : "off")")
            if !v { EngagementNotifications.takeBack() }
            // The tracker's notifications change voice with this.
            AiringNotifications.reschedule(TrackingStore.shared.shows)
        }
    }

    private func refresh() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private static let examples = [
        EngagePlanner.Text.paused("Your show", at: 31 * 60 + 4),
        EngagePlanner.Text.weekAway,
        EngagePlanner.Text.filmNearlyDone("Your film", minutes: 38),
    ]
}
