import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Settings → Notifications (1.25.0; 1.24.0's Reminders). 1.26.1, from a
/// design review: each group's row says On or Off and opens its page, the
/// daily limit and sounds share a section, and Test moved to its own page
/// (Help & Diagnostics → Notification Test), shown here only while it's on.
/// 1.26.3: Personality is a slider over a worded example, and Quiet Hours a
/// switch with your own times (the presets were five rows for one choice).
struct NotifySettingsView: View {
    @State private var status: UNAuthorizationStatus?
    @Bindable private var prefs = NotifyPrefsModel.shared
    @AppStorage(SettingsKey.notifyTone) private var tone = NotifyTone.balanced.rawValue
    @AppStorage(SettingsKey.notifyMaxPerDay) private var maxPerDay = 1
    @AppStorage(SettingsKey.notifyTest) private var test = false
    @AppStorage(SettingsKey.notifyQuietStart) private var quietStart = 22 * 60
    @AppStorage(SettingsKey.notifyQuietEnd) private var quietEnd = 9 * 60
    @State private var quietOn = true
    @State private var from = Date()
    @State private var to = Date()
    @Environment(\.scenePhase) private var phase
    @AppStorage(SettingsKey.announcements) private var news = true

    private var allowed: Bool { status.map { [.authorized, .provisional, .ephemeral].contains($0) } ?? true }

    var body: some View {
        Form {
            Section {
                Toggle("Allow Notifications", isOn: $prefs.allOn.animation(.smooth))
                    .accessibilityIdentifier("notifyAllOn")
            } footer: {
                Text(prefs.allOn
                     ? "Folio's notifications, as each group below allows."
                     : "None of Folio's notifications come, new episodes and finished downloads included. Each group keeps its own setting for when they're back on.")
            }

            if prefs.allOn {
                settings
            }

            // (1.30.3) Outside Allow Notifications: the news shows in Folio too.
            Section {
                Toggle("News from Folio", isOn: $news)
                    .accessibilityIdentifier("announcements")
            } footer: {
                Text("Checks Folio's page on GitHub about twice a day for announcements and new versions. Nothing about you is sent.")
            }
        }
        .brandListBackground()
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .onAppear(perform: loadQuiet)
        .onChange(of: phase) { _, p in if p == .active { Task { await refresh() } } }
        .onChange(of: tone) { _, _ in
            AiringNotifications.reschedule(TrackingStore.shared.shows)
            prefs.changed()
            NotifyCenter.settingsChanged()
        }
        .onChange(of: from) { _, d in if quietOn { quietStart = Self.minutes(d) } }
        .onChange(of: to) { _, d in if quietOn { quietEnd = Self.minutes(d) } }
        .onChange(of: quietStart) { _, _ in NotifyCenter.settingsChanged() }
        .onChange(of: quietEnd) { _, _ in NotifyCenter.settingsChanged() }
        .onChange(of: maxPerDay) { _, _ in NotifyCenter.settingsChanged() }
        .onDisappear { NotifyCenter.refreshFeeds() }
    }

    /// Everything under Allow Notifications, shown while it's on.
    @ViewBuilder
    private var settings: some View {
        if !allowed {
            Section {
                if status == .notDetermined {
                    Button("Ask for Permission") {
                        Task {
                            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                            await refresh()
                        }
                    }
                } else {
                    Button("Allow Notifications in Settings") {
                        if let u = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(u) }
                    }
                }
            } footer: { Text("iOS has notifications off for Folio, so none of these can come.") }
        }

        if test {
            Section {
                NavigationLink(value: LibraryRoute.settingsSubpage(.notifyTest)) {
                    Label("Test is on", systemImage: "testtube.2")
                }
                .accessibilityIdentifier("notifyTestRow")
            } footer: {
                Text("Every kind comes one after another while you're away, and real new-episode notifications wait. Turn it off when you're done.")
            }
        }

        Section {
            ForEach(NotifyGroup.allCases) { g in
                NavigationLink(value: LibraryRoute.settingsSubpage(.notifyGroup(g))) {
                    groupRow(g)
                }
                .accessibilityIdentifier("notifyGroup.\(g.rawValue)")
            }
        } footer: {
            Text("Made on this iPhone from what you watch, your library and IMDb's charts; nothing about what you watch is sent anywhere.")
        }

        Section {
            NotifyToneSlider(tone: $tone)
        } header: { Text("Personality") } footer: {
            Text(toneNote)
        }

        Section {
            Toggle("Quiet Hours", isOn: quietSwitch.animation(.smooth))
                .accessibilityIdentifier("notifyQuiet")
            if quietOn {
                DatePicker("From", selection: $from, displayedComponents: .hourAndMinute)
                DatePicker("To", selection: $to, displayedComponents: .hourAndMinute)
            }
        } footer: {
            Text(quietOn && Self.minutes(from) == Self.minutes(to)
                 ? "From and To are the same time, so there are no quiet hours."
                 : "Nothing comes in these hours except new episodes and finished downloads you asked for.")
        }

        Section {
            Stepper(value: $maxPerDay, in: 1...5) {
                LabeledContent("Notifications a Day", value: "\(maxPerDay)")
            }
            .accessibilityIdentifier("notifyMax")
            NavigationLink(value: LibraryRoute.settingsSubpage(.notifySounds)) {
                Text("Sounds")
            }
        } header: { Text("Delivery") } footer: {
            Text("At most this many a day. New episodes and finished downloads don't count towards it. More than one a day come at least two hours apart.")
        }
    }

    private var toneNote: String {
        switch NotifyTone(rawValue: tone) ?? .balanced {
        case .subtle: "Plain facts. Just for fun is off in Subtle."
        case .balanced: "A joke now and then, the facts first."
        case .unhinged: "Every notification with full personality."
        }
    }

    /// A group's row: its symbol, name and what it is, and On or Off on the right.
    private func groupRow(_ g: NotifyGroup) -> some View {
        let on = prefs[groupOn: g]
        // A Label, so the list lines up every title whatever the symbol's
        // width (the masks are wider than the others).
        // On or Off stays on the right (LabeledContent put it under a
        // long subtitle).
        return HStack(spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(g.title).foregroundStyle(.primary)
                    Text(g == .fun && tone == NotifyTone.subtle.rawValue ? "Off in Subtle" : g.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: g.symbol).foregroundStyle(Theme.accent)
            }
            Spacer(minLength: 0)
            Text(on ? "On" : "Off").foregroundStyle(.secondary).fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(on ? "On" : "Off")
    }

    /// Off is stored as no hours (start == end); on again, the times shown.
    /// Written by the switch itself (1.30.4): as an onChange of `quietOn`,
    /// opening the page wrote them too, and hours kept with the same From
    /// and To became 0 – 0, which took back what was planned.
    private var quietSwitch: Binding<Bool> {
        Binding(get: { quietOn }, set: { on in
            quietOn = on
            quietStart = on ? Self.minutes(from) : 0
            quietEnd = on ? Self.minutes(to) : 0
        })
    }

    /// Off: the switch off, and 10 PM – 9 AM ready for when it's turned on.
    private func loadQuiet() {
        let q = QuietHours(start: quietStart, end: quietEnd)
        quietOn = !q.isOff
        from = Self.date(q.isOff ? QuietHours.standard.start : q.start)
        to = Self.date(q.isOff ? QuietHours.standard.end : q.end)
    }

    private static func date(_ minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }

    private static func minutes(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private func refresh() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

/// One group: its switch, each kind's, its sound, and (Just for fun) the weather's city.
struct NotifyGroupView: View {
    let group: NotifyGroup
    @Bindable private var prefs = NotifyPrefsModel.shared
    @AppStorage(SettingsKey.airingAlerts) private var alerts = AiringAlerts.air.rawValue

    var body: some View {
        Form {
            Section {
                Toggle(group.title, isOn: $prefs[groupOn: group])
                    .accessibilityIdentifier("notifyGroupToggle")
            } footer: { Text(groupFooter) }

            if prefs[groupOn: group] {
                Section {
                    ForEach(group.kinds) { k in
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(k.title, isOn: $prefs[kindOn: k])
                            if let until = NotifyCenter.resting(k) {
                                HStack {
                                    Text("Resting until \(until.formatted(.dateTime.day().month())): dismissed three times in a row.")
                                        .font(.footnote).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Resume") { NotifyCenter.wake(k); prefs.changed() }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .frame(minHeight: 44)
                                        .accessibilityLabel("Resume \(k.title)")
                                }
                            }
                            if let need = needs(k) {
                                Text(need).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text("Which Ones") } footer: {
                    Text("“Fewer Like This” on a notification turns its kind off here.")
                }

                if group == .newReleases {
                    Section {
                        Picker("When", selection: $alerts) {
                            ForEach(AiringAlerts.allCases.filter { $0 != .off }) { Text($0.title).tag($0.rawValue) }
                        }
                        .onChange(of: alerts) { _, _ in AiringNotifications.reschedule(TrackingStore.shared.shows) }
                    } footer: { Text("For the shows you track (Settings → Tracked Shows).") }
                }

                if group == .fun {
                    Section {
                        NavigationLink(value: LibraryRoute.settingsSubpage(.notifyCity)) {
                            LabeledContent("Weather", value: prefs.place?.name ?? "Not set")
                        }
                    } footer: {
                        Text("Rain, cold and heat need a city: only its position (to two decimals) goes to Open-Meteo for the forecast. Weather data by Open-Meteo.com (CC BY 4.0). Public holidays from Nager.Date, for the city's country or this iPhone's region.")
                    }
                }
            }
        }
        .brandListBackground()
        .navigationTitle(group.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var groupFooter: String {
        switch group {
        case .watching: return "Unfinished films and episodes, a late night, a binge, a week away. From what you watch in Folio."
        case .newReleases: return "The shows you track. Same switch as Settings → Tracked Shows → Notify me."
        case .trending: return "From IMDb's Most Popular charts, fetched when Folio is open. At most three a week."
        case .recommendations: return "From Discover's For you and what you've watched. At most two a week."
        case .library: return "Your library's films. At most two a week."
        case .briefing: return "Friday evening's top titles, new titles on the charts, and the 1st's recap of the month."
        case .fun: return NotifyPrefs.tone == .subtle ? "Off while the personality is Subtle." : "Jokes about your habits, the weather and holidays. At most two a week."
        case .downloads: return "When downloads finish while Folio is in the background. Same switch as Settings → Downloads."
        }
    }

    private func needs(_ k: NotifyKind) -> String? {
        if k.needsWeather, prefs.place == nil { return "Needs a city (Weather, below)." }
        return nil
    }
}

/// Settings → Notifications → Sounds: each group's.
struct NotifySoundsList: View {
    /// Each group's sound, read through the model so a sound picked on the
    /// page over this one shows here when you're back (1.28.5; 1.27.1 read
    /// them again on any settings change, which didn't reach this page
    /// while the picker covered it).
    private var prefs = NotifyPrefsModel.shared

    var body: some View {
        Form {
            Section {
                ForEach(NotifyGroup.allCases) { g in
                    NavigationLink(value: LibraryRoute.settingsSubpage(.notifySound(g))) {
                        LabeledContent(g.title, value: prefs.sound(for: g).label)
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
        .navigationTitle("\(group.title) Sound")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            current = NotifySounds.choice(for: group)
            custom = NotifySounds.custom
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url):
                // Converted off the main thread (1.30.2): a long file held the screen.
                let scoped = url.startAccessingSecurityScopedResource()
                Task { @MainActor in
                    let done = await Task.detached(priority: .userInitiated) {
                        Result { try NotifySounds.importSound(from: url) }
                    }.value
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    switch done {
                    case .success(let name):
                        custom = NotifySounds.custom
                        pick(.custom(name))
                        error = nil
                    case .failure(let e):
                        error = "That file couldn't be read as audio: \(e.localizedDescription)"
                    }
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
        .accessibilityAddTraits(current == s ? .isSelected : [])
    }

    private func pick(_ s: NotifySound) {
        current = s
        NotifyPrefsModel.shared.setSound(s, for: group)
        SoundPreview.shared.play(s)
    }
}

/// The weather's city, found by name (Open-Meteo's geocoding).
struct NotifyCityView: View {
    @State private var query = ""
    @State private var results: [WeatherFeed.Place] = []
    @State private var searching = false
    private var prefs = NotifyPrefsModel.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if let p = prefs.place {
                Section("Now") {
                    Text(p.label)
                    Button("Remove", role: .destructive) { prefs.place = nil }
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
                        prefs.place = r
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
        .navigationTitle("Sent Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Clear Sent List") {
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
