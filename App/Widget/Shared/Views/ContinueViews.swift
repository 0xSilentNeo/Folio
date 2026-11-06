import SwiftUI
import UIKit
import WidgetKit

// Continue Watching's widgets (1.24.0): four styles, each its own widget in
// the gallery — Hero (small, medium with Up next, large with a list), Ring
// (small), Episode (medium: Resume or the next episode) and Shelf (large,
// six posters) — plus the Lock Screen's. Every part that shows an entry is
// its own link: folio://continue?id= resumes it with its queue.

struct ContinueEntry: TimelineEntry {
    enum Content {
        case items([ContinueSnapshot.Item])
        /// The group is there but Continue Watching is empty.
        case empty
        /// The app hasn't written a snapshot yet.
        case openFolio
        /// This install gives the widget no way to read Folio's data: no
        /// App Group, and the app's Keychain group is refused (1.23.0).
        case cantShare
    }
    let date: Date
    let content: Content
    var pictures: [String: UIImage] = [:]

    var hasItems: Bool { if case .items = content { return true } else { return false } }

    func picture(_ name: String?) -> UIImage? { name.flatMap { pictures[$0] } }

    /// The widget gallery's preview before Folio has anything to show.
    static let sample = ContinueEntry(date: Date(), content: .items([
        .init(id: "sample-1", title: "Your show", line: "S1 · E3 · Where you left off", progress: 0.62, remaining: 1080,
              episode: "S1 · E3", episodeTitle: "Where you left off", duration: 2880, next: "E4"),
        .init(id: "sample-2", title: "Another show", line: "E7", progress: 0.61, remaining: 540, episode: "E7", duration: 1380),
        .init(id: "sample-3", title: "A film", line: nil, progress: 0.45, remaining: 4320, duration: 7800, year: "2024"),
        .init(id: "sample-4", title: "One more show", line: "S2 · E5", progress: 0.28, remaining: 1860, episode: "S2 · E5", duration: 2580),
    ]))
}

enum ContinueStyle { case hero, ring, episode, shelf }

/// What a Continue Watching widget shows for its entry and family.
struct ContinueWidgetView: View {
    let entry: ContinueEntry
    let family: WidgetFamily
    var style: ContinueStyle = .hero

    var body: some View {
        switch entry.content {
        case .items(let items):
            switch family {
            case .accessoryRectangular: ContinueLockRect(item: items[0])
            case .accessoryCircular: ContinueLockRing(item: items[0])
            case .accessoryInline: ContinueInline(item: items[0])
            default:
                switch style {
                case .ring: ContinueRingTile(item: items[0])
                case .episode: ContinueEpisodeTile(item: items[0], picture: entry.picture(items[0].picture))
                case .shelf: ContinueShelfTile(items: Array(items.prefix(6)), entry: entry)
                case .hero:
                    switch family {
                    case .systemLarge where items.count > 1: ContinueLargeTile(items: Array(items.prefix(4)), entry: entry)
                    // One title: all of it, not a list with nothing in it (1.24.0).
                    case .systemLarge: ContinueHeroTile(item: items[0], picture: entry.picture(items[0].picture), wide: true)
                    case .systemMedium where items.count > 1: ContinueMediumTile(items: Array(items.prefix(3)), entry: entry)
                    case .systemMedium: ContinueHeroTile(item: items[0], picture: entry.picture(items[0].picture), wide: true)
                    default: ContinueHeroTile(item: items[0], picture: entry.picture(items[0].picture))
                    }
                }
            }
        case .empty:
            switch family {
            case .accessoryInline: Text("Nothing to continue").widgetURL(GlanceLink.home)
            case .accessoryRectangular, .accessoryCircular: ContinueLockMessage(text: "Nothing to continue")
            default: WidgetMessage(icon: "play.rectangle", title: "Nothing to continue", detail: "What you start in Folio shows up here.",
                                   action: "Browse", url: GlanceLink.home)
            }
        case .openFolio:
            switch family {
            case .accessoryInline: Text("Open Folio once")
            case .accessoryRectangular, .accessoryCircular: ContinueLockMessage(text: "Open Folio once")
            default: WidgetMessage(icon: "play.rectangle.fill", title: "Open Folio once", detail: "to see what you're watching here.", url: GlanceLink.home)
            }
        case .cantShare:
            switch family {
            case .accessoryInline: Text("Can't reach Folio")
            case .accessoryRectangular, .accessoryCircular: ContinueLockMessage(text: "Can't reach Folio")
            default: WidgetMessage(icon: "lock.rectangle", title: "Can't reach Folio", detail: WidgetAccessText.cantShareDetail)
            }
        }
    }
}

