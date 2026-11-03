import SwiftUI
import UIKit
import WidgetKit

/// The Airing widget (1.21.0): when the shows you track air next, on the
/// Home Screen (small, medium, large) and the Lock Screen (rectangular,
/// inline). It reads the snapshot the app writes (AiringSnapshotWriter) and
/// moves on by itself: one timeline entry per air time, so "in 2 h" turns
/// into "Out now" without the app running.
struct AiringWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AiringSnapshot.widgetKind, provider: AiringProvider()) { entry in
            AiringWidgetView(entry: entry)
        }
        .configurationDisplayName("Airing")
        .description("When the shows you track air next, in your time.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Timeline

struct AiringEntry: TimelineEntry {
    enum Content {
        case snapshot(AiringSnapshot)
        /// No group container, or the app hasn't written a snapshot yet.
        case openFolio
    }
    let date: Date
    let content: Content
    var pictures: [String: UIImage] = [:]

    /// The rows at this entry's moment (AiringSnapshot.rows).
    var rows: [AiringSnapshot.Row] {
        if case .snapshot(let s) = content { return s.rows(at: date) }
        return []
    }

    var tracksNothing: Bool {
        if case .snapshot(let s) = content { return s.items.isEmpty }
        return false
    }

    /// The widget gallery's preview before anything is tracked.
    static func sample(at now: Date = Date()) -> AiringEntry {
        let h: TimeInterval = 3600
        let snap = AiringSnapshot(items: [
            .init(id: "sample-1", name: "Your show", network: "HBO", episodes: [.init(label: "S2 · E5", title: "Episode title", airDate: now.addingTimeInterval(-h))]),
            .init(id: "sample-2", name: "An anime", network: "Crunchyroll", episodes: [.init(label: "E8", title: nil, airDate: now.addingTimeInterval(3 * h))]),
            .init(id: "sample-3", name: "Another show", network: nil, episodes: [.init(label: "S1 · E2", title: nil, airDate: now.addingTimeInterval(28 * h))]),
            .init(id: "sample-4", name: "A new series", network: nil, episodes: [.init(label: "S1 · E1", title: "Pilot", airDate: now.addingTimeInterval(80 * h))]),
        ])
        return AiringEntry(date: now, content: .snapshot(snap))
    }
}

struct AiringProvider: TimelineProvider {
    func placeholder(in context: Context) -> AiringEntry { .sample() }

    func getSnapshot(in context: Context, completion: @escaping (AiringEntry) -> Void) {
        let entry = Self.entries(from: Date()).first ?? AiringEntry(date: Date(), content: .openFolio)
        completion(context.isPreview && entry.rows.isEmpty ? .sample() : entry)
    }

    /// One entry now and one at each air time and each "Out now" ending; a
    /// new timeline after the last (the app also reloads it whenever the
    /// schedules change).
    func getTimeline(in context: Context, completion: @escaping (Timeline<AiringEntry>) -> Void) {
        let entries = Self.entries(from: Date())
        completion(Timeline(entries: entries, policy: entries.count > 1 ? .atEnd : .never))
    }

    static func entries(from now: Date) -> [AiringEntry] {
        let dir = AiringSnapshot.directory()
        guard let snap = AiringSnapshot.read(from: dir) else { return [AiringEntry(date: now, content: .openFolio)] }
        var pictures: [String: UIImage] = [:]
        if let dir {
            for name in snap.items.compactMap(\.picture) {
                if let img = UIImage(contentsOfFile: dir.appendingPathComponent(name).path) { pictures[name] = img }
            }
        }
        return snap.timelineDates(from: now).map { AiringEntry(date: $0, content: .snapshot(snap), pictures: pictures) }
    }
}

// MARK: - Views

struct AiringWidgetView: View {
    let entry: AiringEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let rows = entry.rows
        switch family {
        case .accessoryInline:
            InlineLine(row: rows.first, tracksNothing: entry.tracksNothing)
        case .accessoryRectangular:
            if let r = rows.first { LockScreenAiring(row: r) } else { LockScreenEmpty(entry: entry) }
        default:
            if case .openFolio = entry.content {
                AiringMessage(icon: "bell.fill", title: "Open Folio", detail: "to see the shows you track.")
            } else if entry.tracksNothing {
                AiringMessage(icon: "bell", title: "Nothing tracked", detail: "Tap Track on a show's page in Folio.")
            } else if rows.isEmpty {
                AiringMessage(icon: "calendar", title: "No dates yet", detail: "New episodes show up here once they're announced.")
            } else if family == .systemSmall {
                SmallAiring(row: rows[0], picture: picture(rows[0]), now: entry.date)
            } else {
                AiringList(rows: Array(rows.prefix(family == .systemLarge ? 7 : 3)), pictures: entry.pictures, now: entry.date, large: family == .systemLarge)
            }
        }
    }

    private func picture(_ r: AiringSnapshot.Row) -> UIImage? { r.item.picture.flatMap { entry.pictures[$0] } }
}

