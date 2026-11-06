import Foundation
import Security

// Built into both Folio and FolioWidget (1.23.0): where the app leaves its
// widgets' snapshots and pictures, and where the widgets read them.

/// The widgets' files: in the App Group's container when the install has
/// one; else as small Keychain items in the app's own Keychain group, which
/// the widget can read when the signing lets the app and its widget share
/// Keychain items (a profile's "TEAM.*" Keychain groups). Installs signed
/// with a bought certificate get no App Group (the 4 Nov and 5 Nov reports:
/// "the signing profile lists no App Group"), so until 1.23.0 their widgets
/// only ever said "Open Folio".
enum WidgetStore: Sendable {
    case folder(URL)
    /// `group` nil: the process's default Keychain group (1.23.1).
    case keychain(group: String?, area: String)

    /// Continue Watching's files ("Widget").
    static func continueWatching(create: Bool = false) -> WidgetStore? { store(area: "Widget", create: create) }
    /// The Airing widget's files ("Airing").
    static func airing(create: Bool = false) -> WidgetStore? { store(area: "Airing", create: create) }
    /// The 1.24.0 widgets' files ("Glance"): downloads, your week, new on
    /// your servers, a pick for tonight (GlanceSnapshot).
    static func glance(create: Bool = false) -> WidgetStore? { store(area: "Glance", create: create) }

    private static func store(area: String, create: Bool) -> WidgetStore? {
        if let container = FolioGroup.container {
            let dir = container.appendingPathComponent(area, isDirectory: true)
            if create {
                do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return nil }
            }
            return .folder(dir)
        }
        // The default Keychain group, named by no one: a signing tool built on
        // zsign (KSign) gives the app and its widget the profile's very same
        // entitlements, so their default group is the same (zsign copies the
        // profile's Entitlements into every binary: openssl.cpp, archo.cpp).
        // 1.23.0 named the group "TEAM.<bundle id>", which such a profile
        // doesn't grant: -34018 on every write (5 Nov report).
        return .keychain(group: nil, area: area)
    }

    var isKeychain: Bool { if case .keychain = self { return true } else { return false } }

    func read(_ name: String) -> Data? {
        switch self {
        case .folder(let dir): return try? Data(contentsOf: dir.appendingPathComponent(name))
        case .keychain(let group, let area): return KeychainShare.read(group: group, account: area + "/" + name).data
        }
    }

    func exists(_ name: String) -> Bool {
        switch self {
        case .folder(let dir): return FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
        case .keychain(let group, let area): return KeychainShare.exists(group: group, account: area + "/" + name)
        }
    }

    func write(_ data: Data, _ name: String) throws {
        switch self {
        case .folder(let dir):
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
        case .keychain(let group, let area):
            let status = KeychainShare.write(data, group: group, account: area + "/" + name)
            guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        }
    }

    func names() -> [String] {
        switch self {
        case .folder(let dir): return (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        case .keychain(let group, let area):
            let prefix = area + "/"
            return KeychainShare.accounts(group: group).filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        }
    }

    func remove(_ name: String) {
        switch self {
        case .folder(let dir): try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        case .keychain(let group, let area): KeychainShare.remove(group: group, account: area + "/" + name)
        }
    }
}

/// The Keychain group the app and its widget can both reach without an
/// App Group: the app's own ("TEAMID.<the app's bundle id>"), which the
/// widget can read when its signature allows its team's groups.
enum KeychainShare {
    static let service = "folio.widget-files"

    /// The signing team: the profile's TeamIdentifier, else the prefix of
    /// this process's own Keychain group (a probe item). Nil in the
    /// simulator and for installs with no team.
    static let team: String? = profileTeam() ?? probedTeam()

    /// The app's bundle id, in the app and in its widget.
    static var appBundleID: String? {
        let main = Bundle.main
        if main.bundleURL.pathExtension == "appex",
           let app = Bundle(url: main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()) {
            return app.bundleIdentifier
        }
        return main.bundleIdentifier
    }