enum WidgetAccessText {
    static let cantShareDetail = "This install's signing doesn't let Folio share with its widgets."
}

// MARK: - Hero

/// One entry over its picture: the small widget (and the medium and large
/// ones when only one thing is in progress). The still, the minutes left, a
/// play button.
struct ContinueHeroTile: View {
    let item: ContinueSnapshot.Item
    let picture: UIImage?
    var wide = false

    var body: some View {
        Looked { t in
            ZStack(alignment: .bottomLeading) {
                WidgetArt(image: picture, seed: item.title)
                WidgetScrim()
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.system(size: wide ? 18 : 15, weight: .bold)).lineLimit(wide ? 1 : 2)
                    Text(item.placeAndRemaining).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    WidgetBar(progress: item.progress, track: .white.opacity(0.3), fill: .white).padding(.top, 5)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.bottom, 13)
            }
            .overlay(alignment: .topTrailing) {
                WidgetPill(text: "", icon: "play.fill", primary: false, height: 30).padding(12)
            }
            .widgetCard(t)
            .widgetURL(ContinueLink.url(id: item.id))
        }
    }
}

/// The last thing you watched, big, and the next two. Each part is its own link.
struct ContinueMediumTile: View {
    let items: [ContinueSnapshot.Item]
    let entry: ContinueEntry

