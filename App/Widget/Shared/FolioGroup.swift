import Foundation

// Built into Folio, FolioWidget and FolioPlay (the share sheet's Play in
// Folio, 1.27.0). Foundation only.

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
