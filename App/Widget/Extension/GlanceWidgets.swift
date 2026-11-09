import SwiftUI
import UIKit
import WidgetKit

// The 1.24.0 widgets that read GlanceSnapshot: Downloads, Your week, New on
// your servers and Pick for tonight. Each reloads when the app writes its
// file (GlanceWriter); Your week also at midnight, when its week moves on.

struct DownloadsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.downloads, provider: GlanceProvider(kind: .downloads)) { entry in
            GlanceWidgetView(entry: entry, kind: .downloads)
        }
        .configurationDisplayName("Downloads")
        .description("How far, how fast, how long; when idle, what's ready offline.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

struct YourWeekWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.yourWeek, provider: GlanceProvider(kind: .week)) { entry in
            GlanceWidgetView(entry: entry, kind: .week)
        }
        .configurationDisplayName("Your Week")
        .description("What you watched in the last seven days. Counted on your phone; nothing leaves it.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

struct NewOnServersWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.newOnServers, provider: GlanceProvider(kind: .servers)) { entry in
            GlanceWidgetView(entry: entry, kind: .servers)
        }
        .configurationDisplayName("New on Your Server")
        .description("The newest releases in your server's library, with their quality.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

struct PickTonightWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.pickTonight, provider: GlanceProvider(kind: .pick)) { entry in
            GlanceWidgetView(entry: entry, kind: .pick)
        }
        .configurationDisplayName("Pick for Tonight")
        .description("Something in your library you haven't started. Shuffle for another.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

struct GlanceProvider: TimelineProvider {
    let kind: GlanceKind

    func placeholder(in context: Context) -> GlanceEntry { .sample() }

    func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
        let entry = load(Date())
        completion(context.isPreview && entry.access != .ok ? .sample() : entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        let now = Date()
        var entries = [load(now)]
        // Your week: again at each of the next seven midnights, when a day
        // leaves the week (the tile works the week out from its days).
        if kind == .week {
            let today = Calendar.current.startOfDay(for: now)
            for d in 1...7 {
                guard let midnight = Calendar.current.date(byAdding: .day, value: d, to: today) else { continue }
                entries.append(GlanceEntry(date: midnight, access: entries[0].access, week: entries[0].week))
            }
        }
        // Downloads (1.25.0): again when the estimate runs out, so its
        // "3 min" doesn't go on counting up past it until Folio writes again.
        if kind == .downloads, let run = entries[0].downloads?.run, let end = run.finishBy, end > now, !run.done {
            var at = entries[0]
            at = GlanceEntry(date: end, access: at.access, downloads: at.downloads, pictures: at.pictures)
            entries.append(at)
        }
        // And when the speed it shows goes stale (1.27.0), so the tile drops it.
        if kind == .downloads, let d = entries[0].downloads, let run = d.run, !run.done, run.speed > 0 {
            let stale = d.written.addingTimeInterval(DownloadsGlance.speedFresh)
            if stale > now { entries.append(GlanceEntry(date: stale, access: entries[0].access, downloads: d, pictures: entries[0].pictures)) }
        }
        entries.sort { $0.date < $1.date }
        completion(Timeline(entries: entries, policy: kind == .week ? .atEnd : .never))
    }

    func load(_ now: Date) -> GlanceEntry {
        let store = WidgetStore.glance()
        var e = GlanceEntry(date: now)
        switch kind {
        case .downloads: e.downloads = DownloadsGlance.read(from: store)
        case .week: e.week = WeekGlance.read(from: store)
        case .servers: e.servers = ServersGlance.read(from: store)
        case .pick:
            e.picks = PicksGlance.read(from: store)
            e.pickIndex = PickIndex.current(store)
        }
        let has = e.downloads != nil || e.week != nil || e.servers != nil || e.picks != nil
        if !has {
            // Downloads and Your week still draw with nothing written: "Nothing downloading", "0 min".
            if WidgetAccess.cantShare(store) { e.access = .cantShare }
            else if kind == .servers || kind == .pick { e.access = ContinueSnapshot.read(from: WidgetStore.continueWatching()) == nil ? .openFolio : .ok }
        }
        if let store {
            var names: [String] = []
            if let s = e.servers { names += s.releases.prefix(4).map(ServersTile.pictureName) }
            if let p = e.picks?.picks, !p.isEmpty { names += [p[e.pickIndex % p.count].picture].compactMap { $0 } }
            for n in names { if let d = store.read(n), let img = UIImage(data: d) { e.pictures[n] = img } }
        }
        return e
    }
}