/// "Today 9:00 PM", "Tue 9:00 PM", "Nov 20, 9:00 PM" in the phone's time zone.
private struct AirTime: View {
    let date: Date
    let now: Date

    var body: some View {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) {
            Text("Today ") + Text(date, style: .time)
        } else if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: tomorrow) {
            Text("Tomorrow ") + Text(date, style: .time)
        } else if date.timeIntervalSince(now) < 6 * 86400 {
            Text(date, format: .dateTime.weekday(.abbreviated).hour().minute())
        } else {
            Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
        }
    }
}

/// "Out now", or a countdown that runs by itself ("2 hr, 5 min").
private struct Countdown: View {
    let row: AiringSnapshot.Row

    var body: some View {
        if row.isOut {
            Text("Out now").fontWeight(.semibold)
        } else {
            Text(row.episode.airDate, style: .relative).monospacedDigit()
        }
    }
}

private struct SmallAiring: View {
    let row: AiringSnapshot.Row
    let picture: UIImage?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top) {
                Poster(image: picture).frame(width: 34, height: 51)
                Spacer(minLength: 4)
                Image(systemName: row.isOut ? "bell.badge.fill" : "bell.fill").font(.caption).foregroundStyle(WidgetTheme.accent)
            }
            Spacer(minLength: 4)
            Text(row.item.name).font(.subheadline.weight(.bold)).lineLimit(2)
            Text(row.episode.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            AirTime(date: row.episode.airDate, now: now).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Countdown(row: row).font(.caption.weight(.semibold)).foregroundStyle(WidgetTheme.accent).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(WidgetTheme.text)
        .containerBackground(WidgetTheme.background, for: .widget)
        .widgetURL(TrackLink.url(id: row.item.id))
    }
}

/// Medium (three rows) and large (seven), each row its own link.
private struct AiringList: View {
    let rows: [AiringSnapshot.Row]
    let pictures: [String: UIImage]
    let now: Date
    let large: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if large {
                HStack(spacing: 6) {
                    Image(systemName: "bell.fill").foregroundStyle(WidgetTheme.accent)
                    Text("Airing").fontWeight(.bold)
                }
                .font(.subheadline)
                .padding(.bottom, 8)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                if i > 0 { Spacer(minLength: 4) }
                Link(destination: TrackLink.url(id: r.item.id)) {
                    HStack(spacing: 10) {
                        Poster(image: r.item.picture.flatMap { pictures[$0] }).frame(width: 26, height: 39)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text([r.episode.label, r.episode.title].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        VStack(alignment: .trailing, spacing: 1) {
                            AirTime(date: r.episode.airDate, now: now).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            Countdown(row: r).font(.caption.weight(.semibold)).foregroundStyle(r.isOut ? WidgetTheme.accent : WidgetTheme.text)
                                .lineLimit(1).multilineTextAlignment(.trailing)
                        }
                        .frame(maxWidth: 110, alignment: .trailing)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(WidgetTheme.text)
        .containerBackground(WidgetTheme.background, for: .widget)
    }
}

/// The Lock Screen: the soonest (or just out), in the system's tint.
private struct LockScreenAiring: View {
    let row: AiringSnapshot.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.item.name).font(.headline).lineLimit(1).widgetAccentable()
            Text(row.episode.label).font(.caption).lineLimit(1)
            Countdown(row: row).font(.caption).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(TrackLink.url(id: row.item.id))
    }
}

private struct LockScreenEmpty: View {
    let entry: AiringEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label("Airing", systemImage: "bell").font(.headline).widgetAccentable()
            Text(detail).font(.caption).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { Color.clear }
    }

    private var detail: String {
        if case .openFolio = entry.content { return "Open Folio" }
        return entry.tracksNothing ? "Nothing tracked" : "No dates yet"
    }
}

/// One line over the clock: "MobLand S1 · E5 in 2 hr" or "… is out".
private struct InlineLine: View {
    let row: AiringSnapshot.Row?
    let tracksNothing: Bool

    var body: some View {
        line
            .containerBackground(for: .widget) { Color.clear }
            .widgetURL(row.map { TrackLink.url(id: $0.item.id) })
    }

    private var line: Text {
        guard let row else { return Text(tracksNothing ? "Nothing tracked" : "No new episodes") }
        if row.isOut { return Text("\(row.item.name) \(row.episode.label) is out") }
        return Text("\(row.item.name) \(row.episode.label) in ") + Text(row.episode.airDate, style: .relative)
    }
}

private struct AiringMessage: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon).font(.title2).foregroundStyle(WidgetTheme.accent)
            Spacer(minLength: 0)
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(WidgetTheme.text)
        .containerBackground(WidgetTheme.background, for: .widget)
    }
}

private struct Poster: View {
    let image: UIImage?

    var body: some View {
        Group {
            if let image {
                Color.clear.overlay { Image(uiImage: image).resizable().scaledToFill() }.clipped()
            } else {
                ZStack {
                    WidgetTheme.fill
                    Image(systemName: "tv").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(WidgetTheme.hairline))
    }
}
