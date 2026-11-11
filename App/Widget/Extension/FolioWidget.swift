import SwiftUI
import UIKit
import WidgetKit

/// Folio's widgets. 1.24.0 redesigned them: one look per widget that follows
/// the Home Screen's appearance (light, dark, clear, tinted: WidgetLook),
/// four Continue Watching styles, three Airing ones, Downloads, Your week,
/// New on your servers, Pick for tonight, and the Resume control. The views
/// are in App/Widget/Shared/Views (the app's lab gallery draws them too);
/// here are the widgets themselves and what they read.
@main
struct FolioWidgets: WidgetBundle {
    var body: some Widget {
        ContinueWatchingWidget()
        ContinueRingWidget()
        ContinueEpisodeWidget()
        ContinueShelfWidget()
        AiringWidget()
        AiringDayWidget()
        AiringOutNowWidget()
        DownloadsWidget()
        YourWeekWidget()
        NewOnServersWidget()
        PickTonightWidget()
        DownloadActivityWidget()
        if #available(iOSApplicationExtension 18.0, *) {
            ResumeControl()
        }
    }
}

// MARK: - Continue Watching

/// Hero: the small widget, the medium one with Up next, the large one with
/// a list; and the Lock Screen's. The kind is 1.20.3's, so widgets already
/// on a Home Screen carry on.
struct ContinueWatchingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.continueWatching, provider: ContinueProvider()) { entry in
            FamilyReader { ContinueWidgetView(entry: entry, family: $0) }
        }
        .configurationDisplayName("Continue Watching")
        .description("Pick up where you left off.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular, .accessoryInline])
        .contentMarginsDisabled()
    }
}

struct ContinueRingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.continueRing, provider: ContinueProvider()) { entry in
            FamilyReader { ContinueWidgetView(entry: entry, family: $0, style: .ring) }
        }
        .configurationDisplayName("Progress")
        .description("How much is left of what you're watching.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

struct ContinueEpisodeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.continueEpisode, provider: ContinueProvider()) { entry in
            FamilyReader { ContinueWidgetView(entry: entry, family: $0, style: .episode) }
        }
        .configurationDisplayName("Next Episode")
        .description("Resume, or go straight to the next episode.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

struct ContinueShelfWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.continueShelf, provider: ContinueProvider()) { entry in
            FamilyReader { ContinueWidgetView(entry: entry, family: $0, style: .shelf) }
        }
        .configurationDisplayName("Continue Shelf")
        .description("Everything you're in the middle of, as posters.")
        .supportedFamilies([.systemLarge])
        .contentMarginsDisabled()
    }
}

/// One entry and no schedule: the app asks WidgetKit to reload whenever it
/// writes a new snapshot (ContinueSnapshotWriter), so there's nothing to poll.
struct ContinueProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContinueEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (ContinueEntry) -> Void) {
        let entry = Self.load()
        // The gallery shows what you're watching, or a sample when there's nothing yet.
        completion(context.isPreview && !entry.hasItems ? .sample : entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueEntry>) -> Void) {
        let entry = Self.load()
        // Nothing read (1.28.6): asked again in a quarter of an hour. With
        // .never a read that failed once (before the first unlock after a
        // restart, say) left "Open Folio once" until the history changed.
        switch entry.content {
        case .openFolio, .cantShare: completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900))))
        default: completion(Timeline(entries: [entry], policy: .never))
        }
    }

    static func load() -> ContinueEntry {
        let dir = WidgetStore.continueWatching()
        guard let snapshot = ContinueSnapshot.read(from: dir) else {
            return ContinueEntry(date: Date(), content: WidgetAccess.cantShare(dir) ? .cantShare : .openFolio)
        }
        if dir?.isKeychain == true { KeychainShare.widgetSaw("Continue Watching: \(snapshot.items.count) item(s)") }
        guard !snapshot.items.isEmpty else { return ContinueEntry(date: Date(), content: .empty) }
        var pictures: [String: UIImage] = [:]
        if let dir {
            for name in snapshot.items.flatMap({ [$0.picture, $0.poster] }).compactMap({ $0 }) {
                if let data = dir.read(name), let img = UIImage(data: data) { pictures[name] = img }
            }
        }
        return ContinueEntry(date: Date(), content: .items(snapshot.items), pictures: pictures)
    }
}

/// The widget's family, handed to views that also draw in the app's gallery
/// (where there's no family to read).
struct FamilyReader<Content: View>: View {
    @Environment(\.widgetFamily) private var family
    @ViewBuilder let content: (WidgetFamily) -> Content
    var body: some View { content(family) }
}
