import SwiftUI
import UIKit
import WidgetKit

// The Airing widgets (1.24.0): when tracked shows come out, in your time.
// Airing (small countdown, medium This week, large week agenda, and the
// Lock Screen's), Airing day (small: the day, for episodes with no known
// hour) and Out now (medium: Play when Folio found the episode).

struct AiringEntry: TimelineEntry {
    enum Content {
        case snapshot(AiringSnapshot)
        /// The app hasn't written a snapshot yet.
        case openFolio
        /// No App Group, and the app's Keychain group is refused (1.23.0).
        case cantShare
    }
    let date: Date
    let content: Content
    var pictures: [String: UIImage] = [:]

    var snapshot: AiringSnapshot? { if case .snapshot(let s) = content { return s } else { return nil } }

    /// The rows at this entry's moment (AiringSnapshot.rows).
    var rows: [AiringSnapshot.Row] { snapshot?.rows(at: date) ?? [] }

    var tracksNothing: Bool { snapshot.map { $0.items.isEmpty && ($0.tracked ?? 0) == 0 } ?? false }

    /// How many shows are tracked (the snapshot's count, else its shows).
    var trackedCount: Int { snapshot.map { $0.tracked ?? $0.items.count } ?? 0 }

    func picture(_ name: String?) -> UIImage? { name.flatMap { pictures[$0] } }

    /// Episodes out in the last week, newest first (the Out now widget).
    var recent: [AiringSnapshot.Recent] {
        (snapshot?.recent ?? []).filter { $0.airDate <= date }.sorted { $0.airDate > $1.airDate }
    }

    /// The widget gallery's preview before anything is tracked.
    static func sample(at now: Date = Date()) -> AiringEntry {
        let h: TimeInterval = 3600
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now
        let dayString = { (d: Date) -> String in WatchDayFormat.key(d) }
        var snap = AiringSnapshot(items: [
            .init(id: "sample-1", name: "Your show", network: "HBO", episodes: [.init(label: "S4 · E5", title: "Square One", airDate: now.addingTimeInterval(2 * h + 840))]),
            .init(id: "sample-2", name: "An anime", network: "Crunchyroll", episodes: [.init(label: "E8", title: nil, airDate: tomorrow.addingTimeInterval(12 * h), day: dayString(tomorrow))]),
            .init(id: "sample-3", name: "Another show", network: nil, episodes: [.init(label: "S2 · E4", title: "Spring Tide", airDate: now.addingTimeInterval(74 * h))]),
            .init(id: "sample-4", name: "A new series", network: nil, episodes: [.init(label: "S1 · E9", title: nil, airDate: now.addingTimeInterval(118 * h))]),
        ])
        snap.tracked = 5
        snap.recent = [.init(showID: "sample-5", show: "Your other show", label: "S2 · E1", title: nil, airDate: now.addingTimeInterval(-3 * h),
                             season: 2, number: 1, available: "in your library")]
        return AiringEntry(date: now, content: .snapshot(snap))
    }
}

