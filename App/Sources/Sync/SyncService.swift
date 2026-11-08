import Foundation

/// The services what you watch can go to (1.26.0). Each is off until you
/// connect it in Settings → Sync; nothing is sent before that.
enum SyncService: String, CaseIterable, Identifiable, Codable, Sendable {
    case trakt, anilist, mal
    var id: String { rawValue }

    var name: String {
        switch self {
        case .trakt: return "Trakt"
        case .anilist: return "AniList"
        case .mal: return "MyAnimeList"
        }
    }

    var symbol: String {
        switch self {
        case .trakt: return "checkmark.seal"
        case .anilist: return "a.circle"
        case .mal: return "m.circle"
        }
    }

    /// What it keeps: Trakt every film and episode, the other two anime only.
    var animeOnly: Bool { self != .trakt }

    var enabledKey: String {
        switch self {
        case .trakt: return SettingsKey.syncTrakt
        case .anilist: return SettingsKey.syncAniList
        case .mal: return SettingsKey.syncMAL
        }
    }

    var clientIDKey: String {
        switch self {
        case .trakt: return SettingsKey.syncTraktClientID
        case .anilist: return SettingsKey.syncAniListClientID
        case .mal: return SettingsKey.syncMALClientID
        }
    }

    /// A client id built into the app, for whoever builds it with their own
    /// registered app; empty: each person enters theirs in Settings → Sync.
    var builtInClientID: String { "" }

    /// The client id in use: yours from Settings, else the built-in one.
    var clientID: String {
        let own = UserDefaults.standard.string(forKey: clientIDKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return own.isEmpty ? builtInClientID : own
    }

    /// Where the service sends you back after you allow Folio (registered with your app there).
    var redirectURI: String {
        switch self {
        case .trakt: return "urn:ietf:wg:oauth:2.0:oob"
        case .anilist: return "folio://auth/anilist"
        case .mal: return "folio://auth/mal"
        }
    }

    /// Where to register an app for a client id.
    var developerURL: URL? {
        switch self {
        case .trakt: return URL(string: "https://trakt.tv/oauth/applications/new")
        case .anilist: return URL(string: "https://anilist.co/settings/developer")
        case .mal: return URL(string: "https://myanimelist.net/apiconfig/create")
        }
    }

    // Keychain accounts for the tokens.
    var accessTokenAccount: String { "sync.\(rawValue).access" }
    var refreshTokenAccount: String { "sync.\(rawValue).refresh" }
    var expiryAccount: String { "sync.\(rawValue).expiry" }
    var userAccount: String { "sync.\(rawValue).user" }
    /// Trakt's client secret (its device sign-in needs it), in the Keychain.
    static let traktSecretAccount = "sync.trakt.secret"
}