    var body: some View {
        Looked { t in
            HStack(spacing: 12) {
                Link(destination: ContinueLink.url(id: items[0].id)) {
                    ZStack(alignment: .bottomLeading) {
                        WidgetArt(image: entry.picture(items[0].picture), seed: items[0].title)
                        WidgetScrim()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(items[0].title).font(.system(size: 14, weight: .bold)).lineLimit(2)
                            Text(items[0].placeAndRemaining).font(.system(size: 10)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                            WidgetBar(progress: items[0].progress, track: .white.opacity(0.3), fill: .white).padding(.top, 4)
                        }
                        .foregroundStyle(.white)
                        .padding(10)
                    }
                    .frame(width: 152, height: 152)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        WidgetLeaf().fill(t.sub).frame(width: 12, height: 12)
                        Text("UP NEXT").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(t.sub)
                    }
                    .widgetAccentable()
                    Spacer(minLength: 6)
                    ForEach(Array(items.dropFirst().enumerated()), id: \.element.id) { i, it in
                        if i > 0 { Spacer(minLength: 6) }
                        Link(destination: ContinueLink.url(id: it.id)) {
                            HStack(spacing: 8) {
                                WidgetThumb(image: entry.picture(it.picture), seed: it.title).frame(width: 52, height: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(it.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(t.ink).lineLimit(1)
                                    Text(it.placeAndRemaining).font(.system(size: 10)).foregroundStyle(t.sub).lineLimit(1)
                                    WidgetBar(progress: it.progress, track: t.track, fill: t.ink, height: 2).padding(.top, 3)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 6).padding(.bottom, 4).padding(.trailing, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .widgetCard(t)
        }
    }
}

/// The hero over the top half, then three more: films show their time
/// left, episodes their place.
struct ContinueLargeTile: View {
    let items: [ContinueSnapshot.Item]
    let entry: ContinueEntry

    var body: some View {
        Looked { t in
            VStack(spacing: 0) {
                Link(destination: ContinueLink.url(id: items[0].id)) {
                    ZStack(alignment: .bottomLeading) {
                        WidgetArt(image: entry.picture(items[0].picture), seed: items[0].title)
                        WidgetScrim()
                        HStack(alignment: .bottom, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(items[0].title).font(.system(size: 18, weight: .heavy)).lineLimit(1)
                                Text(([items[0].episode, items[0].episodeTitle].compactMap { $0 } + [items[0].remainingText]).joined(separator: " · "))
                                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                                WidgetBar(progress: items[0].progress, track: .white.opacity(0.3), fill: .white).padding(.top, 5)
                            }
                            WidgetPill(text: "", icon: "play.fill", height: 40)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.bottom, 14)
                    }
                    .frame(height: 196)
                    .clipped()
                }
                VStack(spacing: 0) {
                    ForEach(Array(items.dropFirst().enumerated()), id: \.element.id) { i, it in
                        if i > 0 { Spacer(minLength: 4) }
                        Link(destination: ContinueLink.url(id: it.id)) {
                            HStack(spacing: 10) {
                                WidgetThumb(image: entry.picture(it.picture), seed: it.title, radius: 8).frame(width: 70, height: 40)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(it.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(t.ink).lineLimit(1)
                                    Text(Self.line(it)).font(.system(size: 11)).foregroundStyle(t.sub).lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                Text(it.shortRemaining).font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(t.sub)
                            }
                        }
                    }
                    if items.count < 4 { Spacer(minLength: 0) }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxHeight: .infinity)
            }
            .widgetCard(t)
        }
    }

    /// "E7 · The Lantern Festival", "Film · 2024".
    static func line(_ it: ContinueSnapshot.Item) -> String {
        if let ep = it.episode { return ([ep] + [it.episodeTitle].compactMap { $0 }).joined(separator: " · ") }
        return (["Film"] + [it.year].compactMap { $0 }).joined(separator: " · ")
    }
}

// MARK: - Ring

/// No artwork needed: the progress ring and the episode's name.
struct ContinueRingTile: View {
    let item: ContinueSnapshot.Item

    var body: some View {
        Looked { t in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    WidgetLeaf().fill(t.ink).frame(width: 16, height: 16).widgetAccentable()
                    Spacer()
                    Text(item.episode ?? "Film").font(.system(size: 11, weight: .semibold)).foregroundStyle(t.sub)
                }
                Spacer(minLength: 4)
                HStack(spacing: 12) {
                    ZStack {
                        WidgetRing(progress: item.progress, track: t.track, fill: t.ink).widgetAccentable()
                        Text(item.shortRemaining).font(.system(size: 13, weight: .heavy)).monospacedDigit().foregroundStyle(t.ink)
                            .minimumScaleFactor(0.7).padding(.horizontal, 7)
                    }
                    .frame(width: 58, height: 58)
                    if let d = item.duration, d > 0 {
                        Text("left of\n\(ContinueRingTile.minutes(d))").font(.system(size: 12)).foregroundStyle(t.sub).lineSpacing(1)
                    } else {
                        Text("left").font(.system(size: 12)).foregroundStyle(t.sub)
                    }
                }
                Spacer(minLength: 4)
                Text(item.title).font(.system(size: 15, weight: .bold)).foregroundStyle(t.ink).lineLimit(1)
                Text(item.episodeTitle ?? item.year ?? item.remainingText).font(.system(size: 11)).foregroundStyle(t.sub).lineLimit(1).padding(.top, 2)
            }
            .padding(14)
            .widgetCard(t)
            .widgetURL(ContinueLink.url(id: item.id))
        }
    }

    /// "23 min", "1 h 48".
    static func minutes(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : String(format: "%d h %02d", m / 60, m % 60)
    }
}

// MARK: - Episode

/// One show, wide: Resume, or straight to the next episode.
struct ContinueEpisodeTile: View {
    let item: ContinueSnapshot.Item
    let picture: UIImage?

    var body: some View {
        Looked { t in
            ZStack(alignment: .leading) {
                WidgetArt(image: picture, seed: item.title)
                WidgetScrim(leading: true)
                VStack(alignment: .leading, spacing: 0) {
                    Text("CONTINUE · " + (item.episode ?? "FILM")).font(.system(size: 10, weight: .bold)).tracking(0.8)
                        .foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    Text(item.title).font(.system(size: 18, weight: .heavy)).lineLimit(2).padding(.top, 4)
                    if let sub = item.episodeTitle ?? item.year {
                        Text(sub).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8)).lineLimit(1).padding(.top, 3)
                    }
                    Spacer(minLength: 6)
                    HStack(spacing: 8) {
                        Link(destination: ContinueLink.url(id: item.id)) {
                            WidgetPill(text: "Resume · " + Self.left(item), icon: "play.fill")
                        }
                        if let next = item.next {
                            Link(destination: ContinueLink.nextURL(id: item.id)) {
                                WidgetPill(text: next, primary: false, font: .system(size: 12, weight: .semibold))
                            }
                        }
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: 240, maxHeight: .infinity, alignment: .leading)
                .padding(.leading, 16).padding(.top, 16).padding(.bottom, 14)
            }
            .widgetCard(t)
            .widgetURL(ContinueLink.url(id: item.id))
        }
    }

    /// "31 min", "1 h 12".
    static func left(_ it: ContinueSnapshot.Item) -> String {
        let m = Int((it.remaining / 60).rounded(.up))
        if m < 60 { return "\(max(1, m)) min" }
        return m % 60 == 0 ? "\(m / 60) h" : String(format: "%d h %02d", m / 60, m % 60)
    }
}

// MARK: - Shelf

/// Six posters with their progress, like Home's grid.
struct ContinueShelfTile: View {
    let items: [ContinueSnapshot.Item]
    let entry: ContinueEntry

    var body: some View {
        Looked { t in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    HStack(spacing: 6) {
                        WidgetLeaf().fill(t.ink).frame(width: 14, height: 14)
                        Text("Continue").font(.system(size: 13, weight: .heavy))
                    }
                    .foregroundStyle(t.ink)
                    .widgetAccentable()
                    Spacer()
                    Text("\(items.count) in progress").font(.system(size: 11)).foregroundStyle(t.sub)
                }
                if items.count > 3 {
                    Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                        ForEach(0..<2, id: \.self) { row in
                            GridRow {
                                ForEach(0..<3, id: \.self) { col in
                                    let i = row * 3 + col
                                    if i < items.count { poster(items[i], t) } else { Color.clear }
                                }
                            }
                        }
                    }
                } else {
                    // Three or fewer: one row of posters, each with its place
                    // under it, not an empty half.
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(0..<3, id: \.self) { i in
                            if i < items.count { poster(items[i], t, detail: true) } else { Color.clear.frame(maxWidth: .infinity) }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(14)
            .widgetCard(t)
        }
    }

    private func poster(_ it: ContinueSnapshot.Item, _ t: WidgetPalette, detail: Bool = false) -> some View {
        Link(destination: ContinueLink.url(id: it.id)) {
            VStack(alignment: .leading, spacing: 5) {
                ZStack(alignment: .bottom) {
                    WidgetArt(image: entry.picture(it.poster ?? it.picture), seed: it.title, accentedOpacity: 0.5)
                    WidgetBar(progress: it.progress, track: .white.opacity(0.3), fill: .white).padding(6)
                }
                .aspectRatio(detail ? 2.0 / 3.0 : nil, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(it.title).font(.system(size: detail ? 12 : 10, weight: .semibold)).foregroundStyle(t.ink).lineLimit(1)
                if detail {
                    Text(it.episode.map { $0 + " · " + it.shortRemaining + " left" } ?? it.remainingText)
                        .font(.system(size: 10)).foregroundStyle(t.sub).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Lock Screen

struct ContinueLockRect: View {
    let item: ContinueSnapshot.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title).font(.headline).lineLimit(1).widgetAccentable()
            Text(item.placeAndRemaining).font(.caption).lineLimit(1)
            WidgetBar(progress: item.progress, track: .primary.opacity(0.25), fill: .primary, height: 4).padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(ContinueLink.url(id: item.id))
    }
}

/// The minutes left in a ring.
struct ContinueLockRing: View {
    let item: ContinueSnapshot.Item

    var body: some View {
        let m = Int((item.remaining / 60).rounded(.up))
        Gauge(value: min(1, max(0, item.progress))) {
            Text("Left")
        } currentValueLabel: {
            VStack(spacing: -1) {
                Text(m < 100 ? "\(max(1, m))" : "\(m / 60)h").font(.system(size: 17, weight: .heavy)).monospacedDigit()
                Text(m < 100 ? "MIN" : "LEFT").font(.system(size: 8, weight: .bold))
            }
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(ContinueLink.url(id: item.id))
        .accessibilityLabel("\(item.title), \(item.remainingText)")
    }
}

struct ContinueInline: View {
    let item: ContinueSnapshot.Item

    var body: some View {
        Label("\(item.title) · \(item.remainingText)", systemImage: "play.fill")
            .containerBackground(for: .widget) { Color.clear }
            .widgetURL(ContinueLink.url(id: item.id))
    }
}

struct ContinueLockMessage: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label("Folio", systemImage: "play.rectangle").font(.headline).widgetAccentable()
            Text(text).font(.caption).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { Color.clear }
    }
}
