import SwiftUI
import UserNotifications

/// Settings → Reminders (1.24.0): the engagement notifications on or off,
/// what they're like, and notifications allowed for Folio when they aren't.
/// Nothing asks for permission until you tap Allow here.
struct EngagementSettings: View {
    @AppStorage(SettingsKey.engageNotes) private var on = true
    @State private var status: UNAuthorizationStatus?
    @Environment(\.scenePhase) private var phase
    @State private var testSent = false
    @AppStorage(SettingsKey.engageQuick) private var quick = true
    @State private var planned = 0
    /// The next reminder planned, for the footer (1.24.1).
    @State private var nextText = "Reminders come on later days: the first one the day after you stop mid-episode or finish one, at 7 pm."

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
            if on, allowed {
                Section {
                    Button(testSent ? "Sent: it comes in 10 seconds" : "Send a test reminder") {
                        Task {
                            testSent = await EngagementNotifications.sendTest()
                            try? await Task.sleep(nanoseconds: 12_000_000_000)
                            testSent = false
                        }
                    }
                    .disabled(testSent)
                    .accessibilityIdentifier("engageTest")
                    Toggle("Quick timing for testing", isOn: $quick)
                        .accessibilityIdentifier("engageQuick")
                } footer: {
                    if quick {
                        Text(planned == 0
                             ? "Quick timing is on, but nothing is due from what you've watched yet. Stop an episode mid-way, then leave Folio."
                             : "Quick timing is on: leave Folio and the \(planned == 1 ? "reminder" : "\(planned) reminders") it would send over the next two weeks come from 20 seconds later, a minute apart, with their real lines. Opening Folio takes back the rest. Turn it off for their real days.")
                    } else {
                        Text(nextText)
                    }
                }
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
        planned = await EngagementNotifications.plannedCount()
        if let n = await EngagementNotifications.next() {
            let when = n.fire.formatted(.dateTime.weekday(.wide).hour().minute())
            nextText = "The next one comes \(when). Reminders are planned when you leave Folio and taken back when you open it. A test sends that line in 10 seconds."
        } else {
            nextText = "None is due yet: they come on later days, after you stop mid-episode, finish one, or stay away a while. A test sends a sample line in 10 seconds."
        }
    }

    private static let examples = [
        EngagePlanner.Text.paused("Your show", at: 31 * 60 + 4),
        EngagePlanner.Text.weekAway,
        EngagePlanner.Text.filmNearlyDone("Your film", minutes: 38),
    ]
}
