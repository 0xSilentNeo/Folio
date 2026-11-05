import Foundation

// Built into both Folio and FolioWidget: what the app writes and the widget
// reads. Foundation only, nothing of the app's (an extension can't use it).

/// The App Group Folio shares with its widget (1.20.3 (2 Nov)). The widget
/// runs in its own process and can't see the app's files, so the app copies
/// what the widget shows into the group's container.
///
/// Sideloaded by a tool that didn't register the group there's no
/// container: the app carries on as before and the widget asks you to open
/// Folio.
enum FolioGroup {
    static let id = "group.dev.silentneo.folio"

    /// The group as installed. A sideloading tool re-signs Folio with its own
    /// team and may rename the group to one that team can have (AltStore and
    /// SideStore list the new names under ALTAppGroups in Info.plist), so
    /// those are tried first: the bundle's own, then, in the widget, its
    /// app's. Nil when none was granted.
    static let installedID: String? = {
        var bundles = [Bundle.main]
        if Bundle.main.bundleURL.pathExtension == "appex",
           let app = Bundle(url: Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()) {
            bundles.append(app)
        }
        let renamed = bundles.flatMap { ($0.object(forInfoDictionaryKey: "ALTAppGroups") as? [String]) ?? [] }
        // The app's profile first in both processes, so app and widget pick the same group.
        let fromProfiles = (bundles.dropFirst() + [Bundle.main]).flatMap(profileGroups)
        return (renamed + [id] + fromProfiles).first { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil }
    }()

    /// The App Groups in the signing profile (embedded.mobileprovision's
    /// entitlements), 1.22.2. A tool that signs with a certificate of its own
    /// (KSign with a bought one, 4 Nov) gives Folio its profile's groups,
    /// under names Folio can't know in advance. Empty without a profile
    /// (TrollStore, the simulator).
    static func profileGroups(_ bundle: Bundle) -> [String] {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return [] }
        return profileGroups(fromProfile: data)
    }

    /// The groups out of a profile's bytes: a signed plist, whose XML sits in it as text.
    static func profileGroups(fromProfile data: Data) -> [String] {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return [] }
        return (entitlements["com.apple.security.application-groups"] as? [String]) ?? []
    }

    /// For the log: which group is used, or why none is.
    static var status: String {
        let listed = profileGroups(Bundle.main)
        if let installedID { return "App Group \(installedID)" + (installedID == id ? "" : " (the signing tool's name for it)") }
        if listed.isEmpty { return "no App Group container: \(id) not granted, and the signing profile lists no App Group" }
        return "no App Group container: \(id) not granted, and none of the signing profile's \(listed.count) group(s) has one (\(listed.joined(separator: ", ")))"
    }

    static var container: URL? {
        installedID.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }
}

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
    }

    var items: [Item]

    /// The medium widget shows three; one more for the next size up.
    static let limit = 4
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

    static func id(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "folio", url.host?.lowercased() == "continue",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = comps.queryItems?.first(where: { $0.name == "id" })?.value, !id.isEmpty else { return nil }
        return id
    }
}
