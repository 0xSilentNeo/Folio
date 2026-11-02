import Foundation
import Security

enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "dev.silentneo.folio"

    static func set(_ value: String?, for account: String) {
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
