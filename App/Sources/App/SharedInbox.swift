import Foundation

/// Videos sent to Folio from the share sheet (1.27.1): the extension leaves
/// them in the App Group's Share/Inbox; Folio moves each into its Media
/// folder (Files → On My iPhone → Folio → Media), where the library finds it,
/// and plays it from there.
enum SharedInbox {
    /// Moves a shared video into Media. Returns where it went, or nil when
    /// it isn't there any more.
    static func receive(_ link: SharedPlayLink) -> URL? {
        let fm = FileManager.default
        guard let src = link.fileURL, fm.fileExists(atPath: src.path) else { return nil }
        let media = MPVFiles.mediaDir
        try? fm.createDirectory(at: media, withIntermediateDirectories: true)
        let dest = unique(src.lastPathComponent, in: media)
        do {
            do { try fm.moveItem(at: src, to: dest) } catch { try fm.copyItem(at: src, to: dest) }
        } catch {
            dlog("open/error", "shared video not moved into Media: \(error.localizedDescription)")
            return nil
        }
        try? fm.removeItem(at: src.deletingLastPathComponent())
        dlog("open", "shared video saved to Media: \(dest.lastPathComponent)")
        return dest
    }

    /// "Film.mkv", or "Film 2.mkv" when there's one already.
    static func unique(_ name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var dest = dir.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return dest
    }

    /// Videos shared more than a day ago that Folio never took: removed
    /// (each can be gigabytes).
    static func cleanUp(olderThan age: TimeInterval = 86_400) {
        guard let inbox = SharedPlayLink.inbox,
              let dirs = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for d in dirs {
            let made = (try? d.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if Date().timeIntervalSince(made) > age {
                try? FileManager.default.removeItem(at: d)
                dlog("open", "removed a shared video Folio never took")
            }
        }
    }
}
