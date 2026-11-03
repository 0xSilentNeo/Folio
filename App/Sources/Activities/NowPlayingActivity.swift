import ActivityKit
import UIKit

/// The Live Activity for what's playing (1.22.0): title, episode line,
/// progress and time left, with play/pause and 10 s back and forward on the
/// Lock Screen and in the expanded Dynamic Island.
///
/// The player calls `start` when a video opens, `update` as it plays and
/// `end` when it closes. The bar and the time left move by themselves
/// (timer views from the last position), so ActivityKit hears only of a
/// pause, a play, a seek or a new length: `update` may be called as often
/// as the player likes. The buttons post NowPlayingCommand.notification
/// (NowPlayingIntents.swift), which the player acts on.
@MainActor
enum NowPlayingActivity {
    typealias State = NowPlayingActivityAttributes.ContentState

    /// Updates at most this often (a scrub sends many seeks); the last one
    /// is never dropped, only held back.
    static let minGap: TimeInterval = 1
    /// The lab's sample video (-labLiveActivities).
    static let labID = "lab:now-playing"

    private static var activity: Activity<NowPlayingActivityAttributes>?
    /// What's playing, nil when nothing is. Kept while Live Activities are
    /// off, so switching them on mid-episode brings the activity back.
    private static var current: State?
    private static var currentID: String?
    /// The content ActivityKit has now.
    private static var shown: State?
    private static var lastPush = Date.distantPast
    private static var trailing: Task<Void, Never>?
    private static var ending: Task<Void, Never>?
    /// Bumped by start and end: a picture saved for an earlier video isn't used.
    private static var generation = 0
    private static var listening = false
    private static var toldBackground = false
    /// Swiped away from the Lock Screen (or ended by iOS after hours): not
    /// brought back for this video; the next one shows it again.
    private static var dismissedID: String?

    // MARK: The player's calls

    static func start(id: String, title: String, subtitle: String?, duration: Double, position: Double, paused: Bool, artwork: UIImage?) {
        generation += 1
        let gen = generation
        // The next episode (autoplay) takes over the activity that end() leaves up for a moment.
        ending?.cancel()
        ending = nil
        let same = id == currentID
        currentID = id
        // One swiped away during the last video: this one shows it again.
        if !same, let a = activity, a.activityState == .dismissed || a.activityState == .ended {
            activity = nil
            shown = nil
        }
        current = State(title: title, subtitle: subtitle?.isEmpty == true ? nil : subtitle, artwork: same ? current?.artwork : nil,
                        position: clean(position), duration: clean(duration), paused: paused, at: Date(), tint: same ? current?.tint : nil)
        listen()
        dlog("activity", "now playing: \(same ? "again" : "start")\(artwork == nil ? ", no picture" : "")")
        guard let artwork, current?.artwork == nil else { show(force: true); return }
        // The picture first (a few ms, off the main thread): an activity
        // shown without it would need a second update a moment later.
        Task {
            async let name = LiveActivities.savePicture(artwork, prefix: "nowplaying")
            async let tint = LiveActivities.tint(of: artwork)
            let (saved, colour) = await (name, tint)
            guard gen == generation, current != nil else { return }
            current?.artwork = saved
            current?.tint = colour
            show(force: true)
        }
    }

    static func update(position: Double, duration: Double, paused: Bool) {
        guard var s = current else { return }
        s.position = clean(position)
        s.duration = clean(duration)
        s.paused = paused
        s.at = Date()
        current = s
        // Not shown yet (being started, or off): it starts with `current`.
        guard let shown, activity != nil else { return }
        if needsUpdate(from: shown, to: s) { show(force: false) }
    }

