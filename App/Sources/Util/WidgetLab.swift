import SwiftUI
import UIKit
import WidgetKit

/// `-labWidgets` (1.24.0): draws every widget, in every look, into PNG files
/// in Documents/LabWidgets, from what the app has written for the widgets
/// (with `-shots`: the screenshot seed's library and Continue Watching),
/// else the widgets' samples. A check of the layouts without a Home Screen.
///
/// Light and Dark are drawn as the widget is. Clear and Tinted are close
/// stand-ins only: iOS draws those itself (the accented rendering mode,
/// colouring by alpha), so here the widget is drawn in that mode, made grey
/// (Clear) or grey times a tint (Tinted), over a glass card on a wallpaper.
@MainActor
enum WidgetLab {
    static var on: Bool { CommandLine.arguments.contains("-labWidgets") }

    enum Look: String, CaseIterable { case light, dark, clear, tinted }

    static func start() {
        guard on else { return }
        // After the writers have run (the first snapshot comes 1.5 s after launch, its pictures after).
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { render() }
    }

    // A Pro Max's widgets on iOS 27 (measured from the user's screenshot, 1.28.4).
    static let small = CGSize(width: 176.67, height: 176.67)
    static let medium = CGSize(width: 378.67, height: 176.67)
    static let large = CGSize(width: 378.67, height: 394.33)

