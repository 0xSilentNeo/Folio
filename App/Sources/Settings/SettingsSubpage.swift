import Foundation

/// A page further into Settings (1.26.1), pushed by value on Home's stack
/// like the pages Settings' root opens: until then each was a
/// NavigationLink(destination:), outside the stack's path, the mix
/// navigation.md warns against.
enum SettingsSubpage: Hashable {
    case rememberedShows
    case audioLanguages, subtitleLanguages
    case scripts, shaders, scriptOptions, commands, playbackLog
    /// An mpv text file: its address, title, and whether it's code.
    case config(URL, String, Bool)
    case diagnostics
    case addons
    case syncService(SyncService)
    case notifyGroup(NotifyGroup)
    case notifySounds
    case notifySound(NotifyGroup)
    case notifyCity
    case notifySent
    case notifyTest

    /// For the log: never a file's whole address.
    var logName: String {
        switch self {
        case .config(let url, _, _): return "config(\(url.lastPathComponent))"
        case .syncService(let s): return "sync(\(s.rawValue))"
        case .notifyGroup(let g): return "notify(\(g.rawValue))"
        case .notifySound(let g): return "notifySound(\(g.rawValue))"
        default: return String(describing: self)
        }
    }
}
