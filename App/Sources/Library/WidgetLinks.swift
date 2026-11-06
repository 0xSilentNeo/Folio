import Combine
import Foundation

// What the 1.24.0 widgets' links do in the app, and what the app works out
// for them: the next episode after a Continue Watching entry, and where an
// aired episode of a tracked show is (the library, a server's library).

// MARK: - The next episode

enum NextUp {
    /// The episode after `e`, as the Episode widget's button says it: "E6"
    /// in the same season, "S3 · E1" in the next. Nil when Folio can't tell
    /// without asking a server: library files and the saved library of a
    /// WebDAV server only; nothing for a film or the last episode.
    @MainActor
    static func label(for e: HistoryEntry) async -> String? {
        let item = e.item
        let name = item.fileName
        let p = TitleParser.parse(name)
        guard p.episode != nil else { return nil }
        switch item.source {
        case .local:
            let files = await ContinueQueue.libraryFiles()
            let path = (item.resolvedURL ?? URL(fileURLWithPath: item.historyKey ?? item.url)).standardizedFileURL.path
            guard let file = files.first(where: { $0.standardizedFileURL.path == path }),
                  let group = LibraryOrganizer.groups(files).first(where: { $0.files.contains(file) }), group.isSeries else { return nil }
            let list = group.files.sorted(by: LibraryOrganizer.episodeOrder)
            guard let i = list.firstIndex(of: file), i + 1 < list.count else { return nil }
            return label(TitleParser.parse(list[i + 1].lastPathComponent), after: p)
        case .webdav(let id):
            guard let server = ServerStore.shared.servers.first(where: { $0.id == id }), let url = URL(string: item.url) else { return nil }
            await LibraryIndexStore.shared.load(server)
            guard let files = LibraryIndexStore.shared.state(id).index?.allFiles,
                  let next = NextEpisodes.after(name, url: url, in: files, limit: 1).first else { return nil }
            return label(TitleParser.parse(next.name), after: p)
        default:
            return nil
        }
    }

    static func label(_ n: TitleParser.Parsed, after p: TitleParser.Parsed) -> String? {
        guard let ep = n.episode else { return nil }
        if let s = n.season, s != (p.season ?? s) { return "S\(s) · E\(ep)" }
        return "E\(ep)"
    }
}

extension ContinueQueue {
    /// The episode after `item`, from its queue (the Episode widget's second
    /// button, 1.24.0). Nothing after it: `item` itself, from its place.
    @MainActor
    static func playNext(_ item: MediaItem) {
        Task { @MainActor in
            let (queue, index) = await build(item)
            if index + 1 < queue.count {
                dlog("player", "widget: the episode after \(TitleParser.clean(item.fileName)) (\(index + 2) of \(queue.count))")
                PlayerPresenter.play(queue: queue, index: index + 1)
            } else {
                dlog("player", "widget: nothing after \(TitleParser.clean(item.fileName)) in its queue; resuming it")
                PlayerPresenter.play(queue: queue, index: index)
            }
        }
    }
}

// MARK: - Aired episodes

/// Where an episode of a tracked show is: a library file, or a file in a
/// server's saved library (no network). By its show's name (or other
/// names) and its season and number, as the files are named.
enum EpisodeFinder {
    struct Found {
        var item: MediaItem
        /// "in your library", "on Real-Debrid".
        var place: String
    }

