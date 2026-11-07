import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Settings → Notifications (1.25.0; 1.24.0's Reminders). Shaped like the
/// user's 7 Nov mockup: a check per group (tap the row for its kinds and
/// sound), the personality, quiet hours, a daily maximum, then Test and
/// the sent list.
struct NotifySettingsView: View {
    @State private var status: UNAuthorizationStatus?
    @State private var bump = 0
    @AppStorage(SettingsKey.notifyTone) private var tone = NotifyTone.balanced.rawValue
    @AppStorage(SettingsKey.notifyMaxPerDay) private var maxPerDay = 1
    @AppStorage(SettingsKey.notifyTest) private var test = true
    @AppStorage(SettingsKey.notifyQuietStart) private var quietStart = 22 * 60
    @AppStorage(SettingsKey.notifyQuietEnd) private var quietEnd = 9 * 60
    @State private var customQuiet = false
    @State private var sentKind: NotifyKind?
    @Environment(\.scenePhase) private var phase

    private var allowed: Bool { status.map { [.authorized, .provisional, .ephemeral].contains($0) } ?? true }
    private var quiet: QuietHours { QuietHours(start: quietStart, end: quietEnd) }

    var body: some View {
        Form {
            if !allowed {
                Section {
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
                } footer: { Text("Notifications are off for Folio, so none of these can come.") }
            }

            Section {
                ForEach(NotifyGroup.allCases) { g in
                    NavigationLink {
                        NotifyGroupView(group: g) { bump += 1 }
                    } label: {
                        groupRow(g)
                    }
                }
            } header: { Text("Notifications") } footer: {
                Text("Made on this iPhone from what you watch, your library and IMDb's charts; nothing about what you watch is sent anywhere.")
            }
            .id(bump)

            Section {
                ForEach(NotifyTone.allCases) { t in
                    Button {
                        tone = t.rawValue
                        AiringNotifications.reschedule(TrackingStore.shared.shows)
                    } label: {
                        radioRow(t.title + " – " + t.subtitle.lowercased(), on: tone == t.rawValue)
                    }
                    .accessibilityIdentifier("notifyTone.\(t.rawValue)")
                }
            } header: { Text("Personality") } footer: {
                Text(tone == NotifyTone.subtle.rawValue ? "Plain facts. Just for fun is off in Subtle." : "Example: " + example)
            }

            Section {
                ForEach(QuietHours.presets, id: \.self) { q in
                    Button {
                        customQuiet = false
                        quietStart = q.start
                        quietEnd = q.end
                    } label: { radioRow(q.label(), on: !customQuiet && quiet == q) }
                }
                Button { customQuiet = true } label: {
                    radioRow("Custom", on: customQuiet || !QuietHours.presets.contains(quiet))
                }
                if customQuiet || !QuietHours.presets.contains(quiet) {
                    DatePicker("From", selection: minutes($quietStart), displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: minutes($quietEnd), displayedComponents: .hourAndMinute)
                }
            } header: { Text("Quiet hours") } footer: {
                Text("Nothing comes in these hours except new episodes and finished downloads you asked for.")
            }

            Section {
                Stepper(value: $maxPerDay, in: 1...5) {
                    Text(maxPerDay == 1 ? "1 a day" : "\(maxPerDay) a day")
                }
                .accessibilityIdentifier("notifyMax")
            } header: { Text("At most") } footer: {
                Text("New episodes and finished downloads don't count. More than one a day come at least two hours apart.")
            }

            Section {
                NavigationLink("Sounds") { NotifySoundsList() }
            }

            Section {
                Toggle("Test", isOn: $test)
                    .accessibilityIdentifier("notifyTest")
                    .onChange(of: test) { _, _ in NotifyCenter.testChanged() }
                Button(sentKind.map { "Sent: “\($0.title)” comes in 5 seconds" } ?? "Send the next one now") {
                    Task {
                        sentKind = await NotifyCenter.sendNext()
                        try? await Task.sleep(nanoseconds: 6_000_000_000)
                        sentKind = nil
                    }
                }
                .disabled(sentKind != nil || !allowed)
                .accessibilityIdentifier("notifySendNext")
                NavigationLink("Sent") { NotifyLogView() }
                    .accessibilityIdentifier("notifySent")
            } header: { Text("Testing") } footer: {
                Text(test ? testFooter : "Folio's notifications are planned when you leave Folio and taken back when you open it, so what you do next counts.")
            }
            .id(bump)
        }
        .brandListBackground()
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .onChange(of: phase) { _, p in if p == .active { Task { await refresh() } } }
        .onDisappear { NotifyCenter.refreshFeeds() }
    }

    /// What a Test run sends with the settings above (1.25.2).
    private var testFooter: String {
        let kinds = NotifyCenter.testKinds()
        let all = NotifyKind.allCases.count
        let minutes = max(1, Int((Double(kinds.count) * 20 / 60).rounded()))
        let which = kinds.count == all
            ? "all \(all) kinds of notification come"
            : kinds.isEmpty ? "nothing comes: every kind is switched off above"
            : "the \(kinds.count) kinds of \(all) that your settings above allow come"
        var notes: [String] = []
        if WeatherFeed.place == nil, NotifyKind.allCases.contains(where: { $0.needsWeather && NotifyPrefs.switchedOn($0) }) {
            notes.append("Rain, cold and heat need a city (Just for fun → Weather).")
        }
        let resting = NotifyKind.allCases.filter { NotifyCenter.resting($0) != nil }.count
        if resting > 0 { notes.append("\(resting) resting after being dismissed are left out.") }
        return "Test is on: leave Folio and \(which), one every 20 seconds (about \(minutes) min), in your personality and with each group's sound. "
            + (notes.isEmpty ? "" : notes.joined(separator: " ") + " ")
            + "Your own titles where Folio has them, samples where it doesn't. Quiet hours and the daily limit don't apply to Test. Opening Folio stops the run; leaving again carries on where it stopped, each kind with its next line. New-episode notifications wait while Test is on. Turn it off for the real thing."
    }

    private var example: String {
        let t = NotifyTone(rawValue: tone) ?? .balanced
        return NotifyWording.text(.paused, t, ["show": "Your show", "time": "31:04"], variation: 0)?.body ?? ""
    }

    private func groupRow(_ g: NotifyGroup) -> some View {
        let on = NotifyPrefs.groupOn(g)
        return HStack(spacing: 12) {
            Image(systemName: g.symbol)
                .foregroundStyle(Theme.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(g.title)
                Text(g == .fun && tone == NotifyTone.subtle.rawValue ? "Off in Subtle" : g.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                NotifyPrefs.setGroup(g, on: !on)
                if g == .newReleases { AiringNotifications.reschedule(TrackingStore.shared.shows) }
                bump += 1
            } label: {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(on ? Theme.accent : .secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(on ? "\(g.title), on" : "\(g.title), off")
            .accessibilityIdentifier("notifyGroup.\(g.rawValue)")
        }
    }

    private func radioRow(_ title: String, on: Bool) -> some View {
        HStack {
            Image(systemName: on ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(on ? Theme.accent : .secondary)
            Text(title).foregroundStyle(.primary)
        }
    }

    private func minutes(_ v: Binding<Int>) -> Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: v.wrappedValue / 60, minute: v.wrappedValue % 60, second: 0, of: Date()) ?? Date()
        } set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            v.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }
    }

    private func refresh() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

/// One group: its switch, each kind's, its sound, and (Just for fun) the weather's city.
struct NotifyGroupView: View {
    let group: NotifyGroup
    let changed: () -> Void
    @State private var bump = 0
    @AppStorage(SettingsKey.airingAlerts) private var alerts = AiringAlerts.air.rawValue

    var body: some View {
        Form {
            Section {
                Toggle(group.title, isOn: Binding(get: { NotifyPrefs.groupOn(group) }, set: {
                    NotifyPrefs.setGroup(group, on: $0)
                    after()
                }))
                .accessibilityIdentifier("notifyGroupToggle")
            } footer: { Text(groupFooter) }

            if NotifyPrefs.groupOn(group) {
                Section {
                    ForEach(group.kinds) { k in
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(k.title, isOn: Binding(get: { NotifyPrefs.kindOn(k) }, set: {
                                NotifyPrefs.setKind(k, on: $0)
                                after()
                            }))
                            if let until = NotifyCenter.resting(k) {
                                HStack {
                                    Text("Resting until \(until.formatted(.dateTime.day().month())): dismissed three times in a row.")
                                        .font(.footnote).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Resume") { NotifyCenter.wake(k); bump += 1 }
                                        .font(.footnote)
                                        .buttonStyle(.borderless)
                                }
                            }
                            if let need = needs(k) {
                                Text(need).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text("Which ones") } footer: {
                    Text("“Fewer Like This” on a notification turns its kind off here.")
                }

                if group == .newReleases {
                    Section {
                        Picker("When", selection: $alerts) {
                            ForEach(AiringAlerts.allCases.filter { $0 != .off }) { Text($0.title).tag($0.rawValue) }
                        }
                        .onChange(of: alerts) { _, _ in AiringNotifications.reschedule(TrackingStore.shared.shows) }
                    } footer: { Text("For the shows you track (Settings → Tracking).") }
                }

                Section {
                    NavigationLink {
                        NotifySoundPicker(group: group)
                    } label: {
                        LabeledContent("Sound", value: NotifySounds.choice(for: group).label)
                    }
                }

                if group == .fun {
                    Section {
                        NavigationLink {
                            NotifyCityView()
                        } label: {
                            LabeledContent("Weather", value: WeatherFeed.place?.name ?? "Not set")
                        }
                    } footer: {
                        Text("Rain, cold and heat need a city: only its position (to two decimals) goes to Open-Meteo for the forecast. Weather data by Open-Meteo.com (CC BY 4.0). Public holidays from Nager.Date, for the city's country or this iPhone's region.")
                    }
                }
            }
        }
        .id(bump)
        .brandListBackground()
        .navigationTitle(group.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var groupFooter: String {
        switch group {
        case .watching: return "Unfinished films and episodes, a late night, a binge, a week away. From what you watch in Folio."
        case .newReleases: return "The shows you track. Same switch as Settings → Tracking → New episodes."
        case .trending: return "From IMDb's Most Popular charts, fetched when Folio is open. At most three a week."
        case .recommendations: return "From Discover's For you and what you've watched. At most two a week."
        case .library: return "Your library's films. At most two a week."
        case .briefing: return "Friday evening's top titles, new titles on the charts, and the 1st's recap of the month."
        case .fun: return NotifyPrefs.tone == .subtle ? "Off while the personality is Subtle." : "Jokes about your habits, the weather and holidays. At most two a week."
        case .downloads: return "When downloads finish while Folio is in the background. Same switch as Settings → Downloads."
        }
    }

    private func needs(_ k: NotifyKind) -> String? {
        if k.needsWeather, WeatherFeed.place == nil { return "Needs a city (Weather, below)." }
        return nil
    }

    private func after() {
        bump += 1
        changed()
        if group == .newReleases { AiringNotifications.reschedule(TrackingStore.shared.shows) }
        NotifyCenter.refreshFeeds()
    }
}

/// Settings → Notifications → Sounds: each group's.
struct NotifySoundsList: View {
    var body: some View {
        Form {
            Section {
                ForEach(NotifyGroup.allCases) { g in
                    NavigationLink {
                        NotifySoundPicker(group: g)
                    } label: {
                        LabeledContent(g.title, value: NotifySounds.choice(for: g).label)
                    }
                }
            } footer: {
                Text("iOS plays these only while Folio's sounds are on in iOS Settings → Notifications → Folio, and not in silent mode.")
            }
        }
        .brandListBackground()
        .navigationTitle("Sounds")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One group's sound: Default, None, Folio's, Apple's alert tones on this iPhone, or yours from Files.
struct NotifySoundPicker: View {
    let group: NotifyGroup
    @State private var current: NotifySound = .standard
    @State private var importing = false
    @State private var error: String?
    @State private var custom: [String] = []
    private let apple = NotifySounds.apple

    var body: some View {
        Form {
            Section {
                row(.standard)
                row(.none)
            }
            Section("Folio") {
                ForEach(NotifySounds.folio, id: \.self) { row(.folio($0)) }
            }
            Section {
                ForEach(apple, id: \.self) { row(.apple($0)) }
            } header: { Text("Apple") } footer: {
                Text(apple.isEmpty
                     ? "This iPhone doesn't let Folio read Apple's alert tones, so they can't be used."
                     : "Apple's tones, read from this iPhone and copied for Folio when picked.")
            }
            Section {
                ForEach(custom, id: \.self) { row(.custom($0)) }
                Button("Choose from Files…") { importing = true }
            } header: { Text("Yours") } footer: {
                Text(error ?? "Any audio file: Folio converts it and keeps the first 29 seconds (iOS plays up to 30).")
            }
        }
        .brandListBackground()
        .navigationTitle("\(group.title) sound")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            current = NotifySounds.choice(for: group)
            custom = NotifySounds.custom
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url):
                do {
                    let name = try NotifySounds.importSound(from: url)
                    custom = NotifySounds.custom
                    pick(.custom(name))
                    error = nil
                } catch {
                    self.error = "That file couldn't be read as audio: \(error.localizedDescription)"
                }
            case .failure(let e):
                error = e.localizedDescription
            }
        }
    }

    private func row(_ s: NotifySound) -> some View {
        Button { pick(s) } label: {
            HStack {
                Text(s.label).foregroundStyle(.primary)
                Spacer()
                if current == s { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
            }
        }
    }

    private func pick(_ s: NotifySound) {
        current = s
        NotifySounds.set(s, for: group)
        SoundPreview.shared.play(s)
        if group == .newReleases { AiringNotifications.reschedule(TrackingStore.shared.shows) }
    }
}

/// The weather's city, found by name (Open-Meteo's geocoding).
struct NotifyCityView: View {
    @State private var query = ""
    @State private var results: [WeatherFeed.Place] = []
    @State private var searching = false
    @State private var place = WeatherFeed.place
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if let p = place {
                Section("Now") {
                    Text(p.label)
                    Button("Remove", role: .destructive) {
                        WeatherFeed.place = nil
                        place = nil
                    }
                }
            }
            Section {
                TextField("City", text: $query)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit(search)
                if searching { ProgressView() }
                ForEach(results) { r in
                    Button {
                        WeatherFeed.place = r
                        place = r
                        Task { await WeatherFeed.refresh(force: true); await HolidayFeed.refresh() }
                        dismiss()
                    } label: {
                        Text(r.label).foregroundStyle(.primary)
                    }
                }
            } footer: {
                Text("The name you type goes to Open-Meteo to find the city. Folio keeps the city here; its forecast is fetched every few hours while Just for fun's weather ones are on.")
            }
        }
        .brandListBackground()
        .navigationTitle("Weather")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return }
        searching = true
        Task {
            results = await WeatherFeed.search(q)
            searching = false
        }
    }
}

/// Settings → Notifications → Sent: what's coming and what went out, with why.
struct NotifyLogView: View {
    @State private var entries: [NotifyCenter.LogEntry] = []

    var body: some View {
        let now = Date()
        let coming = entries.filter { $0.at > now }.sorted { $0.at < $1.at }
        let sent = entries.filter { $0.at <= now }.sorted { $0.at > $1.at }
        List {
            if !coming.isEmpty {
                Section("Coming") { ForEach(coming) { row($0) } }
            }
            Section {
                ForEach(sent) { row($0) }
            } header: { Text("Sent") } footer: {
                Text(entries.isEmpty ? "Nothing yet. With Test on, leave Folio and they start in 20 seconds." : "The last 150.")
            }
        }
        .brandListBackground()
        .navigationTitle("Sent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Clear") {
                NotifyCenter.clearLog()
                entries = []
            }
            .disabled(entries.isEmpty)
        }
        .task {
            while !Task.isCancelled {
                entries = NotifyCenter.log()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func row(_ e: NotifyCenter.LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(e.kind.title).font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
                if e.test { Text("Test").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary, in: Capsule()) }
                Spacer()
                Text(e.at.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            if let t = e.title { Text(t).font(.subheadline.weight(.semibold)) }
            Text(e.body).font(.subheadline)
            Text(e.reason + (e.outcome.map { " · " + $0 } ?? "")).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
