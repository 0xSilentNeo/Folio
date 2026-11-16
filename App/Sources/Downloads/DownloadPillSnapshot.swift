import Foundation

/// What the downloads pill shows, read from the manager at most twice a
/// second (1.28.2). The pill watched the manager itself, which announces
/// each piece's progress, many times a second: 5–20 redraws a second of a
/// pill whose numbers change once.
struct DownloadPillSnapshot: Equatable {
    var hasWork = false
    var active = 0
    var speed: Double = 0
    var history: [Double] = []
    /// Files paused since Folio started (1.30.4): the pill stays for them,
    /// its button resumes them (1.30.6: only them). After Pause all (or
    /// iOS's stop button) it went, with no way back but the Downloads screen.
    var paused = 0
    /// Files queued, not started yet (1.30.6): what "Waiting" counts.
    var queued = 0

    /// The pill shows.
    var shown: Bool { hasWork || paused > 0 }
    /// Its button resumes (nothing downloading, something paused); else it pauses.
    var resumes: Bool { active == 0 && paused > 0 }
    /// The files beside the speed or the word: running ones, else the ones
    /// waiting to start, else the paused ones; nil for none (1.30.6: with
    /// files only queued it read "Waiting · 0 files").
    var count: Int? {
        let n = active > 0 ? active : (hasWork ? queued : paused)
        return n > 0 ? n : nil
    }

    @MainActor static func now() -> DownloadPillSnapshot {
        let d = DownloadManager.shared
        return DownloadPillSnapshot(hasWork: d.hasWork, active: d.active.count, speed: d.speed, history: d.speedHistory,
                                    paused: DownloadManager.pillPaused(d.items, pausedThisRun: d.pausedThisRun).count,
                                    queued: d.items.filter { $0.state == .queued }.count)
    }

    /// `now().shown` without building the snapshot (1.30.6): for a page's
    /// room under the pill, whose first value is worked out each time the
    /// page's parent draws (DownloadPillRoom).
    @MainActor static var shownNow: Bool {
        let d = DownloadManager.shared
        return d.hasWork || (!d.pausedThisRun.isEmpty && d.items.contains { $0.state == .paused && d.pausedThisRun.contains($0.id) })
    }
}
