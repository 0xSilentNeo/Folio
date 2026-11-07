import Foundation

/// What the watching moments need (1.24.0's EngagementNotifications; since
/// 1.25.0 NotifyCenter schedules them): Continue Watching, the episode
/// finished last, the watch log, a late night.
@MainActor
enum EngagementState {
    /// What the plan needs, from history, the watch log, the library and the tracker.
    static func gather(now: Date) async -> EngagePlanner.State {
        let history = HistoryStore.shared
        let groups = LibraryOrganizer.groups(await ContinueQueue.libraryFiles()).filter(\.isSeries)
        var s = EngagePlanner.State()
        s.continueWatching = history.continueWatching.prefix(6).map { entry($0, groups: groups) }
        if let latest = history.entries.max(by: { $0.updated < $1.updated }), latest.isFinished,
           HeroCard.parts(latest.item, meta: nil).number != nil {
            s.lastFinished = entry(latest, groups: groups)
        }
        s.lastWatched = [WatchLog.shared.lastWatched, history.entries.map(\.updated).max()].compactMap { $0 }.max()
        s.days = WatchLog.shared.days
        // What was on at the late night's end: the entry saved closest to it
        // (from then on, as the same episode may have gone on past 5 am).
        if let until = WatchLog.shared.days.last?.lateUntil,
           let e = history.entries.filter({ $0.updated >= until.addingTimeInterval(-15 * 60) && $0.updated <= until.addingTimeInterval(12 * 3600) })
            .min(by: { abs($0.updated.timeIntervalSince(until)) < abs($1.updated.timeIntervalSince(until)) }) {
            let x = entry(e, groups: [])
            s.lateNight = (until, x.name, x.showKey)
        }
        return s
    }

    static func entry(_ e: HistoryEntry, groups: [LibraryGroup]) -> EngagePlanner.Entry {
        let episode = HeroCard.parts(e.item, meta: nil).number != nil
        var name = ShowCatalog.name(of: e)
        if !episode, e.item.addonRef == nil {
            let t = TitleParser.parse(e.item.fileName).title
            if !t.isEmpty { name = t }
        }
        return .init(id: e.id, name: name, showKey: episode ? HistoryStore.showKey(e) : nil, position: e.position, duration: e.duration,
                     updated: e.updated, finished: e.isFinished, episodesLeft: episode ? episodesLeft(e, groups: groups) : nil)
    }

    /// Episodes still to watch of the entry's show in the library: this one
    /// unless it's finished, and each later episode once (two releases of an
    /// episode are one). Nil when the file isn't a library file.
    static func episodesLeft(_ e: HistoryEntry, groups: [LibraryGroup]) -> Int? {
        guard let rel = HistoryStore.libraryRelative(e.id) ?? HistoryStore.libraryRelative(e.item.url) else { return nil }
        for g in groups {
            guard let i = g.files.firstIndex(where: { HistoryStore.libraryRelative($0.standardizedFileURL.path) == rel }) else { continue }
            return EngagePlanner.episodesLeft(g.files.map(\.lastPathComponent), at: i, finished: e.isFinished)
        }
        return nil
    }

}
