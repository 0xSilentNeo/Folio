import Foundation
import Network

/// "Download next episodes" (Settings → Downloads, 1.22.0): when you've
/// watched most of an episode from a WebDAV server (streamed, or a file
/// Folio downloaded from one), the next episodes in its folder are queued,
/// on Wi-Fi only. The usual rules still hold: Low Power Mode and "Only
/// while charging" hold the queue (DownloadManager.pump).
///
/// WebDAV only: SMB, Jellyfin and Plex have no downloads in Folio (only
/// WebDAV folders and addon streams do), and an addon stream's next
/// episode has no link until it's searched for.
@MainActor
enum AutoDownload {
    /// How much of an episode the player waits for before calling `watched`.
    static let threshold = 0.7

    /// Files already handled in this run: the player may call again (a seek
    /// back and forth over 70%).
    private static var handled = Set<String>()
    /// Asked for off Wi-Fi: queued when Wi-Fi is back (in this run).
    private static var waiting: [(server: WebDAVServer, file: URL, count: Int)] = []

    /// The player: `item` is past `threshold` (0...1).
    static func watched(item: MediaItem, progress: Double) {
        let count = UserDefaults.standard.integer(forKey: SettingsKey.downloadNextEpisodes)
        guard count > 0, progress >= threshold, let from = origin(of: item) else { return }
        guard handled.insert(from.file.absoluteString).inserted else { return }
        Task { await queueNext(after: from.file, server: from.server, count: count) }
    }

    /// The WebDAV server and file an item comes from: a WebDAV stream, or a
    /// library file downloaded from one (its download is still in the list).
    static func origin(of item: MediaItem) -> (server: WebDAVServer, file: URL)? {
        switch item.source {
        case .webdav(let id):
            guard let server = ServerStore.shared.servers.first(where: { $0.id == id }), let url = URL(string: item.url) else { return nil }
            return (server, url)
        case .local:
            guard let rel = MediaPath.relative(item.historyKey ?? item.url),
                  let d = DownloadManager.shared.items.last(where: { $0.serverID != nil && MediaPath.relative($0.destination.path) == rel }),
                  let server = ServerStore.shared.servers.first(where: { $0.id == d.serverID }) else { return nil }
            return (server, d.url)
        default:
            return nil
        }
    }

    private static func queueNext(after file: URL, server: WebDAVServer, count: Int) async {
        let name = TitleParser.clean(file.lastPathComponent)
        guard await NetworkGate.shared.allowsDownloads() else {
            dlog("downloads", "next episodes after \(name): not on Wi-Fi, waiting for it")
            waiting.removeAll { $0.file == file }
            waiting.append((server, file, count))
            NetworkGate.shared.onWiFi = { AutoDownload.wifiIsBack() }
            return
        }
        let folder = file.deletingLastPathComponent()
        let listing: [DAVItem]
        do {
            listing = try await WebDAVClient(server: server).list(folder)
        } catch {
            dlog("downloads", "next episodes after \(name): couldn't list the folder (\(error.localizedDescription))")
            return
        }
        let next = Self.next(after: file, in: listing, count: count).filter { f in
            // Already in the list (queued, paused, done) or already watched.
            DownloadManager.shared.item(for: f.url) == nil && HistoryStore.shared.entry(forURL: f.url.absoluteString)?.isFinished != true
        }
        guard !next.isEmpty else {
            dlog("downloads", "next episodes after \(name): nothing new to download")
            return
        }
        let subs = listing.filter { s in s.isSubtitle && next.contains { SubtitleMatch.belongs(s.name, to: $0.name) } }
        DownloadManager.shared.enqueue(next + subs, server: server, package: package(for: folder, server: server), auto: true)
        dlog("downloads", "next episodes after \(name): queued \(next.count)")
    }

    private static func wifiIsBack() {
        guard !waiting.isEmpty else { return }
        let list = waiting
        waiting = []
        NetworkGate.shared.onWiFi = nil
        let count = UserDefaults.standard.integer(forKey: SettingsKey.downloadNextEpisodes)
        guard count > 0 else { return }
        for w in list { Task { await queueNext(after: w.file, server: w.server, count: min(count, w.count)) } }
    }

