import ActivityKit
import Foundation

// Built into both Folio and FolioWidget: the Live Activities' data (1.22.0).
// The app starts and updates them (App/Sources/Activities); the widget
// extension draws them. Foundation and ActivityKit only.

// MARK: - Downloads

/// The downloads Live Activity: one for the whole queue while it runs.
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The file downloading now (its clean name), or "3 files" when
        /// several download at once.
        var title: String
        /// Files of this run not finished yet, the ones downloading included.
        var filesLeft: Int
        /// The whole run, 0...1.
        var progress: Double
        /// Bytes per second now.
        var speed: Double
        /// At this speed; nil while it isn't known (no speed yet).
        var secondsLeft: Double?
        /// Nothing downloads right now: a retry is waiting.
        var waiting = false
        /// The run ended (shown for a moment as Done).
        var done = false
        /// Done: files that finished, and those that failed.
        var finished = 0
        var failed = 0
        /// When `progress` was read, and when the run should end at the speed
        /// then (1.22.1). From these the ring, the bar and the time left move
        /// by themselves (timer views): while it downloads in the background
        /// Folio is suspended (iOS does the transfer) and can't update the
        /// activity. Each time Folio runs it corrects them.
        var measuredAt: Date?
        var finishBy: Date?
    }
}

extension DownloadActivityAttributes.ContentState {
    var percentText: String { "\(Int((min(1, max(0, progress)) * 100).rounded(.down)))%" }

    var speedText: String { ByteCountFormatter.string(fromByteCount: Int64(max(0, speed)), countStyle: .file) + "/s" }

    /// "12 min left · 3 files", "Waiting to retry", or nil (nothing known yet).
    var detailText: String? {
        if done {
            let inLibrary = finished == 1 ? "1 file in your library" : "\(finished) files in your library"
            return failed > 0 ? "\(inLibrary) · \(failed) failed" : inLibrary
        }
        var parts: [String] = []
        if waiting { parts.append("Waiting to retry") } else if let secondsLeft { parts.append(ActivityFormat.minutesLeft(secondsLeft)) }
        if filesLeft > 1 { parts.append("\(filesLeft) files") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The title on the Lock Screen, "Downloads finished" once done.
    var headline: String { done ? "Downloads finished" : title }

    /// For ProgressView(timerInterval:): it starts where `progress` was at
    /// `measuredAt` and is full at `finishBy`. Nil without an estimate
    /// (a still ring and bar instead).
    var timerRange: ClosedRange<Date>? {
        guard !done, !waiting, let at = measuredAt, let end = finishBy, end > at, progress < 1 else { return nil }
        let p = min(0.995, max(0, progress))
        let start = at.addingTimeInterval(-end.timeIntervalSince(at) * p / (1 - p))
        return start...end
    }

    /// For Text(timerInterval:): from the reading to the estimated end.
    var timeLeftRange: ClosedRange<Date>? {
        guard timerRange != nil, let at = measuredAt, let end = finishBy else { return nil }
        return at...end
    }

    /// Where the timers say the run is at `date` (0...1).
    func progress(at date: Date) -> Double {
        guard let r = timerRange else { return min(1, max(0, progress)) }
        let whole = r.upperBound.timeIntervalSince(r.lowerBound)
        return whole > 0 ? min(1, max(0, date.timeIntervalSince(r.lowerBound) / whole)) : 1
    }

    /// "12 files" style line under the title while the timers run: the
    /// time left is a timer view next to it.
    var filesText: String? {
        if waiting { return filesLeft > 1 ? "Waiting to retry · \(filesLeft) files" : "Waiting to retry" }
        return filesLeft > 1 ? "\(filesLeft) files" : nil
    }
}

/// folio://downloads: the downloads activity opens the Downloads screen.
enum DownloadsLink {
    static let url = URL(string: "folio://downloads")!
}

// MARK: - Now playing

/// The Live Activity for what's playing. Everything is in the content (none
/// of it in the attributes, which can't change), so the next episode can
/// take over the same activity: an app in the background can update one but
/// can't start one.
struct NowPlayingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        /// The episode line ("S1 · E3 · Title"), if there is one.
        var subtitle: String?
        /// The picture's file name in the group container's Activities
        /// folder (LiveActivityFiles), if there is one.
        var artwork: String?
        /// Seconds into the video at `at`.
        var position: Double
        var duration: Double
        var paused: Bool
        /// When `position` was read: from there the activity's timers move
        /// on by themselves, so it needs no update while the video plays.
        var at: Date
        /// The picture's colour, "RRGGBB" (1.22.1): the glow behind the
        /// Lock Screen pane and the ring in the Dynamic Island.
        var tint: String?
    }
}

extension NowPlayingActivityAttributes.ContentState {
    /// When the video would have started, played straight through to `position`.
    var startDate: Date { at.addingTimeInterval(-max(0, position)) }
    /// When it ends at this pace.
    var endDate: Date { startDate.addingTimeInterval(max(0, duration)) }

    /// For ProgressView(timerInterval:) and Text(timerInterval:): nil while
    /// paused or with no length known (a static bar and text instead).
    var timerRange: ClosedRange<Date>? {
        guard !paused, duration > 0, position < duration else { return nil }
        return startDate...endDate
    }

    func position(at date: Date) -> Double {
        let p = paused ? position : position + date.timeIntervalSince(at)
        return duration > 0 ? min(duration, max(0, p)) : max(0, p)
    }

    func progress(at date: Date) -> Double { duration > 0 ? position(at: date) / duration : 0 }

    func timeLeft(at date: Date) -> Double { max(0, duration - position(at: date)) }

    /// "12:34 left", "1:02:03 left" (paused: a still line, as the timer
    /// text doesn't move then). Empty with no length known.
    func timeLeftText(at date: Date) -> String {
        guard duration > 0 else { return "" }
        return ActivityFormat.clock(timeLeft(at: date)) + " left"
    }
}

// MARK: - Text

enum ActivityFormat {
    /// A download's time left: "Less than a minute left", "12 min left",
    /// "1 h 5 min left". In whole minutes: it's updated every few seconds at
    /// most, so seconds would look stuck.
    static func minutesLeft(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes <= 1 { return seconds < 60 ? "Less than a minute left" : "1 min left" }
        if minutes < 60 { return "\(minutes) min left" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h left" : "\(h) h \(m) min left"
    }

    /// A player's clock: "4:05", "12:34", "1:02:03".
    static func clock(_ seconds: Double) -> String {
        let t = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        let h = t / 3600, m = t % 3600 / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Pictures

/// Where the app leaves the activities' pictures for the widget extension
/// (it runs in its own process and can't see the app's files): an
/// Activities folder in the App Group's container. Nil without the group.
enum LiveActivityFiles {
    static func directory(in container: URL? = FolioGroup.container, create: Bool = false) -> URL? {
        guard let container else { return nil }
        let dir = container.appendingPathComponent("Activities", isDirectory: true)
        if create {
            do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return nil }
        }
        return dir
    }

    static func url(for name: String?) -> URL? {
        guard let name, !name.isEmpty, !name.contains("/") else { return nil }
        return directory()?.appendingPathComponent(name)
    }
}
