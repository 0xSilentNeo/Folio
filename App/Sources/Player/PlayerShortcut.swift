import UIKit

/// The keys the player answers itself on a hardware keyboard (1.30.0).
/// Until then every key went straight to mpv, whose own bindings seek by 5 s
/// and know nothing of Folio's panels, its next episode or its Fill.
///
/// Only these keys with no modifier are Folio's. Every other key, and these
/// with Shift, Ctrl, Alt or ⌘, still goes to mpv and its input.conf.
enum PlayerShortcut: String, CaseIterable {
    case playPause, back, forward, volumeUp, volumeDown, fill, next, close

    /// The shortcut for a key, by the name mpv knows it by
    /// (PlayerViewController.mpvKeyName): "LEFT", "f", "Shift+LEFT".
    static func claimed(mpvName: String) -> PlayerShortcut? {
        switch mpvName {
        case "SPACE": .playPause
        case "LEFT": .back
        case "RIGHT": .forward
        case "UP": .volumeUp
        case "DOWN": .volumeDown
        case "f": .fill
        case "n": .next
        case "ESC": .close
        default: nil
        }
    }

    /// Its name in the list iPadOS shows while ⌘ is held.
    var title: String {
        switch self {
        case .playPause: "Play or Pause"
        case .back: "Skip Back"
        case .forward: "Skip Forward"
        case .volumeUp: "Volume Up"
        case .volumeDown: "Volume Down"
        case .fill: "Fit or Fill the Screen"
        case .next: "Next Episode"
        case .close: "Close"
        }
    }

    /// The key, as UIKeyCommand names it.
    var input: String {
        switch self {
        case .playPause: " "
        case .back: UIKeyCommand.inputLeftArrow
        case .forward: UIKeyCommand.inputRightArrow
        case .volumeUp: UIKeyCommand.inputUpArrow
        case .volumeDown: UIKeyCommand.inputDownArrow
        case .fill: "f"
        case .next: "n"
        case .close: UIKeyCommand.inputEscape
        }
    }

    /// One press of ↑ or ↓: a sixteenth, the step of the iPad's own buttons.
    static func volume(_ current: Float, up: Bool) -> Float {
        min(1, max(0, current + (up ? 1 : -1) / 16))
    }

    /// What Esc closes: the topmost thing that's open, and the player only
    /// when nothing is. With the screen locked, only a sheet over it.
    enum EscapeTarget: Equatable { case nothing, panel, console, card, sheet, player }

    static func escapeTarget(locked: Bool, panel: Bool, console: Bool, card: Bool, sheet: Bool) -> EscapeTarget {
        if sheet { return .sheet }
        if locked { return .nothing }
        if panel { return .panel }
        if console { return .console }
        if card { return .card }
        return .player
    }

    /// The same key reported twice for one press (as a key press and as a
    /// key command) counts once: the second, from the other source within
    /// a twentieth of a second, is dropped. A held key's repeats come from
    /// one source and all count.
    struct Dedupe {
        private var last: (shortcut: PlayerShortcut, fromPress: Bool, time: Double)?

        mutating func shouldPerform(_ s: PlayerShortcut, fromPress: Bool, at time: Double) -> Bool {
            if let last, last.shortcut == s, last.fromPress != fromPress, time - last.time < 0.05 { return false }
            last = (s, fromPress, time)
            return true
        }
    }
}