    /// The package the folder's downloads already have (so they land in the
    /// same Media folder), or the one its folder page would give.
    private static func package(for folder: URL, server: WebDAVServer) -> String {
        if let d = DownloadManager.shared.items.last(where: { $0.url.deletingLastPathComponent() == folder }) { return d.package }
        let own = folder.lastPathComponent
        guard folder.path.count > 1, !own.isEmpty, own != "/" else { return server.name }
        let clean = UserDefaults.standard.bool(forKey: SettingsKey.cleanTitles)
        let title = clean ? ReleaseName.folder(own)?.title ?? own : own
        return DownloadManager.packageName(folder: folder, title: title)
    }

    // MARK: Picking

    /// Up to `count` episodes after `file` in its folder's listing, in
    /// episode order (season, then episode, then name). Only the same show
    /// (a folder can hold several) and the same kind (an OVA's numbers are
    /// its own); nothing for a file without an episode number (a film).
    nonisolated static func next(after file: URL, in listing: [DAVItem], count: Int) -> [DAVItem] {
        guard count > 0 else { return [] }
        let name = file.lastPathComponent
        let current = TitleParser.parse(name)
        guard current.episode != nil else { return [] }
        let show = showKey(current.title)
        let episodes = listing.filter { f in
            guard f.isMedia else { return false }
            let p = TitleParser.parse(f.name)
            return p.episode != nil && p.extra == current.extra && showKey(p.title) == show
        }
        .sorted { a, b in
            let pa = TitleParser.parse(a.name), pb = TitleParser.parse(b.name)
            if (pa.season ?? 0) != (pb.season ?? 0) { return (pa.season ?? 0) < (pb.season ?? 0) }
            if (pa.episode ?? 0) != (pb.episode ?? 0) { return (pa.episode ?? 0) < (pb.episode ?? 0) }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        guard let i = episodes.firstIndex(where: { $0.url.standardized == file.standardized || $0.name == name }) else { return [] }
        return Array(episodes[(i + 1)...].prefix(count))
    }

    /// A show's name, compared without case, spaces or punctuation
    /// ("Mob.Land" and "Mob Land" are one show).
    nonisolated static func showKey(_ title: String) -> String {
        String(title.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}

/// Whether the network is Wi-Fi (or wired) that is neither metered (a
/// phone's hotspot, which iOS marks expensive) nor in Low Data Mode
/// (constrained): what "on Wi-Fi only" means for automatic downloads.
final class NetworkGate: @unchecked Sendable {
    static let shared = NetworkGate()

    struct Path: Equatable {
        var satisfied: Bool
        var wifi: Bool
        var expensive: Bool
        var constrained: Bool
    }

    static func allows(_ p: Path) -> Bool { p.satisfied && p.wifi && !p.expensive && !p.constrained }

    /// Called on the main thread when the network becomes one that allows downloads.
    var onWiFi: (@MainActor () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return wifiHandler }
        set { lock.lock(); wifiHandler = newValue; lock.unlock() }
    }

    private let lock = NSLock()
    private var monitor: NWPathMonitor?
    private var latest: Path?
    private var wifiHandler: (@MainActor () -> Void)?

    /// The network now (the monitor's first answer comes a moment after it
    /// starts: up to 2 s); false when it doesn't come.
    func allowsDownloads() async -> Bool {
        startIfNeeded()
        for _ in 0..<20 {
            if let p = read() { return Self.allows(p) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return read().map(Self.allows) ?? false
    }

    private func read() -> Path? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    private func startIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            self?.changed(Path(satisfied: path.status == .satisfied,
                               wifi: path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet),
                               expensive: path.isExpensive, constrained: path.isConstrained))
        }
        m.start(queue: DispatchQueue(label: "folio.network-gate", qos: .utility))
        monitor = m
    }

    private func changed(_ p: Path) {
        lock.lock()
        let was = latest.map(Self.allows) ?? false
        latest = p
        let handler = wifiHandler
        lock.unlock()
        if !was, Self.allows(p), let handler { DispatchQueue.main.async { MainActor.assumeIsolated { handler() } } }
    }
}
