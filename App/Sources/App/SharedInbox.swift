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
        // Only a file the extension left in Share/Inbox/<id>/ (1.30.2): the
        // path comes from a file any app in the group can write, and its
        // folder is removed below.
        guard let inbox = SharedPlayLink.inbox, isInside(src, inbox: inbox) else {
            dlog("open/warn", "shared video: its path isn't in the share inbox, left alone")
            return nil
        }
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

    /// Whether `file` is in a folder of its own under `inbox`
    /// (Share/Inbox/<id>/<name>), by path components, once "." and ".." are
    /// worked out (1.30.2).
    static func isInside(_ file: URL, inbox: URL) -> Bool {
        // (Without the "/" a folder's address may end in.)
        let f = file.standardizedFileURL.pathComponents.filter { $0 != "/" }
        let b = inbox.standardizedFileURL.pathComponents.filter { $0 != "/" }
        return f.count >= b.count + 2 && Array(f.prefix(b.count)) == b
    }

    /// A file the extension bookmarked where it is (1.28.2), if it opens
    /// here: a bookmark carries the access iOS lent the extension, which
    /// iOS may or may not honour in another app.
    static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            dlog("open/warn", "shared video: its bookmark doesn't resolve here")
            return nil
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let readable = FileManager.default.isReadableFile(atPath: url.path)
        dlog("open", "shared video by bookmark: \(url.lastPathComponent), access \(scoped ? "lent" : "not lent"), \(readable ? "readable" : "not readable")\(stale ? ", stale" : "")")
        return scoped || readable ? url : nil
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
