import SwiftUI

/// Help & Diagnostics → Notification Test (1.26.1; a section of
/// Notifications until then): every kind, one after another, to try them.
struct NotifyTestView: View {
    @AppStorage(SettingsKey.notifyTest) private var test = true
    @State private var sentKind: NotifyKind?
    @State private var allowed = true

    var body: some View {
        Form {
            Section {
                Toggle("Test", isOn: $test)
                    .accessibilityIdentifier("notifyTest")
                    .onChange(of: test) { _, _ in NotifyCenter.testChanged() }
                Button(sentKind.map { "Sent: “\($0.title)” comes in 5 seconds" } ?? "Send the Next One Now") {
                    Task {
                        sentKind = await NotifyCenter.sendNext()
                        try? await Task.sleep(for: .seconds(6))
                        sentKind = nil
                    }
                }
                .disabled(sentKind != nil || !allowed)
                .accessibilityIdentifier("notifySendNext")
                NavigationLink(value: LibraryRoute.settingsSubpage(.notifySent)) { Text("Sent") }
                    .accessibilityIdentifier("notifySent")
            } footer: {
                Text(test ? Self.testFooter : "Folio's notifications are planned when you leave Folio and taken back when you open it, so what you do next counts.")
            }
        }
        .navigationTitle("Notification Test")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let s = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            allowed = [.authorized, .provisional, .ephemeral].contains(s)
        }
    }

    /// What a Test run sends with the settings now (1.25.2).
    static var testFooter: String {
        let kinds = NotifyCenter.testKinds()
        let all = NotifyKind.allCases.count
        let minutes = max(1, Int((Double(kinds.count) * 20 / 60).rounded()))
        let which = kinds.count == all
            ? "all \(all) kinds of notification come"
            : kinds.isEmpty ? "nothing comes: every kind is switched off in Notifications"
            : "the \(kinds.count) kinds of \(all) that your Notifications settings allow come"
        var notes: [String] = []
        if WeatherFeed.place == nil, NotifyKind.allCases.contains(where: { $0.needsWeather && NotifyPrefs.switchedOn($0) }) {
            notes.append("Rain, cold and heat need a city (Just for fun → Weather).")
        }
        let resting = NotifyKind.allCases.filter { NotifyCenter.resting($0) != nil }.count
        if resting > 0 { notes.append("\(resting) resting after being dismissed are left out.") }
        let extra = notes.isEmpty ? "" : notes.joined(separator: " ") + " "
        return "Leave Folio and \(which), one every 20 seconds (about \(minutes) min), in your personality and with each group's sound. \(extra)Your own titles where Folio has them, samples where it doesn't. Quiet hours and the daily limit don't apply. Opening Folio stops the run; leaving again carries on where it stopped. New-episode notifications wait while Test is on: turn it off for the real thing."
    }
}
