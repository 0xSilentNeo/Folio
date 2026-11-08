import Foundation

/// A service's sign-in, kept in the Keychain (1.26.0).
struct SyncTokens: Sendable {
    var access: String
    var refresh: String?
    var expires: Date?
    var user: String?

    var expired: Bool { expires.map { $0.timeIntervalSinceNow < 300 } ?? false }

    static func load(_ s: SyncService) -> SyncTokens? {
        guard let access = Keychain.get(s.accessTokenAccount), !access.isEmpty else { return nil }
        return SyncTokens(access: access, refresh: Keychain.get(s.refreshTokenAccount),
                          expires: Keychain.get(s.expiryAccount).flatMap(Double.init).map(Date.init(timeIntervalSince1970:)),
                          user: Keychain.get(s.userAccount))
    }

    func save(_ s: SyncService) {
        Keychain.set(access, for: s.accessTokenAccount)
        Keychain.set(refresh, for: s.refreshTokenAccount)
        Keychain.set(expires.map { String($0.timeIntervalSince1970) }, for: s.expiryAccount)
        Keychain.set(user, for: s.userAccount)
    }

    static func clear(_ s: SyncService) {
        for a in [s.accessTokenAccount, s.refreshTokenAccount, s.expiryAccount, s.userAccount] { Keychain.set(nil, for: a) }
    }
}