/// "2026-11-13" for a date, in the phone's calendar.
enum WatchDayFormat {
    static func key(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

enum AiringStyle { case main, day, outNow }

struct AiringWidgetView: View {
    let entry: AiringEntry
    let family: WidgetFamily
    var style: AiringStyle = .main

    var body: some View {
        let rows = entry.rows
        switch family {
        case .accessoryInline:
            AiringInline(row: rows.first, entry: entry)
        case .accessoryRectangular:
            if let r = rows.first { AiringLockTonight(rows: rows, first: r, now: entry.date) } else { AiringLockEmpty(entry: entry) }
        case .accessoryCircular:
            if let r = rows.first { AiringLockCountdown(row: r, now: entry.date) } else { AiringLockEmpty(entry: entry, circular: true) }
        default:
            if case .cantShare = entry.content {
                WidgetMessage(icon: "lock.rectangle", title: "Can't reach Folio", detail: WidgetAccessText.cantShareDetail)
            } else if case .openFolio = entry.content {
                WidgetMessage(icon: "bell.fill", title: "Open Folio once", detail: "to see the shows you track.", url: GlanceLink.home)
            } else if entry.tracksNothing {
                WidgetMessage(icon: "bell", title: "Track a show", detail: "Tap Track on a show's page in Folio, and its next episodes show up here.",
                              action: "Tracking", url: TrackLink.list)
            } else if style == .outNow {
                AiringOutNowTile(entry: entry)
            } else if rows.isEmpty {
                WidgetMessage(icon: "calendar", title: "No dates yet", detail: "New episodes show up here once they're announced.", url: TrackLink.list)
            } else if style == .day {
                AiringDayTile(row: rows.first { !$0.isOut } ?? rows[0], picture: entry.picture((rows.first { !$0.isOut } ?? rows[0]).item.picture), now: entry.date)
            } else {
                switch family {
                case .systemSmall: AiringCountdownTile(row: rows[0], now: entry.date)
                case .systemLarge: AiringAgendaTile(entry: entry, rows: rows)
                default: AiringWeekTile(entry: entry, rows: rows)
                }
            }
        }
    }
}

// MARK: - Times

enum AiringText {
    /// "Today · 9:00 PM", "Fri · 9:00 PM", "13 Nov · 9:00 PM"; a day-only
    /// episode: "Today", "Tomorrow", "Fri", "13 Nov" — never a made-up time.
    static func when(_ e: AiringSnapshot.Episode, now: Date, separator: String = " · ") -> String {
        let d = day(e.localDay() ?? e.airDate, now: now)
        guard e.localDay() == nil else { return d }
        return d + separator + time(e.airDate)
    }

    /// "Today", "Tomorrow", "Fri" (this week), "13 Nov".
    static func day(_ date: Date, now: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return "Today" }
        if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: t) { return "Tomorrow" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 0
        if abs(days) < 7 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// A short day for a chip: "Today", "Fri", "13 Nov".
    static func chip(_ e: AiringSnapshot.Episode, now: Date) -> String {
        let s = day(e.localDay() ?? e.airDate, now: now)
        return s == "Tomorrow" ? (e.localDay() ?? e.airDate).formatted(.dateTime.weekday(.abbreviated)) : s
    }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    /// The episode line: "S4 · E5 · Square One".
    static func episode(_ e: AiringSnapshot.Episode) -> String {
        ([e.label] + [e.title].compactMap { $0 }).joined(separator: " · ")
    }
}

// MARK: - Small: countdown

/// The next episode, counting down by itself (the system's timer text):
/// hours, minutes and seconds within a day, the day further out, then
/// "Out now". A day-only episode says its day.
struct AiringCountdownTile: View {
    let row: AiringSnapshot.Row
    let now: Date

    var body: some View {
        Looked { t in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(row.isOut ? "OUT NOW" : "NEXT UP").font(.system(size: 10, weight: .heavy)).tracking(0.8).foregroundStyle(t.sub).widgetAccentable()
                    Spacer(minLength: 4)
                    if let n = row.item.network {
                        WidgetBadge(fill: t.chip, ink: t.ink) {
                            Text(n).font(.system(size: 10, weight: .bold)).lineLimit(1).padding(.horizontal, 7).padding(.vertical, 3)
                        }
                    }
                }
                Spacer(minLength: 4)
                big(t).font(.system(size: 30, weight: .heavy)).monospacedDigit().tracking(-1).foregroundStyle(t.ink)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(under).font(.system(size: 11)).foregroundStyle(t.sub).lineLimit(1).padding(.top, 2)
                Spacer(minLength: 4)
                Text(row.item.name).font(.system(size: 15, weight: .bold)).foregroundStyle(t.ink).lineLimit(1)
                Text(AiringText.episode(row.episode)).font(.system(size: 11)).foregroundStyle(t.sub).lineLimit(1).padding(.top, 2)
            }
            .padding(14)
            .widgetCard(t)
            .widgetURL(TrackLink.url(id: row.item.id))
        }
    }

    /// Under the big line: the day and time when the big line counts down;
    /// the date (and "day only") when it says the day.
    private var under: String {
        let e = row.episode
        if let day = e.localDay() { return day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " · day only" }
        if row.isOut || e.airDate.timeIntervalSince(now) <= 86400 { return AiringText.when(e, now: now) }
        return e.airDate.formatted(.dateTime.day().month(.abbreviated)) + " · " + AiringText.time(e.airDate)
    }

    @ViewBuilder
    private func big(_ t: WidgetPalette) -> some View {
        if row.isOut {
            Text("Out now")
        } else if let day = row.episode.localDay() {
            Text(AiringText.day(day, now: now))
        } else if row.episode.airDate.timeIntervalSince(now) <= 86400 {
            Text(row.episode.airDate, style: .timer)
        } else {
            Text(AiringText.day(row.episode.airDate, now: now))
        }
    }
}

// MARK: - Small: calendar day

/// The show's poster with its day on a calendar leaf.
struct AiringDayTile: View {
    let row: AiringSnapshot.Row
    let picture: UIImage?
    let now: Date

