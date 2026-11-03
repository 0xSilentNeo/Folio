import ActivityKit
import Combine
import UIKit

/// The downloads Live Activity (1.22.0): while files download, the one
/// downloading (or how many at once), the run's progress, the speed and the
/// time left. It ends when the queue is done (Done stays up for a minute)
/// or when everything is paused or cancelled. Tapping it opens the
/// Downloads screen (folio://downloads).
///
/// In the background the transfers go on without Folio (a background
/// URLSession), so nothing updates the activity: it turns stale after a
/// while and says it's downloading in the background. When the last file is
/// done iOS wakes Folio, which ends it.
@MainActor
final class DownloadActivity {
    static let shared = DownloadActivity()
    typealias State = DownloadActivityAttributes.ContentState

    /// ActivityKit budgets updates: at most one per this many seconds. The
    /// end isn't held back.
    static let minGap: TimeInterval = 5
    /// Pushed at least this often while it runs, so it turns stale only
    /// when Folio stops updating it.
    static let refreshEvery: TimeInterval = 60
    static let staleAfter: TimeInterval = 120
    static let doneShownFor: TimeInterval = 60

    enum Phase: Equatable {
        /// A file is downloading.
        case downloading
        /// Files are queued and none runs: a retry's wait, or about to start.
        case waiting
        /// Paused, cancelled, or held by Low Power Mode or charging.
        case stopped
        /// Everything in the run is done (or failed).
        case finished
    }

    private var activity: Activity<DownloadActivityAttributes>?
    /// The files this activity is about: its progress is theirs.
    private var run = Set<UUID>()
    private var shown: State?
    private var lastPush = Date.distantPast
    private var trailing: Task<Void, Never>?
    private var subscription: AnyCancellable?
    private var queued = false
    private var labMode = false
    private var toldBackground = false

    private init() {}

