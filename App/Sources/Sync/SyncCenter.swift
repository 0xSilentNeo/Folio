import Foundation
import Combine
import UIKit

/// Sends what you watch to the services you've connected (1.26.0): Trakt
/// gets films and episodes, AniList and MyAnimeList anime episodes. Off
/// until a service is connected and switched on in Settings → Sync. What
/// can't be sent now (offline, a service down) waits in a queue saved to
/// disk and goes on the next try: when the app comes back, or with the next
/// thing you finish. Your watchlist goes to Trakt too.
@MainActor
final class SyncCenter: ObservableObject {
    static let shared = SyncCenter()

    /// Connected services and the account each is signed in as ("" when the name isn't known).
    @Published private(set) var accounts: [SyncService: String] = [:]
    /// The last thing each service did, for Settings ("Sent: Frieren E5 · E5 of 28").
    @Published private(set) var lastResult: [SyncService: String] = [:]
    @Published private(set) var waiting = 0

    private struct Job: Codable, Hashable {
        var service: SyncService
        var event: SyncEvent?
        var watchlist: WatchlistItem?
        var add: Bool?
        var attempts = 0
    }

    private var jobs: [Job] = [] { didSet { waiting = jobs.count } }
    private var flushing = false
    private var bag: Set<AnyCancellable> = []

