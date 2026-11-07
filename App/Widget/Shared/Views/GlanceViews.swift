import AppIntents
import SwiftUI
import UIKit
import WidgetKit

// The 1.24.0 widgets: Downloads, Your week, New on your servers and Pick
// for tonight. Each reads one small file the app writes (GlanceSnapshot).

struct GlanceEntry: TimelineEntry {
    enum Access { case ok, openFolio, cantShare }
    let date: Date
    var access: Access = .ok
    var downloads: DownloadsGlance?
    var week: WeekGlance?
    var servers: ServersGlance?
    var picks: PicksGlance?
    /// Which pick is shown (Shuffle moves it on).
    var pickIndex = 0
    var pictures: [String: UIImage] = [:]

    func picture(_ name: String?) -> UIImage? { name.flatMap { pictures[$0] } }

    static func sample(at now: Date = Date()) -> GlanceEntry {
        var run = DownloadActivityAttributes.ContentState(title: "Your show E4", filesLeft: 2, progress: 0.64, speed: 38_000_000, secondsLeft: 180)
        run.measuredAt = now
        run.finishBy = now.addingTimeInterval(180)
        return GlanceEntry(
            date: now,
            downloads: DownloadsGlance(run: run, network: "Wi-Fi", ready: ["Your show E3"], readyCount: 3, written: now),
            week: WeekGlance(seconds: 15_600, shows: 3, films: 1, episodes: 9, perDay: [3600, 0, 2400, 1800, 4200, 0, 3600], countingSince: nil, day: now),
            servers: ServersGlance(server: "", serverName: "Real-Debrid", thisWeek: 7, releases: [
                .init(folder: "a", title: "A new season S2", detail: "2160p"), .init(folder: "b", title: "A series S1", detail: "1080p"),
                .init(folder: "c", title: "A film", detail: "DV"), .init(folder: "d", title: "An anime", detail: "1080p"),
            ]),
            picks: PicksGlance(picks: [.init(file: "", title: "A film you haven't started", line: "Film · 1 h 48 · in your library")]))
    }
}

enum GlanceKind { case downloads, week, servers, pick }

struct GlanceWidgetView: View {
    let entry: GlanceEntry
    let kind: GlanceKind

    var body: some View {
        switch entry.access {
        case .cantShare:
            WidgetMessage(icon: "lock.rectangle", title: "Can't reach Folio", detail: WidgetAccessText.cantShareDetail)
        case .openFolio:
            WidgetMessage(icon: "arrow.up.forward.app", title: "Open Folio once", detail: "and this widget fills in.", url: GlanceLink.home)
        case .ok:
            switch kind {
            case .downloads: DownloadsTile(glance: entry.downloads, now: entry.date)
            case .week: WeekTile(glance: entry.week, now: entry.date)
            case .servers:
                if let s = entry.servers, !s.releases.isEmpty { ServersTile(glance: s, entry: entry) }
                else { WidgetMessage(icon: "server.rack", title: "No server library yet", detail: "Add a server in Folio and its newest releases show up here.", url: GlanceLink.home) }
            case .pick:
                if let p = entry.picks?.picks, !p.isEmpty { PickTile(pick: p[entry.pickIndex % p.count], entry: entry, count: p.count) }
                else { WidgetMessage(icon: "sparkles", title: "Nothing to pick", detail: "Films and shows in your library you haven't started show up here.", url: GlanceLink.home) }
            }
        }
    }
}

// MARK: - Downloads

/// How far, how fast, how long. Idle: what's ready offline.
struct DownloadsTile: View {
    let glance: DownloadsGlance?
    let now: Date

