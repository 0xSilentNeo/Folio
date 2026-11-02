import Foundation

/// An SMB share, a Jellyfin server or a Plex server (1.20.3, 2 Nov), listed in
/// the Network tab under the WebDAV servers. Saved in a list of its own
/// (MediaServerStore), not WebDAV's ServerStore. Every field but the id, kind
/// and name is optional, so a list saved by a later version still reads.
///
/// Logins live in the Keychain, never in the saved list: the SMB password,
/// Jellyfin's access token and user id, the Plex token. Jellyfin's password
/// isn't kept at all: signing in gives a token.
struct MediaServer: Codable, Identifiable, Hashable {
    typealias Kind = ServerItemRef.Kind

    var id = UUID()
    var kind: Kind
    var name: String
    /// Jellyfin and Plex: the server's address ("http://192.168.1.20:8096").
    /// SMB: the host, with a port when it isn't 445 ("nas.local", "10.0.0.2:4450").
    var address: String?
    /// SMB: the share to open; none lists the host's shares.
    var share: String?
    /// SMB and Jellyfin: the user name ("DOMAIN\user" works for SMB).
    var username: String?

    init(kind: Kind, name: String = "", address: String? = nil, share: String? = nil, username: String? = nil) {
        self.kind = kind
        self.name = name
        self.address = address
        self.share = share
        self.username = username
    }

    var displayName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
        return host ?? kind.title
    }

    /// What the server list shows under the name.
    var detail: String {
        switch kind {
        case .smb:
            let h = smbHost ?? ""
            return smbShare.map { "\(h)/\($0)" } ?? h
        case .jellyfin, .plex:
            return baseURL.map { u in u.host.map { h in u.port.map { "\(h):\($0)" } ?? h } ?? u.absoluteString } ?? (address ?? "")
        }
    }

    var host: String? {
        switch kind {
        case .smb: return smbHost
        case .jellyfin, .plex: return baseURL?.host
        }
    }

    // MARK: Jellyfin and Plex

    /// The server's address as typed, made whole: "http://" when no scheme
    /// is given (servers on a home network rarely have HTTPS), the usual
    /// port when neither scheme nor port is, no trailing "/". A path stays
    /// (a server behind a proxy at https://host/jellyfin).
    var baseURL: URL? { Self.baseURL(address ?? "", defaultPort: kind.defaultPort) }

    static func baseURL(_ typed: String, defaultPort: Int?) -> URL? {
        var s = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let bare = !s.contains("://")
        if bare { s = "http://" + s }
        guard var c = URLComponents(string: s), let scheme = c.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = c.host, !host.isEmpty else { return nil }
        if bare, c.port == nil, let p = defaultPort { c.port = p }
        while c.path.hasSuffix("/") { c.path.removeLast() }
        c.query = nil
        c.fragment = nil
        return c.url
    }

    // MARK: SMB

    var smbHost: String? {
        let h = SMBURL.parseHost(address ?? "").host
        return h.isEmpty ? nil : h
    }

    /// The share: the field, else one typed after the host ("nas/Media").
    var smbShare: String? {
        let typed = (share ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/\\ "))
        if !typed.isEmpty { return typed }
        return SMBURL.parseHost(address ?? "").share
    }

    /// Where the SMB browser starts: the share, or "/" (the host's shares).
    var smbStartPath: String { smbShare.map { "/" + $0 } ?? "/" }

    // MARK: Keychain

    private func account(_ what: String) -> String { "\(kind.rawValue)-\(what)-\(id.uuidString)" }

    /// SMB: the password.
    var password: String? {
        get { Keychain.get(account("password")) }
        nonmutating set { Keychain.set(newValue, for: account("password")) }
    }

    /// Jellyfin: the access token from signing in. Plex: the X-Plex-Token.
    var token: String? {
        get { Keychain.get(account("token")) }
        nonmutating set { Keychain.set(newValue, for: account("token")) }
    }

    /// Jellyfin: the signed-in user's id.
    var userID: String? {
        get { Keychain.get(account("user")) }
        nonmutating set { Keychain.set(newValue, for: account("user")) }
    }

    func forgetLogin() {
        password = nil
        token = nil
        userID = nil
    }
}

/// A list that keeps the entries it can read: a server saved by a later
/// version (a kind this one doesn't know) is skipped, not the whole list.
struct LenientList<T: Decodable>: Decodable {
    var items: [T]

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [T] = []
        while !c.isAtEnd {
            if let v = try? c.decode(T.self) { out.append(v) } else { _ = try c.decode(Skip.self) }
        }
        items = out
    }

    /// Reads past any one value.
    private struct Skip: Decodable { init(from decoder: Decoder) throws {} }
}

@MainActor
final class MediaServerStore: ObservableObject {
    static let shared = MediaServerStore()
    private static let key = "mediaServers"

    @Published private(set) var servers: [MediaServer] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let list = try? JSONDecoder().decode(LenientList<MediaServer>.self, from: data) {
            servers = list.items
        }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(servers), forKey: Self.key)
    }

    func upsert(_ s: MediaServer) {
        if let i = servers.firstIndex(where: { $0.id == s.id }) { servers[i] = s } else { servers.append(s) }
        SMBClient.forget(s.id)
        save()
    }

    /// The server and its Keychain items. A Jellyfin server is told to end
    /// the session too, so its token stops working there as well.
    func remove(_ s: MediaServer) {
        if s.kind == .jellyfin, let client = JellyfinClient(server: s, device: JellyfinAPI.deviceModel) {
            Task { await client.signOut() }
        }
        s.forgetLogin()
        SMBClient.forget(s.id)
        servers.removeAll { $0.id == s.id }
        save()
    }

    func server(id: UUID) -> MediaServer? { servers.first { $0.id == id } }
}

extension ServerItemRef.Kind: Identifiable {
    var id: String { rawValue }

    var title: String {
        switch self {
        case .smb: return "SMB share"
        case .jellyfin: return "Jellyfin"
        case .plex: return "Plex"
        }
    }

    var icon: String {
        switch self {
        case .smb: return "server.rack"
        case .jellyfin: return "play.rectangle.on.rectangle"
        case .plex: return "play.square.stack"
        }
    }

    /// The port a bare address gets ("192.168.1.20" → :8096).
    var defaultPort: Int? {
        switch self {
        case .smb: return nil
        case .jellyfin: return 8096
        case .plex: return 32400
        }
    }
}