    static var group: String? {
        guard let team, let app = appBundleID else { return nil }
        return team + "." + app
    }

    /// A team id: ten capital letters and digits.
    static func isTeam(_ s: String) -> Bool {
        s.count == 10 && s.allSatisfy { ($0.isASCII && $0.isUppercase) || $0.isNumber }
    }

    private static func profileTeam() -> String? {
        for bundle in [Bundle.main] + appBundle() {
            guard let plist = profile(bundle) else { continue }
            if let t = (plist["TeamIdentifier"] as? [String])?.first(where: isTeam) { return t }
        }
        return nil
    }

    private static func appBundle() -> [Bundle] {
        guard Bundle.main.bundleURL.pathExtension == "appex",
              let app = Bundle(url: Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()) else { return [] }
        return [app]
    }

    /// The signing profile as a dictionary (embedded.mobileprovision is a
    /// signed plist with its XML inside).
    static func profile(_ bundle: Bundle) -> [String: Any]? {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any]
    }

    /// For the log: the Keychain groups the profile allows ("ABCDE12345.*").
    static var profileKeychainGroups: [String] {
        ((profile(Bundle.main)?["Entitlements"] as? [String: Any])?["keychain-access-groups"] as? [String]) ?? []
    }

    private static func probedTeam() -> String? {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "folio.team-probe",
                                   kSecAttrAccount as String: "probe"]
        var out: CFTypeRef?
        var query = base
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = Data()
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecReturnAttributes as String] = true
            status = SecItemAdd(add as CFDictionary, &out)
        }
        guard status == errSecSuccess, let attrs = out as? [String: Any],
              let group = attrs[kSecAttrAccessGroup as String] as? String,
              let first = group.split(separator: ".").first.map(String.init), isTeam(first) else { return nil }
        return first
    }

    private static func query(group: String?, account: String? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service]
        if let group { q[kSecAttrAccessGroup as String] = group }
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    static func read(group: String?, account: String) -> (data: Data?, status: OSStatus) {
        var q = query(group: group, account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        return (status == errSecSuccess ? out as? Data : nil, status)
    }

    static func exists(group: String?, account: String) -> Bool {
        var q = query(group: group, account: account)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func write(_ data: Data, group: String?, account: String) -> OSStatus {
        let q = query(group: group, account: account)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil)
    }

    static func accounts(group: String?) -> [String] {
        var q = query(group: group)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    static func remove(group: String?, account: String) {
        SecItemDelete(query(group: group, account: account) as CFDictionary)
    }

    // MARK: Whether the widget can read them

    /// The widget writes when it last read the app's files (and how), so the
    /// app's log can say whether sharing works on this install.
    static let seenAccount = "seen"

    /// The default group as this process has it (a probe item's group), for
    /// the log: the app's and the widget's must be the same for sharing.
    static let defaultGroup: String? = probedGroup()

    static func widgetSaw(_ what: String) {
        let line = ISO8601DateFormatter().string(from: Date()) + " " + what + " (the widget's Keychain group: " + (defaultGroup ?? "?") + ")"
        write(Data(line.utf8), group: nil, account: seenAccount)
    }

    /// What the widget wrote, if it reached the same group.
    static func lastSeen() -> String? {
        guard let data = read(group: nil, account: seenAccount).data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether this process may use its Keychain at all. errSecMissingEntitlement: no.
    static func reachable() -> OSStatus? {
        read(group: nil, account: seenAccount).status
    }

    private static func probedGroup() -> String? {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "folio.team-probe",
                                   kSecAttrAccount as String: "probe"]
        var out: CFTypeRef?
        var query = base
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = Data()
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecReturnAttributes as String] = true
            status = SecItemAdd(add as CFDictionary, &out)
        }
        guard status == errSecSuccess, let attrs = out as? [String: Any] else { return "status \(status)" }
        return attrs[kSecAttrAccessGroup as String] as? String
    }
}
