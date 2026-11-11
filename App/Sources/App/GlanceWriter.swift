import Combine
import Network
import UIKit
import WidgetKit

/// Writes the 1.24.0 widgets' files (GlanceSnapshot) into the widgets'
/// store: Downloads, Your week, New on your server and Pick for tonight.
/// Each file is written only when what it says changes, and only its own
/// widget is reloaded then (WidgetKit budgets reloads; while Folio is on
/// screen they're free).
@MainActor
enum GlanceWriter {
    private static var subscriptions: Set<AnyCancellable> = []
    private static var written: [String: Data] = [:]
    private static var lastDownloadsWrite = Date.distantPast
    private static var network: String?
    private static var monitor: NWPathMonitor?

    /// The kids profile went on or off (1.28.6): the widgets that show the
    /// library's and the servers' titles are written for it now.
    static func kidsChanged() {
        writePicks()
        serversSoon()       // ends a write already under way (1.28.10): it could put the titles back
    }

    static func start() {
        guard subscriptions.isEmpty else { return }
        DownloadManager.shared.objectWillChange
            .throttle(for: .seconds(2), scheduler: DispatchQueue.main, latest: true)
            .sink { _ in MainActor.assumeIsolated { writeDownloads() } }
            .store(in: &subscriptions)
        HistoryStore.shared.objectWillChange
            .debounce(for: .seconds(3), scheduler: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { writeWeek(); writePicks() } }
            .store(in: &subscriptions)
        LocalMediaStore.shared.$files
            .debounce(for: .seconds(3), scheduler: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { writePicks() } }
            .store(in: &subscriptions)
        IndexSummaries.shared.$all
            .debounce(for: .seconds(3), scheduler: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { serversSoon() } }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { _ in MainActor.assumeIsolated {
                WatchLog.shared.flush()
                AwayWork.onLeaving("week and downloads widgets") {
                    writeWeek()
                    writeDownloads(force: true)
                }
            } }
            .store(in: &subscriptions)
        let m = NWPathMonitor()
        m.pathUpdateHandler = { path in
            let name: String? = path.status != .satisfied ? nil
                : path.usesInterfaceType(.wifi) ? "Wi-Fi" : path.usesInterfaceType(.wiredEthernet) ? "Ethernet"
                : path.usesInterfaceType(.cellular) ? "Cellular" : nil
            DispatchQueue.main.async { MainActor.assumeIsolated { network = name } }
        }
        m.start(queue: DispatchQueue(label: "folio.glance-network", qos: .utility))
        monitor = m
        writeDownloads(force: true)
        writeWeek()
        writePicks()
        serversSoon()
    }

    private static var serversTask: Task<Void, Never>?

    private static func serversSoon() {
        serversTask?.cancel()
        serversTask = Task { @MainActor in await writeServers() }
    }

    /// The store's reads and writes, one at a time and off the main thread
    /// (1.28.8). On this install the store is the Keychain: every call is a
    /// round trip to another process, and they all ran on the main thread,
    /// at launch and after every change to the history.
    private static let disk = DispatchQueue(label: "folio.glance-store", qos: .utility)
    /// Files compared once with what the last run left.
    private static var compared: Set<String> = []

    /// Writes `file` when it's new or changed, and reloads `kind`.
    private static func write<F: GlanceFile>(_ file: F, kind: String, compare: Data? = nil) -> Bool {
        guard let store = WidgetStore.glance(create: true) else { return false }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        guard let data = try? e.encode(file) else { return false }
        let key = compare ?? data
        if written[F.fileName] == key { return false }
        written[F.fileName] = key
        // The first write of a launch (1.28.8): not when it's what the last
        // run left. Every cold launch wrote every file again and had iOS
        // reload four kinds of widget for nothing.
        let first = compared.insert(F.fileName).inserted && compare == nil
        disk.async {
            if first, F.read(from: store) == file { return }
            do {
                try file.write(to: store)
                WidgetCenter.shared.reloadTimelines(ofKind: kind)
            } catch {
                dlog("widget", "\(F.fileName) not written: \(error.localizedDescription)")
                DispatchQueue.main.async { MainActor.assumeIsolated { if written[F.fileName] == key { written[F.fileName] = nil } } }
            }
        }
        return true
    }

