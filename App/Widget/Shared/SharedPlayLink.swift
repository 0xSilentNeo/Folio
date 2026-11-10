import Foundation

// Built into Folio and FolioPlay (1.27.0). Foundation only.

/// A link or video sent with the share sheet's Folio (1.27.0 as Play in
/// Folio, an action; 1.27.1 a share extension, in the app row with Folio's
/// icon, for videos from Files and Photos too). The extension leaves it in
/// the App Group and opens folio://shared?id=<id>; Folio takes it and plays
/// it. Only what's left this way plays without asking: any web page can
/// open folio://play, so that one asks first. If Folio couldn't be opened,
/// it waits, and Folio offers it when it's next opened.
struct SharedPlayLink: Codable, Equatable {
    var url: String
    var title: String?
    var at: Date
    var id: String
    /// A video file instead of a link: its path in the App Group, under
    /// Share/Inbox (1.27.1).
    var file: String?
    /// A video from Files on an install with no App Group (1.28.2): a
    /// bookmark to the file where it is, which iOS lent the extension in
    /// place. Small enough for the Keychain, where the link waits there.
    var bookmark: Data?

    init(url: String, title: String? = nil, at: Date, id: String, file: String? = nil, bookmark: Data? = nil) {
        self.url = url; self.title = title; self.at = at; self.id = id; self.file = file; self.bookmark = bookmark
    }

    /// Where shared videos wait for Folio.
    static var inbox: URL? {
        FolioGroup.container?.appendingPathComponent("Share/Inbox", isDirectory: true)
    }

    /// A shared file's place in the App Group.
    var fileURL: URL? { file.flatMap { f in FolioGroup.container?.appendingPathComponent(f) } }

    static let fileName = "play-link.json"

    /// The schemes Folio hands to mpv from outside: network streams, not
    /// mpv's own protocols (edl://, lavfi://) or a local path.
    static let playableSchemes: Set<String> = ["http", "https", "rtsp", "rtmp", "smb", "sftp", "ftp"]

    static func isPlayable(_ url: URL) -> Bool {
        guard let s = url.scheme?.lowercased(), playableSchemes.contains(s) else { return false }
        return url.host?.isEmpty == false
    }

    /// The first link in shared text (Messages, Notes), or the text itself
    /// when it's one.
    static func firstLink(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let u = URL(string: trimmed), isPlayable(u) { return u }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return detector.matches(in: trimmed, range: range).compactMap(\.url).first(where: isPlayable)
    }

    /// Left for Folio. False when there's nowhere to leave it.
    @discardableResult
    static func leave(_ link: SharedPlayLink) -> Bool {
        guard let store = WidgetStore.share(create: true), let data = try? JSONEncoder().encode(link) else { return false }
        return (try? store.write(data, fileName)) != nil
    }

    /// The waiting link, taken (it's gone after): the one `id` names, or any
    /// when `id` is nil; nil when there's none or it's older than `maxAge`.
    static func take(id: String?, maxAge: TimeInterval, now: Date = Date()) -> SharedPlayLink? {
        guard let store = WidgetStore.share(), let data = store.read(fileName),
              let link = try? JSONDecoder().decode(SharedPlayLink.self, from: data) else { return nil }
        if let id, link.id != id { return nil }
        store.remove(fileName)
        return accepts(link, maxAge: maxAge, now: now) ? link : nil
    }

    /// Fresh enough, and a link Folio plays (or a file, which the app checks).
    static func accepts(_ link: SharedPlayLink, maxAge: TimeInterval, now: Date) -> Bool {
        let age = now.timeIntervalSince(link.at)
        guard age >= -60, age <= maxAge else { return false }
        if let mark = link.bookmark { return !mark.isEmpty }
        if let file = link.file { return !file.isEmpty && !file.contains("..") }
        guard let u = URL(string: link.url) else { return false }
        return isPlayable(u)
    }

    /// What the extension opens.
    var openURL: URL? { URL(string: "folio://shared?id=\(id)") }

    /// Opened when a video can't be handed over at all (no App Group, and
    /// not a file iOS lends in place, as Photos' copies): Folio's Add files.
    static let importURL = URL(string: "folio://import?from=share")!
}