    func start() {
        // Folio relaunched with its downloads still running: the activity of
        // the last run carries on (it can be updated from the background,
        // not started again there).
        let left = Activity<DownloadActivityAttributes>.activities
        activity = left.first
        for a in left.dropFirst() { Task { await a.end(nil, dismissalPolicy: .immediate) } }
        if activity != nil {
            let recent = Date().addingTimeInterval(-7200)
            run = Set(DownloadManager.shared.items.filter { $0.state != .done || ($0.finished ?? .distantPast) > recent }.map(\.id))
            dlog("activity", "downloads: carrying on with the last run's activity")
        }
        // Progress arrives a few times a second: one look per turn of the main loop.
        subscription = DownloadManager.shared.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.queued else { return }
                self.queued = true
                DispatchQueue.main.async { MainActor.assumeIsolated { self.queued = false; self.refresh() } }
            }
        }
        refresh()
    }

    func refresh() {
        guard !labMode else { return }
        let dm = DownloadManager.shared
        guard LiveActivities.enabled else { finish(nil, after: nil); return }
        let now = Date()
        switch Self.phase(dm.items, run: run, conditionsOK: dm.conditionsOK) {
        case .downloading, .waiting:
            run.formUnion(dm.items.filter { $0.state == .running || $0.state == .queued }.map(\.id))
            let s = Self.state(dm.items, run: run, speed: dm.speed) { TitleParser.clean($0.fileName) }
            if let activity, activity.activityState == .active || activity.activityState == .stale {
                guard let shown else { push(s, to: activity, now: now); return }
                guard Self.looksDifferent(shown, s) || now.timeIntervalSince(lastPush) >= Self.refreshEvery else { return }
                let wait = Self.minGap - now.timeIntervalSince(lastPush)
                if wait > 0 { holdBack(wait) } else { push(s, to: activity, now: now) }
            } else if activity == nil, !dm.active.isEmpty {
                request(s)
            }
            // (Swiped away from the Lock Screen: not shown again for this run.)
        case .stopped:
            finish(nil, after: nil)
        case .finished:
            var s = Self.state(dm.items, run: run, speed: 0) { TitleParser.clean($0.fileName) }
            s.done = true
            finish(s, after: now.addingTimeInterval(Self.doneShownFor))
        }
    }

    // MARK: Decisions

    nonisolated static func phase(_ items: [DownloadItem], run: Set<UUID>, conditionsOK: Bool) -> Phase {
        if items.contains(where: { $0.state == .running }) { return .downloading }
        if items.contains(where: { $0.state == .queued }) {
            // Low Power Mode or "only while charging" holds the queue: as good as paused.
            return conditionsOK ? .waiting : .stopped
        }
        let mine = items.filter { run.contains($0.id) }
        if mine.contains(where: { $0.state == .paused }) || !mine.contains(where: { $0.state == .done }) { return .stopped }
        return .finished
    }

    /// The activity's content for the run's files. `name`: a file's name as shown.
    nonisolated static func state(_ items: [DownloadItem], run: Set<UUID>, speed: Double, name: (DownloadItem) -> String) -> State {
        let mine = items.filter { run.contains($0.id) }
        let running = items.filter { $0.state == .running }
        let left = mine.filter { $0.state == .running || $0.state == .queued }
        // Paused and failed files aren't part of what's left to do.
        let counted = mine.filter { $0.state == .running || $0.state == .queued || $0.state == .done }
        let total = counted.reduce(Int64(0)) { $0 + max(0, $1.expected) }
        let got = counted.reduce(Int64(0)) { $0 + ($1.state == .done ? max(0, $1.expected) : min(max(0, $1.received), max(0, $1.expected))) }
        let bytesLeft = left.reduce(Int64(0)) { $0 + max(0, $1.expected - $1.received) }
        let title: String
        switch running.count {
        case 0: title = left.first.map(name) ?? "Downloads"
        case 1: title = name(running[0])
        default: title = "\(running.count) files"
        }
        return State(title: title, filesLeft: left.count,
                     progress: total > 0 ? Double(got) / Double(total) : 0,
                     speed: running.isEmpty ? 0 : speed,
                     secondsLeft: !running.isEmpty && speed > 1 && bytesLeft > 0 ? Double(bytesLeft) / speed : nil,
                     waiting: running.isEmpty,
                     finished: mine.filter { $0.state == .done }.count,
                     failed: mine.filter { $0.state == .failed }.count)
    }

    /// Whether the activity would read differently (what an update is for).
    nonisolated static func looksDifferent(_ a: State, _ b: State) -> Bool {
        a.headline != b.headline || a.percentText != b.percentText || a.speedText != b.speedText
            || a.detailText != b.detailText || a.waiting != b.waiting || a.done != b.done
    }

    // MARK: ActivityKit

    private func request(_ s: State) {
        guard LiveActivities.canStart else {
            if !toldBackground {
                toldBackground = true
                dlog("activity", "downloads: Folio is in the background, the activity starts when it's back")
            }
            return
        }
        toldBackground = false
        do {
            activity = try Activity.request(attributes: DownloadActivityAttributes(), content: content(s), pushType: nil)
            shown = s
            lastPush = Date()
            dlog("activity", "downloads: activity started (\(s.filesLeft) file(s))")
        } catch {
            dlog("activity", "downloads: no activity (\(error.localizedDescription))")
        }
    }

    private func push(_ s: State, to activity: Activity<DownloadActivityAttributes>, now: Date) {
        trailing?.cancel()
        trailing = nil
        shown = s
        lastPush = now
        let c = content(s)
        Task { await activity.update(c) }
    }

    private func holdBack(_ wait: TimeInterval) {
        guard trailing == nil else { return }
        trailing = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.trailing = nil
            self.lastPush = .distantPast
            self.refresh()
        }
    }

    private func content(_ s: State) -> ActivityContent<State> {
        ActivityContent(state: s, staleDate: s.done ? nil : Date().addingTimeInterval(Self.staleAfter), relevanceScore: 50)
    }

    /// Ends the activity: with `final` shown until `after`, or at once.
    private func finish(_ final: State?, after: Date?) {
        trailing?.cancel()
        trailing = nil
        run = []
        shown = nil
        guard let a = activity else { return }
        activity = nil
        dlog("activity", "downloads: activity ended\(final?.done == true ? " (done)" : "")")
        let c = final.map { ActivityContent(state: $0, staleDate: nil) }
        Task { await a.end(c, dismissalPolicy: after.map { .after($0) } ?? .immediate) }
    }

    // MARK: Lab

    /// -labLiveActivities: a sample run (the download list isn't touched).
    func lab() {
        labMode = true
        let s = State(title: "Lab Show · S01E04", filesLeft: 3, progress: 0.42, speed: 2_400_000, secondsLeft: 760)
        if let activity { push(s, to: activity, now: Date()) } else { request(s) }
    }
}
