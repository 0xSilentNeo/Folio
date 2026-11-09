import Foundation

// Built into both Folio and FolioWidget: what the app writes and the widget
// reads. Foundation only, nothing of the app's (an extension can't use it).

/// The top of Home's Continue Watching row, as the widget shows it.
struct ContinueSnapshot: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        /// The history entry's id: what folio://continue?id= plays.
        var id: String
        var title: String
        /// "S1 · E24 · episode title" for an episode, as Home's card has it
        /// (HeroCard.line); a film's synopsis; or nothing.
        var line: String?
        var progress: Double
        /// Seconds left.
        var remaining: Double
        /// A picture's file name next to the snapshot, if there is one.
        var picture: String?
        /// 1.24.0, for the redesigned widgets (nil in older snapshots):
        /// "S2 · E3" (nil for a film), the episode's title, the whole length
        /// in seconds, the next episode's number when Folio knows it ("E6",
        /// "S3 · E1"), a portrait poster's file name, and the year of a film.
        var episode: String? = nil
        var episodeTitle: String? = nil
        var duration: Double? = nil
        var next: String? = nil
        var poster: String? = nil
        var year: String? = nil

        var isFilm: Bool { episode == nil }
    }

    var items: [Item]

    /// The poster shelf shows six (1.24.0; four until then).
    static let limit = 6
    /// The widget's kind (WidgetKit), the same in the app and the extension.
    static let widgetKind = "ContinueWatching"
    /// Pictures are kept this big on their long side: about a small widget's
    /// width at 3x. WidgetKit refuses to draw a widget whose pictures are
    /// much bigger than the widget itself.
    static let picturePixels: CGFloat = 540

    private static let fileName = "continue.json"

    /// `Widget/` in the group's container, where the snapshot and its
    /// pictures live; nil without the group. `create`: made if missing.
    static func directory(in container: URL? = FolioGroup.container, create: Bool = false) -> URL? {
        guard let container else { return nil }
        let dir = container.appendingPathComponent("Widget", isDirectory: true)
        if create {
            do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return nil }
        }
        return dir
    }

    /// The last snapshot written; nil when there is none (the app hasn't run
    /// since it was installed or updated) or no group.
    static func read(from dir: URL?) -> ContinueSnapshot? {
        guard let dir, let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(ContinueSnapshot.self, from: data)
    }

    func write(to dir: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// The same through WidgetStore (1.23.0): the App Group's folder, or the
    /// Keychain when the install has no group.
    static func read(from store: WidgetStore?) -> ContinueSnapshot? {
        guard let data = store?.read(fileName) else { return nil }
        return try? JSONDecoder().decode(ContinueSnapshot.self, from: data)
    }

    func write(to store: WidgetStore) throws {
        try store.write(try JSONEncoder().encode(self), Self.fileName)
    }
}

extension ContinueSnapshot.Item {
    /// "9m", "1h 12m": the large widget's column.
    var shortRemaining: String {
        let minutes = Int((remaining / 60).rounded(.up))
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// "S2 · E3 · 18 min left", or a film's "1 h 5 min left".
    var placeAndRemaining: String {
        [episode, remainingText].compactMap { $0 }.joined(separator: " · ")
    }

    /// "24 min left", "1 h 5 min left". In minutes, not Home's "23:41 left":
    /// a widget is a still picture and a ticking-looking time would be wrong
    /// a minute later.
    var remainingText: String {
        let minutes = Int((remaining / 60).rounded(.up))
        if minutes < 1 { return "Almost done" }
        if minutes < 60 { return "\(minutes) min left" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h left" : "\(h) h \(m) min left"
    }
}

/// folio://continue?id=<history id>: the widget's link to an entry. A
/// history id is a file path or a stream's URL (with its own ?, & and =),
/// so everything but letters, digits and -._~ is percent-encoded.
enum ContinueLink {
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func url(id: String) -> URL {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        return URL(string: "folio://continue?id=" + encoded) ?? URL(string: "folio://continue")!
    }

    /// The episode after the entry, from its start (1.24.0): the Episode
    /// widget's second button.
    static func nextURL(id: String) -> URL {
        URL(string: url(id: id).absoluteString + "&next=1") ?? url(id: id)
    }

    static func wantsNext(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "next" && $0.value == "1" } ?? false
    }

    static func id(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "folio", url.host?.lowercased() == "continue",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = comps.queryItems?.first(where: { $0.name == "id" })?.value, !id.isEmpty else { return nil }
        return id
    }
}
