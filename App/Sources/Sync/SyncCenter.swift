import Foundation
import Combine
import Network
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
    /// Services whose saved sign-in was refused when it was renewed (1.30.4):
    /// their jobs wait for a new sign-in instead of 60 tries; Settings says
    /// "Sign in again" (lastResult).
    @Published private(set) var needsSignIn: Set<SyncService> = []

    /// Internal, not private (1.30.4): the tests read the queue's decoding.
    struct Job: Codable, Hashable {
        var service: SyncService
        var event: SyncEvent?
        var watchlist: WatchlistItem?
        var add: Bool?
        var attempts = 0
    }

    private var jobs: [Job] = [] { didSet { waiting = jobs.count } }
    private var flushing = false
    private var bag: Set<AnyCancellable> = []
    /// One refresh per service that every caller waits for (1.30.2): two at
    /// once both used Trakt's single-use refresh token, and one failed.
    private var refreshing: [SyncService: Task<SyncTokens, Error>] = [:]
    /// What was sent and when ("trakt|tt1|2|1"), kept between launches
    /// (1.30.2): finishing an episode, then opening it again near its end,
    /// sent a second play.
    private var sent: [String: Date] = [:]

    private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("sync-queue.json")
    }()
    private let sentFile: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("sync-sent.json")
    }()

    /// How long an episode or film counts as already sent.
    nonisolated static var sentWindow: TimeInterval { 12 * 3600 }
    nonisolated static var sentLimit: Int { 200 }

    nonisolated static func sentKey(_ s: SyncService, _ e: SyncEvent) -> String { "\(s.rawValue)|\(e.key)" }

    /// Sent within the last 12 hours (either side of now, so a clock set back doesn't hold a play for good).
    nonisolated static func sentRecently(_ sent: [String: Date], key: String, now: Date) -> Bool {
        guard let at = sent[key] else { return false }
        return abs(now.timeIntervalSince(at)) < sentWindow
    }

    /// Without what's older than 12 hours, and the newest 200 at most.
    nonisolated static func prunedSent(_ sent: [String: Date], now: Date) -> [String: Date] {
        var kept = sent.filter { abs(now.timeIntervalSince($0.value)) < sentWindow }
        if kept.count > sentLimit {
            let newest = kept.sorted { $0.value > $1.value }.prefix(sentLimit)
            kept = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        return kept
    }

    private init() {
        for s in SyncService.allCases {
            if let t = SyncTokens.load(s) { accounts[s] = t.user ?? "" }
        }
        // One entry by entry (1.30.4): one this version can't read emptied
        // the whole queue, and the next save wrote the empty one over it.
        if let data = try? Data(contentsOf: file) { jobs = Self.decodeJobs(data) }
        if let data = try? Data(contentsOf: sentFile) { sent = Self.prunedSent(Self.decodeSent(data), now: Date()) }
        _ = Self.path
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.flushSoon() }
            .store(in: &bag)
        // A service switched on again (1.30.4): what waited for it goes now.
        switchedOn = Set(SyncService.allCases.filter(isOn))
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.switchesChanged() }
            .store(in: &bag)
        WatchlistStore.shared.changes
            .sink { [weak self] change in self?.watchlistChanged(change.item, added: change.added) }
            .store(in: &bag)
    }

    private var switchedOn: Set<SyncService> = []

    private func switchesChanged() {
        let on = Set(SyncService.allCases.filter(isOn))
        guard on != switchedOn else { return }
        let turnedOn = !on.subtracting(switchedOn).isEmpty
        switchedOn = on
        if turnedOn { flushSoon() }
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
        needsSignIn.remove(s)
        dlog("sync", "\(s.name): connected\(t.user.map { " as \($0)" } ?? "")")
        flushSoon()         // what waited for the sign-in (1.30.4)
    }

    func disconnect(_ s: SyncService) {
        // A refresh under way must not put the sign-in back (1.30.2).
        refreshing[s]?.cancel()
        refreshing[s] = nil
        SyncTokens.clear(s)
        accounts[s] = nil
        UserDefaults.standard.set(false, forKey: s.enabledKey)
        jobs.removeAll { $0.service == s }
        save()
        let prefix = s.rawValue + "|"
        if sent.keys.contains(where: { $0.hasPrefix(prefix) }) {
            sent = sent.filter { !$0.key.hasPrefix(prefix) }
            saveSent()
        }
        lastResult[s] = nil
        needsSignIn.remove(s)
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
        let now = Date()
        var queued: [SyncService] = []
        for s in targets where !jobs.contains(where: { $0.service == s && $0.event?.key == e.key }) {
            // Sent in the last 12 hours (1.30.2): not a second play.
            if Self.sentRecently(sent, key: Self.sentKey(s, e), now: now) {
                dlog("sync", "\(s.name): \(e.label) was sent already, not again")
                continue
            }
            jobs.append(Job(service: s, event: e))
            queued.append(s)
        }
        guard !queued.isEmpty else { flushSoon(); return }
        dlog("sync", "finished \(e.label): to \(queued.map(\.name).joined(separator: ", "))")
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
        // Time in the background (1.30.4): a play sent as Folio left the
        // screen was cut off mid-request and sent again, or not, next time.
        let bg = BackgroundTime("folio.sync")
        Task {
            await flush()
            flushing = false
            bg.end()
        }
    }

    // MARK: Reading the saved queue (1.30.4)

    /// The saved queue, entry by entry: one this version can't read is left out, not the rest.
    nonisolated static func decodeJobs(_ data: Data) -> [Job] {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return d.decodeLossy(Job.self, from: data) ?? []
    }

    private struct SentDate: Decodable {
        var value: Date?
        // Through the container, so the decoder's ISO 8601 dates apply.
        init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(Date.self) }
    }

    /// What was sent and when, entry by entry.
    nonisolated static func decodeSent(_ data: Data) -> [String: Date] {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return ((try? d.decode([String: SentDate].self, from: data)) ?? [:]).compactMapValues(\.value)
    }

    /// A refused renewal of the sign-in (Trakt's and MyAnimeList's
    /// invalid_grant, HTTP 400 or 401): a new sign-in is needed, not another try.
    nonisolated static func refusedRefresh(status: Int, body: String) -> Bool {
        status == 401 || (status == 400 && body.contains("invalid_grant"))
    }

    /// Whether the phone has a network now (1.30.4): offline, a job not
    /// reached holds the whole queue; online, only its own service's jobs.
    private static let path: NWPathMonitor = {
        let m = NWPathMonitor()
        m.start(queue: DispatchQueue(label: "folio.sync.path", qos: .utility))
        return m
    }()

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
            // Switched off, not disconnected (1.30.4): kept until it's on
            // again (disconnecting removes them). They were deleted here.
            guard isConnected(job.service) else { jobs.remove(at: i); continue }
            guard isOn(job.service), !needsSignIn.contains(job.service) else { i += 1; continue }
            if waiting.contains(job.service) { i += 1; continue }
            do {
                let outcome = try await send(job)
                lastResult[job.service] = outcome
                dlog("sync", "\(job.service.name): \(outcome)")
                jobs.removeAll { $0 == job }
                if let e = job.event, outcome.hasPrefix("Sent") {
                    sent[Self.sentKey(job.service, e)] = Date()
                    sent = Self.prunedSent(sent, now: Date())
                    saveSent()
                }
            } catch {
                var j = job
                j.attempts += 1
                let why = (error as? SyncHTTP.Failure).map { "\($0.errorDescription ?? "") \($0.body.prefix(160))" } ?? error.localizedDescription
                dlog("sync/error", "\(job.service.name): \(job.event?.label ?? job.watchlist?.name ?? "?") not sent (\(why)), try \(j.attempts)")
                // Waiting for a new sign-in (1.30.4): kept as it is, not counted.
                if needsSignIn.contains(job.service) { i += 1; continue }
                lastResult[job.service] = "Not sent yet: \(job.event?.label ?? job.watchlist?.name ?? "") (\(error.localizedDescription))"
                // Not reached: this (and, offline, the rest) waits for the next try.
                let status = (error as? SyncHTTP.Failure)?.status
                let unreachable = status == 0
                // Dropped after six refusals of the job itself (1.30.1). An
                // outage or a rate limit counted too, so six tries during one
                // deleted everything queued; those wait now (up to 60 tries,
                // so a job a service will never take doesn't stay for good;
                // not reached at all, it is never dropped, as before).
                let transient = status.map(Self.isTransient) ?? false
                if let k = jobs.firstIndex(of: job) {
                    if j.attempts >= (transient ? 60 : 6) && !unreachable { jobs.remove(at: k) } else { jobs[k] = j; i += 1 }
                }
                // Online, only this service or its anime lookup wasn't reached
                // (1.30.4): its jobs wait, the other services' still go.
                if unreachable, Self.path.currentPath.status != .satisfied { break }
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
            guard let hint = e.anime, let episode = hint.episode ?? e.episode else {
                return "Skipped \(e.label) (not found on \(s.name))"
            }
            let ids: AnimeHint
            switch await SkipService.shared.animeIDLookup(hint, season: e.season) {
            case .found(let found): ids = found
            case .notFound: return "Skipped \(e.label) (not found on \(s.name))"
            case .unreachable:
                // Not reached isn't "not found" (1.30.4): the job waits, never
                // dropped. Until then an offline or rate-limited scrobble was skipped.
                let offline = Self.path.currentPath.status != .satisfied
                throw SyncHTTP.Failure(status: 0, body: "the anime lookup wasn't reached (\(offline ? "offline" : "AniList or ids.moe didn't answer"))")
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
        guard let t = SyncTokens.load(s) else { throw SyncHTTP.Failure(status: 401, body: "not signed in") }
        guard t.expired else { return t.access }
        // One refresh at a time (1.30.2): whoever else asks waits for it.
        if let running = refreshing[s] { return try await running.value.access }
        let task = Task { () throws -> SyncTokens in
            do {
                let fresh: SyncTokens
                switch s {
                case .trakt: fresh = try await TraktClient.refresh(t)
                case .mal: fresh = try await MALClient.refresh(t)
                case .anilist: throw SyncHTTP.Failure(status: 401, body: "AniList's sign-in ran out: connect again")
                }
                // Disconnected meanwhile (1.30.2): the tokens were saved
                // again, and the service showed as connected on next launch.
                guard !Task.isCancelled, self.accounts[s] != nil else {
                    throw SyncHTTP.Failure(status: 401, body: "not signed in")
                }
                fresh.save(s)
                self.refreshing[s] = nil
                return fresh
            } catch {
                // Cancelled by disconnect: the entry is no longer this task's.
                if !Task.isCancelled {
                    self.refreshing[s] = nil
                    // Refused, not unreachable (1.30.4): "Sign in again" in
                    // Settings, and its jobs wait for that, not 60 more tries.
                    if let f = error as? SyncHTTP.Failure, self.accounts[s] != nil, Self.refusedRefresh(status: f.status, body: f.body) {
                        self.needsSignIn.insert(s)
                        self.lastResult[s] = "Sign in again: \(s.name) no longer accepts Folio's sign-in. Disconnect, then connect again; what's waiting is sent then."
                        dlog("sync/error", "\(s.name): the sign-in's renewal was refused (HTTP \(f.status)): sign in again")
                    }
                }
                throw error
            }
        }
        refreshing[s] = task
        // Its own time in the background (1.30.4): Trakt's refresh token is
        // single-use, and a renewal cut off half-way could lose the sign-in.
        let bg = BackgroundTime("folio.sync.refresh")
        defer { bg.end() }
        return try await task.value.access
    }

    private func save() {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        if let data = try? e.encode(jobs) { try? data.write(to: file, options: .atomic) }
    }

    private func saveSent() {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        if let data = try? e.encode(sent) { try? data.write(to: sentFile, options: .atomic) }
    }
}