    private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("sync-queue.json")
    }()

    private init() {
        for s in SyncService.allCases {
            if let t = SyncTokens.load(s) { accounts[s] = t.user ?? "" }
        }
        if let data = try? Data(contentsOf: file) {
            let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
            jobs = (try? d.decode([Job].self, from: data)) ?? []
        }
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.flushSoon() }
            .store(in: &bag)
        WatchlistStore.shared.changes
            .sink { [weak self] change in self?.watchlistChanged(change.item, added: change.added) }
            .store(in: &bag)
    }

    /// Starts the queue (called at launch).
    func start() { flushSoon() }

    func isConnected(_ s: SyncService) -> Bool { accounts[s] != nil }
    func isOn(_ s: SyncService) -> Bool { isConnected(s) && UserDefaults.standard.bool(forKey: s.enabledKey) }
    var anyOn: Bool { SyncService.allCases.contains(where: isOn) }

    func connected(_ s: SyncService, _ t: SyncTokens) {
        t.save(s)
        accounts[s] = t.user ?? ""
        UserDefaults.standard.set(true, forKey: s.enabledKey)
        lastResult[s] = "Connected"
        dlog("sync", "\(s.name): connected\(t.user.map { " as \($0)" } ?? "")")
    }

    func disconnect(_ s: SyncService) {
        SyncTokens.clear(s)
        accounts[s] = nil
        UserDefaults.standard.set(false, forKey: s.enabledKey)
        jobs.removeAll { $0.service == s }
        save()
        lastResult[s] = nil
        dlog("sync", "\(s.name): disconnected")
    }

    // MARK: What happened

    /// Something you finished watching.
    func watched(_ e: SyncEvent) {
        let targets = SyncService.allCases.filter { s in
            guard isOn(s) else { return false }
            return s == .trakt ? e.imdb != nil : e.looksLikeAnime && (e.anime?.episode ?? e.episode) != nil
        }
        guard !targets.isEmpty else { return }
        for s in targets where !jobs.contains(where: { $0.service == s && $0.event?.key == e.key }) {
            jobs.append(Job(service: s, event: e))
        }
        dlog("sync", "finished \(e.label): to \(targets.map(\.name).joined(separator: ", "))")
        save()
        flushSoon()
    }

    private func watchlistChanged(_ item: WatchlistItem, added: Bool) {
        guard isOn(.trakt), item.id.hasPrefix("tt") else { return }
        jobs.removeAll { $0.service == .trakt && $0.watchlist?.id == item.id }    // the latest choice wins
        jobs.append(Job(service: .trakt, watchlist: item, add: added))
        save()
        flushSoon()
    }

    /// Your Trakt watchlist into Folio's (titles already there are kept as they are).
    func importTraktWatchlist() async -> String {
        do {
            let token = try await token(.trakt)
            let metas = try await TraktClient.fetchWatchlist(token: token)
            let before = WatchlistStore.shared.items.count
            WatchlistStore.shared.merge(metas)
            let added = WatchlistStore.shared.items.count - before
            return added == 0 ? "Nothing new on your Trakt watchlist." : "\(added) title\(added == 1 ? "" : "s") added from Trakt."
        } catch {
            return "Couldn't read your Trakt watchlist (\(error.localizedDescription))."
        }
    }

    // MARK: Sending

    private func flushSoon() {
        guard !jobs.isEmpty, !flushing else { return }
        flushing = true
        Task {
            await flush()
            flushing = false
        }
    }

    /// The service is busy or down, or wants a new sign-in: the job is kept
    /// for a later try rather than counted towards being dropped.
    nonisolated static func isTransient(status: Int) -> Bool {
        status == 0 || status == 401 || status == 408 || status == 429 || (500...599).contains(status)
    }

    private func flush() async {
        var i = 0
        // Services that answered "not now" in this pass: their other jobs wait.
        var waiting = Set<SyncService>()
        while i < jobs.count {
            let job = jobs[i]
            guard isOn(job.service) else { jobs.remove(at: i); continue }
            if waiting.contains(job.service) { i += 1; continue }
            do {
                let outcome = try await send(job)
                lastResult[job.service] = outcome
                dlog("sync", "\(job.service.name): \(outcome)")
                jobs.removeAll { $0 == job }
            } catch {
                var j = job
                j.attempts += 1
                let why = (error as? SyncHTTP.Failure).map { "\($0.errorDescription ?? "") \($0.body.prefix(160))" } ?? error.localizedDescription
                dlog("sync/error", "\(job.service.name): \(job.event?.label ?? job.watchlist?.name ?? "?") not sent (\(why)), try \(j.attempts)")
                lastResult[job.service] = "Not sent yet: \(job.event?.label ?? job.watchlist?.name ?? "") (\(error.localizedDescription))"
                // Not reached: this and the rest wait for the next try.
                let status = (error as? SyncHTTP.Failure)?.status
                let unreachable = status == 0
                // Dropped after six refusals of the job itself (1.30.1). An
                // outage or a rate limit counted too, so six tries during one
                // deleted everything queued; those wait now (up to 60 tries,
                // so a job a service will never take doesn't stay for good).
                let transient = status.map(Self.isTransient) ?? false
                if let k = jobs.firstIndex(of: job) {
                    if j.attempts >= (transient ? 60 : 6) { jobs.remove(at: k) } else { jobs[k] = j; i += 1 }
                }
                if unreachable { break }
                if transient { waiting.insert(job.service) }
            }
            save()
        }
        save()
    }

    /// One job. The outcome for Settings and the log.
    private func send(_ job: Job) async throws -> String {
        let s = job.service
        let token = try await token(s)
        if let item = job.watchlist {
            try await TraktClient.watchlist(item, add: job.add ?? true, token: token)
            return "\(job.add == false ? "Removed from" : "Added to") watchlist: \(item.name)"
        }
        guard let e = job.event else { return "Nothing to send" }
        switch s {
        case .trakt:
            return try await TraktClient.addToHistory(e, token: token) ? "Sent: \(e.label)" : "Skipped \(e.label) (no IMDb id)"
        case .anilist, .mal:
            guard let hint = e.anime, let episode = hint.episode ?? e.episode,
                  let ids = await SkipService.shared.animeIDs(hint, season: e.season) else {
                return "Skipped \(e.label) (not found on \(s.name))"
            }
            if s == .anilist {
                guard let id = ids.anilistId else { return "Skipped \(e.label) (no AniList id)" }
                return "Sent: \(e.label) · " + (try await AniListClient.progress(mediaID: id, episode: episode, token: token))
            }
            guard let id = ids.malId else { return "Skipped \(e.label) (no MyAnimeList id)" }
            return "Sent: \(e.label) · " + (try await MALClient.progress(animeID: id, episode: episode, token: token))
        }
    }

    /// A valid access token, refreshed when it's about to run out.
    private func token(_ s: SyncService) async throws -> String {
        guard var t = SyncTokens.load(s) else { throw SyncHTTP.Failure(status: 401, body: "not signed in") }
        if t.expired {
            switch s {
            case .trakt: t = try await TraktClient.refresh(t)
            case .mal: t = try await MALClient.refresh(t)
            case .anilist: throw SyncHTTP.Failure(status: 401, body: "AniList's sign-in ran out: connect again")
            }
            t.save(s)
        }
        return t.access
    }

    private func save() {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        if let data = try? e.encode(jobs) { try? data.write(to: file, options: .atomic) }
    }
}