    static func end() {
        guard current != nil || activity != nil else { return }
        generation += 1
        current = nil
        currentID = nil
        dismissedID = nil
        trailing?.cancel()
        trailing = nil
        dlog("activity", "now playing: end")
        // A moment's grace before it goes: the next episode's start takes the
        // same activity over, also in the background, where a new one
        // couldn't be started.
        ending?.cancel()
        ending = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, current == nil else { return }
            await endAll()
        }
    }

    // MARK: Decisions

    /// Whether ActivityKit needs the new content: the timers already show
    /// a video playing on at its pace, so only a pause or play, a new
    /// length, a new video, or a position more than 2 s from where the
    /// timers are (a seek; a speed other than 1x drifts) counts.
    nonisolated static func needsUpdate(from old: State, to new: State) -> Bool {
        if old.paused != new.paused { return true }
        if abs(old.duration - new.duration) > 1 { return true }
        if old.title != new.title || old.subtitle != new.subtitle || old.artwork != new.artwork || old.tint != new.tint { return true }
        return abs(old.position(at: new.at) - new.position) > 2
    }

    /// Stale once the video should have ended (Folio was closed while it played).
    nonisolated static func staleDate(_ s: State) -> Date? {
        s.timerRange.map { $0.upperBound.addingTimeInterval(60) }
    }

    // MARK: Showing

    private static func show(force: Bool) {
        guard let s = current else { return }
        guard LiveActivities.enabled else {
            if activity != nil { Task { await endAll() } }
            return
        }
        if let activity, activity.activityState == .dismissed || activity.activityState == .ended {
            self.activity = nil
            shown = nil
            dismissedID = currentID
            dlog("activity", "now playing: dismissed, not shown again for this video")
        }
        if let activity, activity.activityState == .active || activity.activityState == .stale {
            let wait = minGap - Date().timeIntervalSince(lastPush)
            if !force, wait > 0 {
                holdBack(wait)
                return
            }
            trailing?.cancel()
            trailing = nil
            shown = s
            lastPush = Date()
            Task { await activity.update(ActivityContent(state: s, staleDate: staleDate(s), relevanceScore: 100)) }
            return
        }
        guard currentID != dismissedID else { return }
        request(s)
    }

    private static func holdBack(_ wait: TimeInterval) {
        guard trailing == nil else { return }
        trailing = Task {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            trailing = nil
            show(force: true)
        }
    }

    private static func request(_ s: State) {
        guard LiveActivities.canStart else {
            if !toldBackground {
                toldBackground = true
                dlog("activity", "now playing: Folio is in the background, the activity starts when it's back")
            }
            return
        }
        toldBackground = false
        // One at a time: any other (left from an earlier video) goes.
        for old in Activity<NowPlayingActivityAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        do {
            activity = try Activity.request(attributes: NowPlayingActivityAttributes(),
                                            content: ActivityContent(state: s, staleDate: staleDate(s), relevanceScore: 100),
                                            pushType: nil)
            shown = s
            lastPush = Date()
            dlog("activity", "now playing: activity started")
        } catch {
            activity = nil
            shown = nil
            dlog("activity", "now playing: no activity (\(error.localizedDescription))")
        }
    }

    private static func endAll() async {
        let all = Activity<NowPlayingActivityAttributes>.activities
        activity = nil
        shown = nil
        for a in all { await a.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: App events

    /// Launch: the player isn't open, so an activity from the last run is left over.
    static func launch() {
        guard current == nil else { return }
        let left = Activity<NowPlayingActivityAttributes>.activities
        guard !left.isEmpty else { return }
        dlog("activity", "now playing: ending \(left.count) activity left from the last run")
        Task { for a in left { await a.end(nil, dismissalPolicy: .immediate) } }
    }

    static func becameActive() {
        if current != nil, activity == nil { show(force: true) }
    }

    static func settingChanged() {
        if LiveActivities.enabled {
            if current != nil { show(force: true) }
        } else {
            trailing?.cancel()
            trailing = nil
            Task { await endAll() }
        }
    }

    // MARK: Buttons

    /// Logs the activity's buttons (the player acts on them); the lab's
    /// sample plays along.
    private static func listen() {
        guard !listening else { return }
        listening = true
        NotificationCenter.default.addObserver(forName: NowPlayingCommand.notification, object: nil, queue: .main) { note in
            let command = note.userInfo?[NowPlayingCommand.key] as? String ?? "?"
            MainActor.assumeIsolated {
                dlog("activity", "now playing: \(command) from the Live Activity")
                guard currentID == labID, let s = current else { return }
                let now = s.position(at: Date())
                switch command {
                case "toggle": update(position: now, duration: s.duration, paused: !s.paused)
                case "back": update(position: max(0, now - 10), duration: s.duration, paused: s.paused)
                case "forward": update(position: min(s.duration, now + 10), duration: s.duration, paused: s.paused)
                default: break
                }
            }
        }
    }

    private static func clean(_ v: Double) -> Double { v.isFinite ? max(0, v) : 0 }
}