    @MainActor
    static func find(_ show: TrackedShow, season: Int?, episode: Int, libraryFiles: [URL]) -> Found? {
        let keys = Set(([show.name] + (show.otherNames ?? [])).map(NextEpisodes.showKey).filter { !$0.isEmpty })
        func matches(_ name: String) -> Bool {
            let p = TitleParser.parse(name)
            guard p.episode == episode, keys.contains(NextEpisodes.showKey(p.title)) else { return false }
            if let season, let s = p.season { return s == season }
            return true
        }
        if let f = libraryFiles.first(where: { matches($0.lastPathComponent) }) {
            return Found(item: HistoryStore.shared.entry(forURL: f.path)?.item ?? HistoryStore.libraryItem(f.path), place: "in your library")
        }
        for server in ServerStore.shared.servers {
            guard let files = LibraryIndexStore.shared.state(server.id).index?.allFiles,
                  let f = files.first(where: { matches($0.name) }) else { continue }
            var item = MediaItem(url: f.url.absoluteString, title: TitleParser.clean(f.name), source: .webdav(serverID: server.id))
            if let h = HistoryStore.shared.entry(forURL: f.url.absoluteString) { item = h.item }
            return Found(item: item, place: "on " + server.name)
        }
        return nil
    }

    /// folio://aired?id=&s=&e=: found now, played with its queue; not found
    /// (moved, deleted since): the show's tracking page.
    @MainActor
    static func open(_ url: URL) {
        guard let id = GlanceLink.value("id", in: url), let e = GlanceLink.value("e", in: url).flatMap(Int.init) else { return }
        let s = GlanceLink.value("s", in: url).flatMap(Int.init)
        Task { @MainActor in
            await TrackingStore.shared.whenLoaded()
            for server in ServerStore.shared.servers { await LibraryIndexStore.shared.load(server) }
            guard let show = TrackingStore.shared.show(id: id),
                  let found = find(show, season: s, episode: e, libraryFiles: await ContinueQueue.libraryFiles()) else {
                dlog("open", "widget: that episode isn't in the library or a server's library now; opening the show")
                TrackingPresenter.open(id)
                return
            }
            dlog("open", "widget: playing \(show.name) E\(e), \(found.place)")
            ContinueQueue.play(found.item)
        }
    }
}

// MARK: - Library files and server folders

enum WidgetOpen {
    /// folio://library?file=<place in Media>: the Pick for tonight widget's Play.
    @MainActor
    static func libraryFile(_ url: URL) {
        guard let rel = GlanceLink.value("file", in: url), !rel.isEmpty, !rel.contains("..") else { return }
        let path = MPVFiles.mediaDir.appendingPathComponent(rel).path
        guard FileManager.default.fileExists(atPath: path) else {
            dlog("open", "widget: that library file isn't there any more")
            return
        }
        ContinueQueue.play(HistoryStore.shared.entry(forURL: path)?.item ?? HistoryStore.libraryItem(path))
    }

    /// folio://release?server=<id>[&name=<folder>]: a release's folder, or
    /// the server's library, on Home.
    @MainActor
    static func release(_ url: URL) {
        guard let server = GlanceLink.value("server", in: url), let id = UUID(uuidString: server),
              ServerStore.shared.servers.contains(where: { $0.id == id }) else { return }
        let name = GlanceLink.value("name", in: url)
        let release = name.flatMap { n in IndexSummaries.shared.all[id]?.releases?.first { $0.name == n } }
        HomeRouter.shared.open(release.map { LibraryRoute.webdavFolder(server, $0.url, $0.name) } ?? LibraryRoute.webdav(server))
    }
}

/// A screen for Home to open, from outside it (a widget's link).
@MainActor
final class HomeRouter: ObservableObject {
    static let shared = HomeRouter()
    let routes = PassthroughSubject<LibraryRoute, Never>()
    /// Asks the app to show Home first.
    let showHome = PassthroughSubject<Void, Never>()

    /// A route Home hasn't taken yet: opened from a widget while Folio was
    /// still starting, before Home was there to receive it.
    private(set) var pending: LibraryRoute?

    func open(_ route: LibraryRoute) {
        pending = route
        showHome.send()
        // Home's stack gets it once Home is the tab on screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard let r = self.pending else { return }
            self.routes.send(r)
        }
    }

    /// Home takes the waiting route (when it appears, or when it's sent).
    func take() -> LibraryRoute? {
        defer { pending = nil }
        return pending
    }
}