    var body: some View {
        Looked { t in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 15, weight: .bold)).foregroundStyle(t.ink).widgetAccentable()
                    Spacer(minLength: 4)
                    Text(header).font(.system(size: 11, weight: .semibold)).foregroundStyle(t.sub).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let run = glance?.run, !run.done {
                    ZStack {
                        WidgetRing(progress: run.progress, track: t.track, fill: t.ink, width: 7).widgetAccentable()
                        Text(run.percentText).font(.system(size: 15, weight: .heavy)).monospacedDigit().foregroundStyle(t.ink)
                    }
                    .frame(width: 70, height: 70)
                    Spacer(minLength: 4)
                    Text(run.filesLeft == 1 ? "1 downloading" : "\(run.filesLeft) downloading").font(.system(size: 14, weight: .bold)).foregroundStyle(t.ink)
                    detail(run).font(.system(size: 11)).foregroundStyle(t.sub).lineLimit(1).padding(.top, 2)
                } else {
                    Text("\(glance?.readyCount ?? 0)").font(.system(size: 34, weight: .heavy)).monospacedDigit().foregroundStyle(t.ink)
                    Text(glance?.readyCount == 1 ? "download this week" : "downloads this week").font(.system(size: 11)).foregroundStyle(t.sub)
                    Spacer(minLength: 4)
                    Text(glance == nil ? "Nothing downloading" : "Ready offline").font(.system(size: 14, weight: .bold)).foregroundStyle(t.ink)
                    Text(glance?.ready.first ?? "Download from a server's page.").font(.system(size: 11)).foregroundStyle(t.sub).lineLimit(1).padding(.top, 2)
                }
            }
            .padding(14)
            .widgetCard(t, seed: glance?.run?.title ?? "downloads")
            .widgetURL(GlanceLink.downloads)
        }
    }

    private var header: String {
        guard let run = glance?.run, !run.done else { return "Downloads" }
        if run.waiting { return "Waiting" }
        return ([glance?.network] + [run.speed > 0 ? run.speedText : nil]).compactMap { $0 }.joined(separator: " · ")
    }

    /// "Your show E4 · 3 min left", the time left counting down by itself.
    private func detail(_ run: DownloadActivityAttributes.ContentState) -> Text {
        if let end = run.finishBy, end > now, !run.waiting {
            return Text(run.title + " · ") + Text(end, style: .relative)
        }
        return Text(run.title)
    }
}

// MARK: - Your week

/// From the time watched, kept on the phone. Nothing leaves it.
struct WeekTile: View {
    let glance: WeekGlance?
    let now: Date

    var body: some View {
        Looked { t in
            let ink = t.ink
            VStack(alignment: .leading, spacing: 0) {
                WidgetLeaf().fill(ink).frame(width: 20, height: 20).widgetAccentable()
                Spacer(minLength: 4)
                Text(WeekGlance.duration(glance?.seconds ?? 0)).font(.system(size: 30, weight: .heavy)).tracking(-1).monospacedDigit()
                    .foregroundStyle(ink).lineLimit(1).minimumScaleFactor(0.6)
                Text(since).font(.system(size: 11)).foregroundStyle(ink.opacity(0.75)).padding(.top, 2)
                Spacer(minLength: 4)
                Text(counts).font(.system(size: 11, weight: .semibold)).foregroundStyle(ink.opacity(0.85)).lineLimit(2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetCard(t, seed: "your week")
            .widgetURL(GlanceLink.home)
        }
    }

    private var since: String {
        if let s = glance?.countingSince { return "watched since " + s.formatted(.dateTime.weekday(.wide)) }
        return "watched this week"
    }

    private var counts: String {
        guard let g = glance else { return "Starts counting when you watch" }
        var parts: [String] = []
        if g.shows > 0 { parts.append(g.shows == 1 ? "1 show" : "\(g.shows) shows") }
        if g.films > 0 { parts.append(g.films == 1 ? "1 film" : "\(g.films) films") }
        if g.episodes > 0 { parts.append(g.episodes == 1 ? "1 episode" : "\(g.episodes) episodes") }
        return parts.isEmpty ? "Nothing yet this week" : parts.joined(separator: " · ")
    }
}

// MARK: - New on your servers

/// The newest releases of a server's saved library, with their quality.
struct ServersTile: View {
    let glance: ServersGlance
    let entry: GlanceEntry

    var body: some View {
        Looked { t in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("New on \(glance.serverName)").font(.system(size: 13, weight: .heavy)).foregroundStyle(t.ink).lineLimit(1).widgetAccentable()
                    Spacer(minLength: 6)
                    Text(glance.thisWeek > 0 ? "this week · \(glance.thisWeek)" : "newest").font(.system(size: 11)).foregroundStyle(t.sub)
                }
                HStack(spacing: 9) {
                    ForEach(0..<4, id: \.self) { i in
                        if i < glance.releases.count {
                            let r = glance.releases[i]
                            Link(destination: GlanceLink.release(server: glance.server, folder: r.folder)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    WidgetThumb(image: entry.picture(Self.pictureName(r)), seed: r.title, radius: 9)
                                        .overlay(alignment: .topLeading) {
                                            if let tag = r.detail {
                                                WidgetBadge(fill: .white, ink: Color(hex: 0x141312), radius: 5) {
                                                    Text(tag).font(.system(size: 8, weight: .heavy)).lineLimit(1).padding(.horizontal, 5).padding(.vertical, 2)
                                                }
                                                .fixedSize()
                                                .padding(5)
                                            }
                                        }
                                    Text(r.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(t.ink).lineLimit(1)
                                }
                            }
                        } else {
                            Color.clear
                        }
                    }
                }
            }
            .padding(14)
            .widgetCard(t, art: glance.releases.first.flatMap { entry.picture(Self.pictureName($0)) }, seed: glance.releases.first?.title ?? "")
            .widgetURL(GlanceLink.server(glance.server))
        }
    }

