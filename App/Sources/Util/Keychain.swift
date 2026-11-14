import Foundation
import Security

enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "dev.silentneo.folio"

    /// What was read, kept in memory (1.30.4): a queue of 1,000 Plex items
    /// asked the Keychain twice per item on the main thread as the player
    /// opened (preparedForPlayback), a visible freeze.
    static let cache = SecretCache()

    static func set(_ value: String?, for account: String) {
        // Forgotten once the change is made, whatever its result (1.30.4):
        // the next read asks the Keychain again.
        defer { cache.forget(account) }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard let value, let data = value.data(using: .utf8) else {
            let status = SecItemDelete(base as CFDictionary)
            if status != errSecSuccess, status != errSecItemNotFound { dlog("app", "keychain: couldn't remove \(account) (OSStatus \(status))") }
            return
        }
        // Changed in place. It used to be deleted and added again, so an add
        // that failed (the phone locked during a background save) lost the
        // saved password with nothing in the log.
        var status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess { dlog("app", "keychain: couldn't save \(account) (OSStatus \(status))") }
    }

    static func get(_ account: String) -> String? {
        cache.value(for: account) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var out: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &out)
            if status == errSecItemNotFound { return .missing }
            guard status == errSecSuccess, let data = out as? Data, let s = String(data: data, encoding: .utf8) else { return .failed }
            return .found(s)
        }
    }
}

/// Keychain reads kept in memory by account (1.30.4), never written
/// anywhere. A value set or removed is forgotten; a read that failed (the
/// phone not yet unlocked since it started) isn't kept, so it's asked again.
final class SecretCache: @unchecked Sendable {
    enum Read { case found(String), missing, failed }

    private let lock = NSLock()
    /// A nil value: known to be missing.
    private var known: [String: String?] = [:]
    /// Bumped by every change: a read begun before one isn't kept.
    private var generation = 0

    func value(for account: String, read: () -> Read) -> String? {
        lock.lock()
        if let v = known[account] { lock.unlock(); return v }
        let started = generation
        lock.unlock()
        let r = read()
        lock.lock(); defer { lock.unlock() }
        let keep = started == generation
        switch r {
        case .found(let s):
            if keep { known.updateValue(s, forKey: account) }
            return s
        case .missing:
            if keep { known.updateValue(nil, forKey: account) }
            return nil
        case .failed:
            return nil
        }
    }

    func forget(_ account: String) {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        known.removeValue(forKey: account)
    }
}