    static func render() {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let out = docs.appendingPathComponent("LabWidgets", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let cont = continueEntry()
        let air = airingEntry()
        let glance = glanceEntry()
        var tiles: [(String, CGSize, AnyView, Bool)] = [
            ("cw-small-hero", small, AnyView(ContinueWidgetView(entry: cont, family: .systemSmall)), false),
            ("cw-small-ring", small, AnyView(ContinueWidgetView(entry: cont, family: .systemSmall, style: .ring)), false),
            ("cw-medium-hero", medium, AnyView(ContinueWidgetView(entry: cont, family: .systemMedium)), false),
            ("cw-medium-episode", medium, AnyView(ContinueWidgetView(entry: cont, family: .systemMedium, style: .episode)), false),
            ("cw-large-hero", large, AnyView(ContinueWidgetView(entry: cont, family: .systemLarge)), false),
            ("cw-large-shelf", large, AnyView(ContinueWidgetView(entry: cont, family: .systemLarge, style: .shelf)), false),
            ("air-small-countdown", small, AnyView(AiringWidgetView(entry: air, family: .systemSmall)), false),
            ("air-small-day", small, AnyView(AiringWidgetView(entry: air, family: .systemSmall, style: .day)), false),
            ("air-medium-week", medium, AnyView(AiringWidgetView(entry: air, family: .systemMedium)), false),
            ("air-medium-outnow", medium, AnyView(AiringWidgetView(entry: air, family: .systemMedium, style: .outNow)), false),
            ("air-large-agenda", large, AnyView(AiringWidgetView(entry: air, family: .systemLarge)), false),
            ("new-small-downloads", small, AnyView(GlanceWidgetView(entry: glance, kind: .downloads)), false),
            ("new-small-week", small, AnyView(GlanceWidgetView(entry: glance, kind: .week)), true),
            ("new-medium-servers", medium, AnyView(GlanceWidgetView(entry: glance, kind: .servers)), false),
            ("new-medium-pick", medium, AnyView(GlanceWidgetView(entry: glance, kind: .pick)), false),
        ]
        // Empty and error states.
        tiles += [
            ("state-cw-empty", small, AnyView(ContinueWidgetView(entry: ContinueEntry(date: Date(), content: .empty), family: .systemSmall)), false),
            ("state-cw-cantshare", medium, AnyView(ContinueWidgetView(entry: ContinueEntry(date: Date(), content: .cantShare), family: .systemMedium)), false),
            ("state-air-nothing", small, AnyView(AiringWidgetView(entry: AiringEntry(date: Date(), content: .snapshot(AiringSnapshot(items: []))), family: .systemSmall)), false),
        ]
        var count = 0
        for look in Look.allCases {
            for (name, size, view, inverted) in tiles {
                if write(framed(view, size: size, look: look, inverted: inverted), to: out.appendingPathComponent("\(name)-\(look.rawValue).png")) { count += 1 }
            }
        }
        // The Lock Screen's, on a dark wallpaper as iOS draws them (vibrant).
        let lock: [(String, CGSize, AnyView)] = [
            ("lock-cw-rect", CGSize(width: 172, height: 76), AnyView(ContinueWidgetView(entry: cont, family: .accessoryRectangular))),
            ("lock-cw-circle", CGSize(width: 76, height: 76), AnyView(ContinueWidgetView(entry: cont, family: .accessoryCircular))),
            ("lock-cw-inline", CGSize(width: 260, height: 22), AnyView(ContinueWidgetView(entry: cont, family: .accessoryInline))),
            ("lock-air-rect", CGSize(width: 172, height: 76), AnyView(AiringWidgetView(entry: air, family: .accessoryRectangular))),
            ("lock-air-circle", CGSize(width: 76, height: 76), AnyView(AiringWidgetView(entry: air, family: .accessoryCircular))),
            ("lock-air-inline", CGSize(width: 260, height: 22), AnyView(AiringWidgetView(entry: air, family: .accessoryInline))),
        ]
        for (name, size, view) in lock {
            let v = view.environment(\.colorScheme, .dark).environment(\.widgetRenderingMode, .vibrant)
                .foregroundStyle(.white).frame(width: size.width, height: size.height)
                .padding(10).background(Color(hex: 0x2A2F3A))
            if write(v, to: out.appendingPathComponent("\(name).png")) { count += 1 }
        }
        dlog("lab", "widgets: \(count) pictures in Documents/LabWidgets (Continue Watching: \(cont.hasItems ? "the app's snapshot" : "sample"), \(glance.downloads == nil ? "no" : "with") downloads file)")
    }

    private static func framed(_ view: AnyView, size: CGSize, look: Look, inverted: Bool) -> some View {
        let scheme: ColorScheme = look == .dark ? .dark : .light
        let mode: WidgetRenderingMode = look == .clear || look == .tinted ? .accented : .fullColor
        let tint = WidgetPalette.tint
        // In the app a container background isn't drawn: widgetLab puts the
        // look's backdrop behind the content instead (1.24.1).
        let content = view
            .environment(\.colorScheme, scheme)
            .environment(\.widgetRenderingMode, mode)
            .environment(\.widgetLab, true)
            .frame(width: size.width, height: size.height)
        let card = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return ZStack {
            switch look {
            case .light, .dark:
                content.clipShape(card)
            case .clear:
                // iOS's glass, roughly; artwork keeps its colours (full colour), text is white.
                card.fill(.white.opacity(0.14)).overlay(card.strokeBorder(.white.opacity(0.32)))
                content.clipShape(card)
            case .tinted:
                card.fill(tint.opacity(0.16)).overlay(card.strokeBorder(tint.opacity(0.35)))
                content.clipShape(card)
            }
        }
        .frame(width: size.width, height: size.height)
        .padding(18)
        .background(wallpaper(look))
    }

    @ViewBuilder
    private static func wallpaper(_ look: Look) -> some View {
        switch look {
        case .light: LinearGradient(colors: [Color(hex: 0xDCE6F0), Color(hex: 0xF4EEE6)], startPoint: .top, endPoint: .bottom)
        case .dark: Color(hex: 0x0B0A09)
        case .clear: LinearGradient(colors: [Color(hex: 0x8C6B4A), Color(hex: 0x3E3127), Color(hex: 0x2F4A55)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .tinted: LinearGradient(colors: [Color(hex: 0x22344A), Color(hex: 0x141D26)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private static func write(_ view: some View, to url: URL) -> Bool {
        let r = ImageRenderer(content: view)
        r.scale = 3
        guard let data = r.uiImage?.pngData() else { return false }
        return (try? data.write(to: url)) != nil
    }

    // MARK: What the widgets would read

    /// `-labArt` (1.28.4): the samples with real pictures, Documents/lab-art-1…4.jpg,
    /// to judge the frosted glass (the samples have none, so it fell back to neutral).
    private static let labArt: [UIImage] = {
        guard CommandLine.arguments.contains("-labArt"),
              let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return [] }
        return (1...4).compactMap { UIImage(contentsOfFile: docs.appendingPathComponent("lab-art-\($0).jpg").path) }
    }()

    private static func artName(_ i: Int) -> String { "lab-art-\(i % max(1, labArt.count))" }
    private static var artPictures: [String: UIImage] {
        Dictionary(uniqueKeysWithValues: labArt.enumerated().map { ("lab-art-\($0.offset)", $0.element) })
    }

    private static func continueEntry() -> ContinueEntry {
        let dir = WidgetStore.continueWatching()
        guard let snap = ContinueSnapshot.read(from: dir), !snap.items.isEmpty else {
            guard !labArt.isEmpty, case .items(var items) = ContinueEntry.sample.content else { return .sample }
            for i in items.indices { items[i].picture = artName(i) }
            return ContinueEntry(date: Date(), content: .items(items), pictures: artPictures)
        }
        var pictures: [String: UIImage] = [:]
        for name in snap.items.flatMap({ [$0.picture, $0.poster] }).compactMap({ $0 }) {
            if let d = dir?.read(name), let img = UIImage(data: d) { pictures[name] = img }
        }
        return ContinueEntry(date: Date(), content: .items(snap.items), pictures: pictures)
    }

    private static func airingEntry() -> AiringEntry {
        let dir = WidgetStore.airing()
        guard let snap = AiringSnapshot.read(from: dir), !snap.items.isEmpty else {
            let sample = AiringEntry.sample()
            guard !labArt.isEmpty, case .snapshot(var s) = sample.content else { return sample }
            for i in s.items.indices { s.items[i].picture = artName(i + 1) }
            return AiringEntry(date: sample.date, content: .snapshot(s), pictures: artPictures)
        }
        var pictures: [String: UIImage] = [:]
        for name in snap.items.compactMap(\.picture) + (snap.recent ?? []).compactMap(\.picture) {
            if let d = dir?.read(name), let img = UIImage(data: d) { pictures[name] = img }
        }
        return AiringEntry(date: Date(), content: .snapshot(snap), pictures: pictures)
    }

    private static func glanceEntry() -> GlanceEntry {
        let store = WidgetStore.glance()
        var e = GlanceEntry.sample()
        if let d = DownloadsGlance.read(from: store) { e.downloads = d }
        if let w = WeekGlance.read(from: store), w.seconds > 0 { e.week = w }
        if let s = ServersGlance.read(from: store) { e.servers = s }
        if let p = PicksGlance.read(from: store), !p.picks.isEmpty { e.picks = p }
        if !labArt.isEmpty {
            for (i, r) in (e.servers?.releases ?? []).enumerated() { e.pictures[ServersTile.pictureName(r)] = labArt[(i + 2) % labArt.count] }
        }
        var names = (e.servers?.releases ?? []).map(ServersTile.pictureName)
        names += (e.picks?.picks ?? []).compactMap(\.picture)
        for n in names { if let d = store?.read(n), let img = UIImage(data: d) { e.pictures[n] = img } }
        return e
    }
}