    /// The poster the app saved for a release, by its folder's name.
    static func pictureName(_ r: ServersGlance.Release) -> String { "rel-" + String(UInt32(truncatingIfNeeded: r.folder.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) })) + ".jpg" }
}

// MARK: - Pick for tonight

/// One title you haven't started; Shuffle picks another in place.
struct PickTile: View {
    let pick: PicksGlance.Pick
    let entry: GlanceEntry
    let count: Int

    var body: some View {
        Looked { t in
            ZStack(alignment: .leading) {
                WidgetArt(image: entry.picture(pick.picture), seed: pick.title)
                WidgetScrim(leading: true)
                VStack(alignment: .leading, spacing: 0) {
                    Text("PICK FOR TONIGHT").font(.system(size: 10, weight: .heavy)).tracking(0.8).foregroundStyle(.white.opacity(0.8))
                    Text(pick.title).font(.system(size: 18, weight: .heavy)).lineLimit(2).padding(.top, 4)
                    Text(pick.line).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8)).lineLimit(1).padding(.top, 3)
                    Spacer(minLength: 6)
                    HStack(spacing: 8) {
                        Link(destination: GlanceLink.library(file: pick.file)) { WidgetPill(text: "Play", icon: "play.fill") }
                        if count > 1 {
                            Button(intent: ShufflePickIntent()) { WidgetPill(text: "", icon: "shuffle", primary: false) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Shuffle")
                        }
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: 250, maxHeight: .infinity, alignment: .leading)
                .padding(.leading, 16).padding(.top, 16).padding(.bottom, 14)
            }
            .widgetCard(t, art: entry.picture(pick.picture), seed: pick.title)
            .widgetURL(GlanceLink.library(file: pick.file))
        }
    }
}

/// The Pick for tonight widget's Shuffle: the next pick. Which pick is
/// shown is kept with the widgets' files, so it's the same whichever
/// process iOS runs this in.
struct ShufflePickIntent: AppIntent {
    static let title: LocalizedStringResource = "Shuffle Tonight's Pick"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        PickIndex.advance()
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.pickTonight)
        return .result()
    }
}

enum PickIndex {
    private static let fileName = "pick-index"

    static func current(_ store: WidgetStore? = WidgetStore.glance()) -> Int {
        guard let d = store?.read(fileName), let s = String(data: d, encoding: .utf8), let n = Int(s) else { return 0 }
        return max(0, n)
    }

    static func advance(_ store: WidgetStore? = WidgetStore.glance(create: true)) {
        guard let store else { return }
        try? store.write(Data(String(current(store) + 1).utf8), fileName)
    }
}