    /// A picture kept for the widgets, encoded and stored off the main thread (1.28.8).
    private static func keep(_ image: UIImage, as name: String, in store: WidgetStore) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            disk.async {
                if let jpeg = image.jpegData(compressionQuality: 0.8) { try? store.write(jpeg, name) }
                done.resume()
            }
        }
    }

    /// Whether the store has `name`, asked off the main thread.
    private static func has(_ name: String, in store: WidgetStore) async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            disk.async { done.resume(returning: store.exists(name)) }
        }
    }

    /// Pictures with `prefix` that are no longer shown, removed off the main thread.
    private static func sweep(_ prefix: String, keeping: Set<String>, in store: WidgetStore) {
        disk.async { for f in store.names() where f.hasPrefix(prefix) && !keeping.contains(f) { store.remove(f) } }
    }

    // MARK: Downloads

    static func writeDownloads(force: Bool = false) {
        let dm = DownloadManager.shared
        let now = Date()
        let active = dm.items.filter { $0.state == .running || $0.state == .queued }
        var run: DownloadActivityAttributes.ContentState?
        if !active.isEmpty {
            let ids = Set(active.map(\.id))
            run = DownloadActivity.state(dm.items, run: ids, speed: dm.estimateSpeed, now: now) { TitleParser.clean($0.fileName) }
        }
        let week = now.addingTimeInterval(-7 * 86400)
        let done = dm.items.filter { $0.state == .done && ($0.finished ?? .distantPast) > week }
            .sorted { ($0.finished ?? .distantPast) > ($1.finished ?? .distantPast) }
        let glance = DownloadsGlance(run: run, network: network, ready: done.prefix(3).map { TitleParser.clean($0.fileName) },
                                     readyCount: done.count, written: now)
        // Written when the files downloading, the title or what's ready
        // change, and a minute on while it runs (the widget's timers carry
        // the time left in between); not on every progress tick.
        let sig = Data("\(run?.filesLeft ?? -1)|\(run?.title ?? "")|\(run?.waiting ?? false)|\(glance.ready)|\(glance.readyCount)".utf8)
        // In the background every five minutes: each reload there comes out
        // of the widget's daily budget.
        let gap: TimeInterval = UIApplication.shared.applicationState == .background ? 300 : 60
        let minuteOn = run != nil && now.timeIntervalSince(lastDownloadsWrite) >= gap
        guard force || minuteOn || written[DownloadsGlance.fileName + "#sig"] != sig else { return }
        if write(glance, kind: WidgetKind.downloads) {
            lastDownloadsWrite = now
            written[DownloadsGlance.fileName + "#sig"] = sig
        }
    }

    // MARK: Your week

    static func writeWeek() {
        let w = WatchLog.shared.week()
        let glance = WeekGlance(seconds: w.seconds.rounded(), shows: w.shows, films: w.films, episodes: w.episodes,
                                perDay: w.perDay.map { ($0 / 60).rounded() * 60 }, countingSince: w.countingSince,
                                day: Calendar.current.startOfDay(for: Date()))
        _ = write(glance, kind: WidgetKind.yourWeek)
    }

    // MARK: New on your server

    static func writeServers() async {
        // Kids profile (1.28.6): nothing from the servers on the widget.
        guard !KidsProfile.isOnNow else {
            _ = write(ServersGlance(server: "", serverName: "", thisWeek: 0, releases: []), kind: WidgetKind.newOnServers)
            return
        }
        let summaries = IndexSummaries.shared.all
        // Real-Debrid first (Home's row), else the server with the newest release.
        let servers = ServerStore.shared.servers.filter { summaries[$0.id]?.releases?.isEmpty == false }
        guard let server = servers.first(where: RealDebrid.isRealDebrid)
                ?? servers.max(by: { (summaries[$0.id]?.releases?.first?.added ?? .distantPast) < (summaries[$1.id]?.releases?.first?.added ?? .distantPast) }),
              let releases = summaries[server.id]?.releases, let store = WidgetStore.glance(create: true) else { return }
        let week = Date().addingTimeInterval(-7 * 86400)
        let newest = releases.sorted { ($0.added ?? .distantPast) > ($1.added ?? .distantPast) }
        let shown: [ServersGlance.Release] = newest.prefix(4).map { r in
            let name = ReleaseName.folder(r.name)
            return ServersGlance.Release(folder: r.name, title: name?.title ?? r.name,
                                         detail: name.flatMap { n in [n.label, n.attribute(.resolution)].compactMap { $0 }.joined(separator: " · ") }.flatMap { $0.isEmpty ? nil : $0 },
                                         added: r.added)
        }
        let glance = ServersGlance(server: server.id.uuidString, serverName: RealDebrid.isRealDebrid(server) ? "Real-Debrid" : server.name,
                                   thisWeek: releases.filter { ($0.added ?? .distantPast) > week }.count, releases: shown)
        // Posters, as Home's row finds them (only with metadata on).
        if UserDefaults.standard.bool(forKey: SettingsKey.metadataFetching) {
            for r in shown {
                let file = ServersTile.pictureName(r)
                if await has(file, in: store) { continue }
                guard let name = ReleaseName.folder(r.folder),
                      let m = await ReleaseMatcher.shared.match(name), m.confident, let poster = m.poster, let url = URL(string: poster),
                      let img = await ImageCache.shared.poster(id: m.imdbID ?? poster, url: url, maxPixel: 240) else { continue }
                await keep(img, as: file, in: store)
            }
        }
        // Not if the kids profile came on, or a newer write began, while the posters were fetched (1.28.10).
        guard !Task.isCancelled, !KidsProfile.isOnNow else { return }
        sweep("rel-", keeping: Set(shown.map(ServersTile.pictureName)), in: store)
        if write(glance, kind: WidgetKind.newOnServers) {
            dlog("widget", "new on \(glance.serverName): \(glance.releases.count) shown, \(glance.thisWeek) this week")
        }
    }

    // MARK: Pick for tonight

    /// Films in the library you haven't started, weighted as Pick something
    /// for me weighs them (newer and better-known first), in a fresh order
    /// each day; Shuffle in the widget moves along it.
    static func writePicks() {
        // Kids profile (1.28.6): no picks, where the grown-ups' stayed on the widget.
        guard !KidsProfile.isOnNow else {
            picturesTask?.cancel()
            _ = write(PicksGlance(picks: []), kind: WidgetKind.pickTonight)
            return
        }
        let files = LocalMediaStore.shared.files
        let history = HistoryStore.shared
        var candidates: [PickForMe.Candidate] = []
        for f in files where LibraryOrganizer.titleKey(f).hasPrefix("f|") {
            let e = history.entry(forURL: f.path)
            guard e == nil || (e?.isFinished != true && e?.canResume != true && e?.watched != true) else { continue }
            let meta = LibraryMetaIndex.shared.meta(for: f)
            candidates.append(PickForMe.Candidate(file: f, added: LibraryOrganizer.info(f).date, hasMeta: meta?.poster != nil || meta?.description != nil))
        }
        // The day's order: the same all day, so Shuffle walks through it.
        var rng = SeededGenerator(seed: UInt64(Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0))
        var order: [PickForMe.Candidate] = []
        var pool = candidates
        while order.count < 8, let c = PickForMe.pick(pool, using: &rng) {
            order.append(c)
            pool.removeAll { $0.file == c.file }
        }
        let base = MPVFiles.mediaDir.standardizedFileURL.path + "/"
        let picks: [PicksGlance.Pick] = order.compactMap { c in
            let path = c.file.standardizedFileURL.path
            guard path.hasPrefix(base) else { return nil }
            let meta = LibraryMetaIndex.shared.meta(for: c.file)
            let p = TitleParser.parse(c.file.lastPathComponent)
            let line = ["Film", meta?.year ?? p.year.map(String.init), "in your library", meta?.rating].compactMap { $0 }.joined(separator: " · ")
            return PicksGlance.Pick(file: String(path.dropFirst(base.count)), title: meta?.name ?? TitleParser.clean(c.file.lastPathComponent), line: line)
        }
        // Written once, with its pictures (1.28.8): it was written without
        // them first and again with them, two writes and two reloads of the
        // widget for every change to the history or the library.
        if picks.isEmpty { _ = write(PicksGlance(picks: []), kind: WidgetKind.pickTonight) }
        let chosen = order.map(\.file)
        picturesTask?.cancel()
        picturesTask = Task { @MainActor in await writePickPictures(picks: picks, metaFiles: chosen) }
    }

    private static var picturesTask: Task<Void, Never>?

    /// The picks' posters (wide art when Folio has it), then the file again
    /// with their names.
    private static func writePickPictures(picks: [PicksGlance.Pick], metaFiles: [URL]) async {
        guard let store = WidgetStore.glance(create: true) else { return }
        var out = picks
        for (i, f) in metaFiles.enumerated() where i < out.count {
            let meta = LibraryMetaIndex.shared.meta(for: f)
            guard let art = meta?.wideArt ?? meta?.poster, let url = URL(string: art) else { out[i].picture = nil; continue }
            let name = "pick-" + stableHash(art) + ".jpg"
            out[i].picture = name
            if await has(name, in: store) { continue }
            guard let img = await ImageCache.shared.image(url, maxPixel: 540) else { out[i].picture = nil; continue }
            await keep(img, as: name, in: store)
        }
        guard !Task.isCancelled else { return }
        sweep("pick-", keeping: Set(out.compactMap(\.picture)), in: store)
        _ = write(PicksGlance(picks: out), kind: WidgetKind.pickTonight)
    }

    private static func stableHash(_ s: String) -> String {
        String(s.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) } & 0xFFFF_FFFF_FFFF, radix: 16)
    }
}

/// A small seeded generator (SplitMix64): the same picks all day.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
