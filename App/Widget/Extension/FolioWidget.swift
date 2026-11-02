import SwiftUI
import UIKit
import WidgetKit

/// Folio's widgets (1.20.3 (2 Nov)): Continue Watching on the Home Screen
/// (small, medium) and the Lock Screen (rectangular).
@main
struct FolioWidgets: WidgetBundle {
    var body: some Widget {
        ContinueWatchingWidget()
    }
}

struct ContinueWatchingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ContinueSnapshot.widgetKind, provider: ContinueProvider()) { entry in
            ContinueWidgetView(entry: entry)
        }
        .configurationDisplayName("Continue Watching")
        .description("Pick up where you left off.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

// MARK: - Timeline

struct ContinueEntry: TimelineEntry {
    enum Content {
        case items([ContinueSnapshot.Item])
        /// The group is there but Continue Watching is empty.
        case empty
        /// No group container, or the app hasn't written a snapshot yet.
        case openFolio
    }
    let date: Date
    let content: Content
    var pictures: [String: UIImage] = [:]

    var hasItems: Bool { if case .items = content { return true } else { return false } }

    /// The widget gallery's preview before Folio has anything to show.
    static let sample = ContinueEntry(date: Date(), content: .items([
        .init(id: "sample-1", title: "Your show", line: "S1 · E3 · Where you left off", progress: 0.4, remaining: 840),
        .init(id: "sample-2", title: "Another show", line: "S2 · E7", progress: 0.7, remaining: 1080),
        .init(id: "sample-3", title: "A film", line: nil, progress: 0.2, remaining: 6000),
    ]))
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
        completion(Timeline(entries: [Self.load()], policy: .never))
    }

    static func load() -> ContinueEntry {
        let dir = ContinueSnapshot.directory()
        guard let snapshot = ContinueSnapshot.read(from: dir) else { return ContinueEntry(date: Date(), content: .openFolio) }
        guard !snapshot.items.isEmpty else { return ContinueEntry(date: Date(), content: .empty) }
        var pictures: [String: UIImage] = [:]
        if let dir {
            for name in snapshot.items.compactMap(\.picture) {
                if let img = UIImage(contentsOfFile: dir.appendingPathComponent(name).path) { pictures[name] = img }
            }
        }
        return ContinueEntry(date: Date(), content: .items(snapshot.items), pictures: pictures)
    }
}

// MARK: - Views

struct ContinueWidgetView: View {
    let entry: ContinueEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch entry.content {
        case .items(let items):
            switch family {
            case .accessoryRectangular: LockScreenRow(item: items[0])
            case .systemMedium where items.count > 1: MediumList(items: Array(items.prefix(3)), pictures: entry.pictures)
            default: HeroTile(item: items[0], picture: items[0].picture.flatMap { entry.pictures[$0] })
            }
        case .empty:
            Message(icon: "play.rectangle", title: "Nothing to continue", detail: "What you start in Folio shows up here.")
        case .openFolio:
            Message(icon: "play.rectangle.fill", title: "Open Folio", detail: "to see what you're watching.")
        }
    }
}

/// One entry over its picture, like Home's Continue Watching card: the
/// small widget, and the medium one when there's only one entry.
private struct HeroTile: View {
    let item: ContinueSnapshot.Item
    let picture: UIImage?
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Spacer(minLength: 0)
            Text(item.title)
                .font(.subheadline.weight(.bold))
                .lineLimit(family == .systemSmall ? 2 : 1)
            if let line = item.line {
                Text(line).font(.caption2).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            }
            ProgressBar(progress: item.progress, track: .white.opacity(0.3), fill: .white)
                .padding(.top, 4)
            Text(item.remainingText).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.75))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
        // Text sits on a dark scrim over the picture: dark in both appearances, as on Home.
        .environment(\.colorScheme, .dark)
        .containerBackground(for: .widget) {
            ZStack {
                Picture(image: picture)
                LinearGradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.88)], startPoint: .top, endPoint: .bottom)
            }
        }
        .widgetURL(ContinueLink.url(id: item.id))
    }
}

/// Up to three entries, each its own link.
private struct MediumList: View {
    let items: [ContinueSnapshot.Item]
    let pictures: [String: UIImage]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                if i > 0 { Spacer(minLength: 6) }
                Link(destination: ContinueLink.url(id: item.id)) {
                    HStack(spacing: 10) {
                        Picture(image: item.picture.flatMap { pictures[$0] })
                            .frame(width: 64, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(WidgetTheme.hairline))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(item.line ?? item.remainingText).lineLimit(1)
                                if item.line != nil {
                                    Spacer(minLength: 4)
                                    Text(item.remainingText).monospacedDigit().lineLimit(1).fixedSize()
                                }
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                            ProgressBar(progress: item.progress, track: WidgetTheme.fill, fill: WidgetTheme.accent)
                        }
                    }
                }
            }
            if items.count < 3 { Spacer(minLength: 0) }
        }
        .foregroundStyle(WidgetTheme.text)
        .containerBackground(WidgetTheme.background, for: .widget)
    }
}

/// The Lock Screen: the entry watched last, drawn in the system's tint.
private struct LockScreenRow: View {
    let item: ContinueSnapshot.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title).font(.headline).lineLimit(1).widgetAccentable()
            Text(item.line ?? item.remainingText).font(.caption).lineLimit(1)
            ProgressBar(progress: item.progress, track: .primary.opacity(0.25), fill: .primary).padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(ContinueLink.url(id: item.id))
    }
}

private struct Message: View {
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

/// The saved picture, or the brand's graphite gradient when there is none
/// (Home's cards draw generated art; a widget can't vary it per launch).
private struct Picture: View {
    let image: UIImage?

    var body: some View {
        if let image {
            Color.clear.overlay { Image(uiImage: image).resizable().scaledToFill() }.clipped()
        } else {
            ZStack {
                LinearGradient(colors: [Color(hex: 0x3A3733), Color(hex: 0x141312)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "film").font(.system(size: 18, weight: .light)).foregroundStyle(.white.opacity(0.25))
            }
        }
    }
}

private struct ProgressBar: View {
    let progress: Double
    let track: Color
    let fill: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(fill).frame(width: max(3, g.size.width * min(1, max(0, progress))))
            }
        }
        .frame(height: 3)
    }
}

// MARK: - Palette

/// Theme's colours (App/Sources/Util/Theme.swift), the ones the widget
/// uses. Copied, not shared: Theme.swift also holds app-only code (settings,
/// windows) that an extension can't build.
enum WidgetTheme {
    static let accent = Color(light: 0x1B1A18, dark: 0xEEE9E1)
    static let text = Color(light: 0x1B1A18, dark: 0xEEE9E1)
    static let background = Color(light: 0xF1EDE6, dark: 0x121110)
    static let fill = Color(light: 0x1B1A18, dark: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.11)
    static let hairline = Color(light: 0x1B1A18, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.09)
}

private extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

private extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }

    init(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) {
        let l = UIColor(hex: light, alpha: lightAlpha), d = UIColor(hex: dark, alpha: darkAlpha)
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? d : l })
    }
}
