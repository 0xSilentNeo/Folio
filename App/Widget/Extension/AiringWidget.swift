import SwiftUI
import Security
import UIKit
import WidgetKit

/// The Airing widgets (1.21.0; redesigned in 1.24.0): when the shows you
/// track air next. They read the snapshot the app writes
/// (AiringSnapshotWriter) and move on by themselves: an entry at each air
/// time, a day before each (the countdown starts), at each "Out now"
/// ending and at each midnight, so "Tomorrow" becomes "Today" without the app.
struct AiringWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.airing, provider: AiringProvider()) { entry in
            FamilyReader { AiringWidgetView(entry: entry, family: $0) }
        }
        .configurationDisplayName("Airing")
        .description("When the shows you track air next, in your time.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular, .accessoryInline])
        .contentMarginsDisabled()
    }
}

struct AiringDayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.airingDay, provider: AiringProvider()) { entry in
            FamilyReader { AiringWidgetView(entry: entry, family: $0, style: .day) }
        }
        .configurationDisplayName("Airing Day")
        .description("The next episode's day, with the show's poster.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

struct AiringOutNowWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.airingOutNow, provider: AiringProvider()) { entry in
            FamilyReader { AiringWidgetView(entry: entry, family: $0, style: .outNow) }
        }
        .configurationDisplayName("Out Now")
        .description("The newest episode of a show you track, and Play when Folio has it.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

// MARK: - Timeline

struct AiringProvider: TimelineProvider {
    func placeholder(in context: Context) -> AiringEntry { .sample() }

    func getSnapshot(in context: Context, completion: @escaping (AiringEntry) -> Void) {
        let entry = Self.entries(from: Date(), family: context.family).first ?? AiringEntry(date: Date(), content: .openFolio)
        completion(context.isPreview && entry.rows.isEmpty && entry.recent.isEmpty ? .sample() : entry)
    }

    /// The entries below; a new timeline after the last (the app also
    /// reloads it whenever the schedules change).
    func getTimeline(in context: Context, completion: @escaping (Timeline<AiringEntry>) -> Void) {
        let entries = Self.entries(from: Date(), family: context.family)
        // Nothing read (1.28.6): asked again in an hour, not never.
        if entries.count == 1, case .snapshot = entries[0].content {
            completion(Timeline(entries: entries, policy: .never))
        } else if entries.count == 1 {
            completion(Timeline(entries: entries, policy: .after(Date().addingTimeInterval(3600))))
        } else {
            completion(Timeline(entries: entries, policy: .atEnd))
        }
    }

    /// The pictures a family's widgets draw at these moments (1.30.2):
    /// every show's was decoded before the timeline was handed over. The
    /// Lock Screen's draw none; small, the first row's (Airing Day: the
    /// first not out yet); medium, the first row's and the newest episode
    /// out (Out Now); large, the first five rows'. No family: all of them.
    static func pictureNames(_ snap: AiringSnapshot, at dates: [Date], family: WidgetFamily?) -> Set<String> {
        guard let family else { return Set(snap.items.compactMap(\.picture) + (snap.recent ?? []).compactMap(\.picture)) }
        var names = Set<String>()
        switch family {
        case .accessoryInline, .accessoryRectangular, .accessoryCircular: return names
        default: break
        }
        for date in dates {
            let rows = snap.rows(at: date)
            var wanted: [String?] = []
            switch family {
            case .systemSmall:
                wanted = [rows.first?.item.picture, rows.first(where: { !$0.isOut })?.item.picture]
            case .systemMedium:
                let out = (snap.recent ?? []).filter { $0.airDate <= date }
                let newest = out.map(\.airDate).max()
                wanted = [rows.first?.item.picture] + out.filter { $0.airDate == newest }.map(\.picture)
            default:
                wanted = rows.prefix(5).map(\.item.picture)
            }
            for name in wanted { if let name { names.insert(name) } }
        }
        return names
    }

    static func entries(from now: Date, family: WidgetFamily? = nil) -> [AiringEntry] {
        let dir = WidgetStore.airing()
        guard let snap = AiringSnapshot.read(from: dir) else {
            return [AiringEntry(date: now, content: WidgetAccess.cantShare(dir) ? .cantShare : .openFolio)]
        }
        if dir?.isKeychain == true { KeychainShare.widgetSaw("Airing: \(snap.items.count) show(s)") }
        // A day before each air time too: the small widget's countdown
        // starts there (further out it shows the day).
        var dates = Set(snap.timelineDates(from: now))
        for e in snap.items.flatMap(\.episodes) where e.day == nil {
            let start = e.airDate.addingTimeInterval(-86400)
            if start > now { dates.insert(start) }
        }
        // 24 entries, not 80 (1.30.2): less to make before the timeline is
        // handed over; a new one is asked for after the last.
        let moments = Array(dates.sorted().prefix(24))
        var pictures: [String: UIImage] = [:]
        if let dir {
            for name in pictureNames(snap, at: moments, family: family) {
                if let data = dir.read(name), let img = UIImage(data: data) { pictures[name] = img }
            }
        }
        return moments.map { AiringEntry(date: $0, content: .snapshot(snap), pictures: pictures) }
    }
}

/// Whether the widget can never see Folio's data on this install (1.23.0):
/// no App Group, and the app's Keychain group refused. Then the widget says
/// so instead of "Open Folio", which never helped.
enum WidgetAccess {
    static func cantShare(_ store: WidgetStore?) -> Bool {
        guard FolioGroup.container == nil else { return false }
        guard store != nil, let status = KeychainShare.reachable() else { return true }
        return status == errSecMissingEntitlement
    }
}