    var body: some View {
        let day = row.episode.localDay() ?? row.episode.airDate
        Looked { t in
            ZStack(alignment: .bottomLeading) {
                WidgetArt(image: picture, seed: row.item.name)
                WidgetScrim()
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.item.name).font(.system(size: 15, weight: .bold)).lineLimit(2)
                    Text(([row.episode.label, row.isOut ? "Out now" : AiringText.when(row.episode, now: now)]
                          + (row.episode.localDay() != nil ? ["day only"] : [])).joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.bottom, 13)
            }
            .overlay(alignment: .topLeading) {
                WidgetBadge(fill: .white, ink: Color(hex: 0x141312), radius: 12) {
                    VStack(spacing: 0) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased()).font(.system(size: 9, weight: .heavy)).tracking(0.6)
                        Text(day.formatted(.dateTime.day())).font(.system(size: 20, weight: .heavy))
                    }
                    .frame(width: 44).padding(.vertical, 5)
                }
                .padding(12)
            }
            .widgetCard(t)
            .widgetURL(TrackLink.url(id: row.item.id))
        }
    }
}

// MARK: - Medium: this week

/// Today's first and highlighted; the hour when known, the day when not.
struct AiringWeekTile: View {
    let entry: AiringEntry
    let rows: [AiringSnapshot.Row]

    var body: some View {
        let now = entry.date
        let week = rows.filter { ($0.episode.localDay() ?? $0.episode.airDate).timeIntervalSince(now) < 7 * 86400 }
        let shown = Array((week.isEmpty ? Array(rows.prefix(1)) : week).prefix(3))
        Looked { t in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    HStack(spacing: 6) {
                        WidgetLeaf().fill(t.ink).frame(width: 14, height: 14)
                        Text(week.isEmpty ? "Next" : "This week").font(.system(size: 13, weight: .heavy))
                    }
                    .foregroundStyle(t.ink).widgetAccentable()
                    Spacer()
                    Text("\(Set(week.map(\.item.id)).count) of \(entry.trackedCount) tracked").font(.system(size: 11)).foregroundStyle(t.sub)
                }
                ForEach(shown) { r in
                    Link(destination: TrackLink.url(id: r.item.id)) { AiringWeekRow(row: r, now: now, t: t) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .widgetCard(t)
        }
    }
}

private struct AiringWeekRow: View {
    let row: AiringSnapshot.Row
    let now: Date
    let t: WidgetPalette

    var body: some View {
        let isToday = row.isOut || Calendar.current.isDate(row.episode.localDay() ?? row.episode.airDate, inSameDayAs: now)
        HStack(spacing: 10) {
            WidgetBadge(fill: isToday ? t.today : t.chip, ink: isToday ? t.todayInk : t.ink, radius: 9) {
                Text(row.isOut ? "New" : AiringText.chip(row.episode, now: now)).font(.system(size: 11, weight: .heavy)).lineLimit(1)
                    .minimumScaleFactor(0.8).frame(width: 54).padding(.vertical, 4)
            }
            .opacity(isToday || !t.accented ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.item.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(t.ink).lineLimit(1)
                Text(AiringText.episode(row.episode) + (row.episode.localDay() != nil ? " · day only" : ""))
                    .font(.system(size: 11)).foregroundStyle(t.sub).lineLimit(1)
            }
            Spacer(minLength: 6)
            Group {
                if row.isOut { Text("Out now") }
                else if row.episode.localDay() != nil { Text((row.episode.localDay() ?? now).formatted(.dateTime.day().month(.abbreviated))) }
                else { Text(AiringText.time(row.episode.airDate)) }
            }
            .font(.system(size: 12, weight: .bold)).monospacedDigit().foregroundStyle(t.ink).lineLimit(1)
        }
    }
}

// MARK: - Large: week agenda

/// A week strip with a dot on airing days, then each episode in order.
struct AiringAgendaTile: View {
    let entry: AiringEntry
    let rows: [AiringSnapshot.Row]

    var body: some View {
        let now = entry.date
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        let airing = Set(rows.map { cal.startOfDay(for: $0.episode.localDay() ?? $0.episode.airDate) })
        Looked { t in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(now.formatted(.dateTime.month(.wide))).font(.system(size: 15, weight: .heavy)).foregroundStyle(t.ink).widgetAccentable()
                    Spacer()
                    Text("Airing · \(entry.trackedCount) tracked").font(.system(size: 11)).foregroundStyle(t.sub)
                }
                HStack(spacing: 4) {
                    ForEach(days, id: \.self) { d in
                        let today = cal.isDate(d, inSameDayAs: now)
                        let dot = airing.contains(d)
                        dayCell(d, today: today, dot: dot, t: t)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(Array(rows.prefix(5).enumerated()), id: \.element.id) { i, r in
                        if i > 0 { Spacer(minLength: 6) }
                        Link(destination: TrackLink.url(id: r.item.id)) {
                            HStack(spacing: 10) {
                                WidgetThumb(image: entry.picture(r.item.picture), seed: r.item.name).frame(width: 30, height: 42)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(r.item.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(t.ink).lineLimit(1)
                                    Text(AiringText.episode(r.episode)).font(.system(size: 11)).foregroundStyle(t.sub).lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                VStack(alignment: .trailing, spacing: 0) {
                                    Text(r.isOut ? "Out now" : AiringText.day(r.episode.localDay() ?? r.episode.airDate, now: now))
                                        .font(.system(size: 11, weight: .bold)).foregroundStyle(t.ink)
                                    Text(r.isOut ? AiringText.time(r.episode.airDate) : r.episode.localDay() != nil ? "day only" : AiringText.time(r.episode.airDate))
                                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(t.sub)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .widgetCard(t)
        }
    }

    @ViewBuilder
    private func dayCell(_ d: Date, today: Bool, dot: Bool, t: WidgetPalette) -> some View {
        let cell = VStack(spacing: 3) {
            Text(d.formatted(.dateTime.weekday(.abbreviated)).uppercased()).font(.system(size: 9, weight: .bold)).opacity(0.75)
            Text(d.formatted(.dateTime.day())).font(.system(size: 15, weight: .heavy))
            Circle().frame(width: 5, height: 5).opacity(dot ? 1 : 0)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 6)
        if today {
            WidgetBadge(fill: t.today, ink: t.todayInk, radius: 10) { cell }.widgetAccentable()
        } else {
            cell.foregroundStyle(t.ink).overlay(alignment: .bottom) {
                Circle().fill(t.accent).frame(width: 5, height: 5).padding(.bottom, 6).opacity(dot ? 1 : 0).widgetAccentable()
            }
        }
    }
}

// MARK: - Medium: out now

/// The newest episode that's out. Play when Folio found it in your library
/// or on a server (the app looks it up again when tapped); Show opens the
/// show's tracking page.
struct AiringOutNowTile: View {
    let entry: AiringEntry

    var body: some View {
        Looked { t in
            if let r = entry.recent.first {
                content(t, picture: entry.picture(r.picture), badge: Self.badge(r.airDate, now: entry.date), show: r.show,
                        line: ([r.label] + [r.available.map { "\($0)" } ?? r.title].compactMap { $0 }).joined(separator: " · "),
                        play: r.available != nil ? r.number.map { TrackLink.aired(id: r.showID, season: r.season, episode: $0) } : nil,
                        showURL: TrackLink.url(id: r.showID))
            } else if let next = entry.rows.first {
                content(t, picture: entry.picture(next.item.picture), badge: next.isOut ? "OUT NOW" : "NEXT · " + AiringText.chip(next.episode, now: entry.date).uppercased(),
                        show: next.item.name, line: AiringText.episode(next.episode) + (next.isOut ? "" : " · " + AiringText.when(next.episode, now: entry.date)),
                        play: nil, showURL: TrackLink.url(id: next.item.id))
            } else {
                WidgetMessage(icon: "calendar", title: "Nothing out this week", detail: "New episodes of the shows you track show up here.", url: TrackLink.list)
            }
        }
    }

    /// "OUT NOW" for six hours, then "NEW · TUE".
    static func badge(_ aired: Date, now: Date) -> String {
        now.timeIntervalSince(aired) < AiringClock.outNowWindow ? "OUT NOW" : "NEW · " + AiringText.day(aired, now: now).uppercased()
    }

    private func content(_ t: WidgetPalette, picture: UIImage?, badge: String, show: String, line: String, play: URL?, showURL: URL) -> some View {
        ZStack(alignment: .leading) {
            WidgetArt(image: picture, seed: show)
            WidgetScrim(leading: true)
            VStack(alignment: .leading, spacing: 0) {
                WidgetBadge(fill: .white, ink: Color(hex: 0x141312)) {
                    Text(badge).font(.system(size: 10, weight: .heavy)).tracking(0.8).padding(.horizontal, 8).padding(.vertical, 3)
                }
                .fixedSize()
                Text(show).font(.system(size: 18, weight: .heavy)).lineLimit(2).padding(.top, 8)
                Text(line).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8)).lineLimit(1).padding(.top, 3)
                Spacer(minLength: 6)
                HStack(spacing: 8) {
                    if let play { Link(destination: play) { WidgetPill(text: "Play", icon: "play.fill") } }
                    Link(destination: showURL) { WidgetPill(text: "Show", primary: play == nil ? true : false, font: .system(size: 12, weight: .semibold)) }
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: 250, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, 16).padding(.top, 16).padding(.bottom, 14)
        }
        .widgetCard(t)
        .widgetURL(showURL)
    }
}

// MARK: - Lock Screen

/// "TONIGHT 9:00 PM", the show and episode, and what else is coming.
struct AiringLockTonight: View {
    let rows: [AiringSnapshot.Row]
    let first: AiringSnapshot.Row
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(header).font(.caption2.weight(.bold)).textCase(.uppercase).lineLimit(1).widgetAccentable()
            Text("\(first.item.name) \(first.episode.label)").font(.headline).lineLimit(1)
            if let more = rows.dropFirst().first {
                Text("+ \(more.item.name) " + (more.isOut ? "out now" : "on " + AiringText.day(more.episode.localDay() ?? more.episode.airDate, now: now).replacingOccurrences(of: "Today", with: "today")))
                    .font(.caption).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(TrackLink.url(id: first.item.id))
    }

    private var header: String {
        if first.isOut { return "Out now" }
        let e = first.episode
        let cal = Calendar.current
        let day = e.localDay() ?? e.airDate
        var name = AiringText.day(day, now: now)
        if cal.isDate(day, inSameDayAs: now), e.localDay() == nil, cal.component(.hour, from: e.airDate) >= 17 { name = "Tonight" }
        return e.localDay() == nil ? name + " " + AiringText.time(e.airDate) : name
    }
}

/// The time to the next episode in a ring that fills as it comes.
struct AiringLockCountdown: View {
    let row: AiringSnapshot.Row
    let now: Date

    var body: some View {
        let date = row.episode.airDate
        Group {
            if row.isOut || row.episode.localDay() != nil || date.timeIntervalSince(now) > 86400 {
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 0) {
                        Image(systemName: row.isOut ? "bell.badge.fill" : "calendar").font(.system(size: 12, weight: .semibold)).widgetAccentable()
                        Text(row.isOut ? "Out" : AiringText.chip(row.episode, now: now)).font(.system(size: 13, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.6)
                    }
                    .padding(4)
                }
            } else {
                ProgressView(timerInterval: date.addingTimeInterval(-86400)...date, countsDown: false) {
                    Text(row.item.name)
                } currentValueLabel: {
                    Text(date, style: .timer).font(.system(size: 11, weight: .heavy)).monospacedDigit().multilineTextAlignment(.center)
                }
                .progressViewStyle(.circular)
                .widgetAccentable()
            }
        }
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(TrackLink.url(id: row.item.id))
        .accessibilityLabel("\(row.item.name), \(AiringText.when(row.episode, now: now))")
    }
}

struct AiringLockEmpty: View {
    let entry: AiringEntry
    var circular = false

    var body: some View {
        Group {
            if circular {
                ZStack { AccessoryWidgetBackground(); Image(systemName: "bell").font(.title3).widgetAccentable() }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Label("Airing", systemImage: "bell").font(.headline).widgetAccentable()
                    Text(detail).font(.caption).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    private var detail: String {
        if case .openFolio = entry.content { return "Open Folio once" }
        if case .cantShare = entry.content { return "Can't reach Folio" }
        return entry.tracksNothing ? "Nothing tracked" : "No dates yet"
    }
}

/// One line over the clock: "MobLand S1 · E5 in 2 hr" or "… is out".
struct AiringInline: View {
    let row: AiringSnapshot.Row?
    let entry: AiringEntry

    var body: some View {
        line
            .containerBackground(for: .widget) { Color.clear }
            .widgetURL(row.map { TrackLink.url(id: $0.item.id) })
    }

    private var line: Text {
        guard let row else {
            if case .openFolio = entry.content { return Text("Open Folio for your shows") }
            if case .cantShare = entry.content { return Text("Can't reach Folio") }
            return Text(entry.tracksNothing ? "Nothing tracked" : "No new episodes")
        }
        if row.isOut { return Text("\(row.item.name) \(row.episode.label) is out") }
        if let day = row.episode.localDay() {
            let cal = Calendar.current
            let n = cal.dateComponents([.day], from: cal.startOfDay(for: entry.date), to: day).day ?? 0
            return Text("\(row.item.name) \(row.episode.label) " + (n <= 0 ? "today" : n == 1 ? "tomorrow" : "in \(n) days"))
        }
        return Text("\(row.item.name) \(row.episode.label) in ") + Text(row.episode.airDate, style: .relative)
    }
}
