import SwiftUI

/// Adds or edits an SMB share, a Jellyfin server or a Plex server.
///
/// Test connection saves nothing (as WebDAV's form since 1.20.3): it uses
/// what's typed, and the Keychain is written by Save only. A Jellyfin
/// sign-in made by Test is kept in memory and used by Save if nothing
/// changed since, so the server isn't signed in to twice.
struct MediaServerEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var server: MediaServer
    /// The SMB password, Jellyfin password or Plex token, as typed.
    @State private var secret: String
    @State private var testing = false
    @State private var saving = false
    @State private var result: String?
    @State private var tested: (fields: String, session: JellyfinAPI.Session)?
    private let original: MediaServer?

    init(kind: MediaServer.Kind, server: MediaServer?) {
        let s = server ?? MediaServer(kind: kind)
        _server = State(initialValue: s)
        // Jellyfin's password isn't kept; the others show what's saved, as WebDAV's form does.
        _secret = State(initialValue: server.map { $0.kind == .smb ? $0.password ?? "" : $0.kind == .plex ? $0.token ?? "" : "" } ?? "")
        original = server
    }

    private var isNew: Bool { original == nil }
    private var kind: MediaServer.Kind { server.kind }

    private var valid: Bool {
        switch kind {
        case .smb: return server.smbHost != nil
        case .jellyfin: return server.baseURL != nil && !(server.username ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        case .plex: return server.baseURL != nil
        }
    }

    /// Jellyfin: another address or user than the saved sign-in's.
    private var accountChanged: Bool {
        guard let original else { return true }
        return original.baseURL != server.baseURL || (original.username ?? "") != (server.username ?? "")
    }

    private var fields: String { [server.address ?? "", server.username ?? "", secret].joined(separator: "\u{1}") }

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                loginSection
                Section {
                    Button { Task { await test() } } label: {
                        HStack { Text("Test connection"); Spacer(); if testing { ProgressView() } }
                    }
                    .disabled(!valid || testing || saving)
                    if let result { Text(result).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .brandListBackground()
            .navigationTitle(isNew ? "Add \(kind.title)" : "Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button(kind == .jellyfin && (accountChanged || !secret.isEmpty) ? "Sign In" : "Save") { Task { await save() } }
                            .disabled(!valid || testing)
                    }
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    @ViewBuilder private var serverSection: some View {
        Section {
            TextField("Name", text: $server.name)
            switch kind {
            case .smb:
                TextField("Host (nas.local or 192.168.1.20)", text: text(\.address))
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Share (optional)", text: text(\.share))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            case .jellyfin:
                TextField("URL (http://192.168.1.20:8096)", text: text(\.address))
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            case .plex:
                TextField("URL (http://192.168.1.20:32400)", text: text(\.address))
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        } header: { Text("Server") } footer: {
            switch kind {
            case .smb: Text("Without a share, Folio lists the host's shares.")
            case .jellyfin: Text("An address without http:// gets it, and port 8096 when none is given.")
            case .plex: Text("An address without http:// gets it, and port 32400 when none is given.")
            }
        }
    }

    @ViewBuilder private var loginSection: some View {
        switch kind {
        case .smb:
            Section {
                TextField("User", text: text(\.username))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password", text: $secret)
            } header: { Text("Login") } footer: {
                Text("Leave both empty for guest access. A domain goes before the user: DOMAIN\\user. The password is stored in the iOS Keychain.")
            }
        case .jellyfin:
            Section {
                TextField("User", text: text(\.username))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField(isNew ? "Password" : "Password (only to sign in again)", text: $secret)
            } header: { Text("Sign in") } footer: {
                Text("Folio signs in once and keeps the server's access token in the iOS Keychain. Your password isn't stored.")
            }
        case .plex:
            Section {
                SecureField("X-Plex-Token", text: $secret)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("Token") } footer: {
                Text("In Plex Web, open any film or episode and choose ⋯ → Get Info → View XML. The address of the page that opens ends in X-Plex-Token=…: copy what follows the = sign. The token is stored in the iOS Keychain. Signing in with a plex.tv account isn't supported yet.")
            }
        }
    }

    /// An optional text field of the server, as a plain text binding.
    private func text(_ path: WritableKeyPath<MediaServer, String?>) -> Binding<String> {
        Binding(get: { server[keyPath: path] ?? "" },
                set: { server[keyPath: path] = $0.isEmpty ? nil : $0 })
    }

    // MARK: Test and save

    private func test() async {
        testing = true
        defer { testing = false }
        result = nil
        do {
            result = try await check()
        } catch {
            result = ServerError.message(error, server: server.displayName).text
        }
    }

    /// Lists the start: the share (or the shares), the libraries. Writes nothing.
    private func check() async throws -> String {
        switch kind {
        case .smb:
            guard let host = server.smbHost else { throw SMBError.badAddress }
            // A client of its own with the typed login, not the server's shared one.
            let client = SMBClient(host: host, username: server.username ?? "", password: secret)
            let entries = try await client.list(server.smbStartPath)
            if server.smbShare == nil {
                let n = entries.filter { $0.kind == .share }.count
                return "Connected — \(n) share\(n == 1 ? "" : "s")."
            }
            return "Connected — \(entries.count) item\(entries.count == 1 ? "" : "s") in \(server.smbShare ?? "the share")."
        case .jellyfin:
            let session: JellyfinAPI.Session
            if secret.isEmpty, !accountChanged, let token = original?.token, let user = original?.userID {
                session = JellyfinAPI.Session(token: token, userID: user)
            } else {
                session = try await JellyfinClient.signIn(server: server, username: server.username ?? "", password: secret, device: JellyfinAPI.deviceModel)
                tested = (fields, session)
            }
            guard let client = JellyfinClient(server: server, session: session, device: JellyfinAPI.deviceModel) else { throw ServerError.badAddress }
            let n = try await client.children(of: nil).count
            let who = session.userName.map { "Signed in as \($0)" } ?? "Connected"
            return "\(who) — \(n) librar\(n == 1 ? "y" : "ies")."
        case .plex:
            let token = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return "Paste the server's X-Plex-Token first." }
            guard let client = PlexClient(server: server, token: token) else { throw ServerError.badAddress }
            let n = try await client.children(of: nil).count
            return "Connected — \(n) librar\(n == 1 ? "y" : "ies")."
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var s = server
        s.name = s.name.trimmingCharacters(in: .whitespaces)
        if s.name.isEmpty { s.name = s.host ?? kind.title }
        s.address = s.address?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .smb:
            s.password = secret.isEmpty ? nil : secret
        case .jellyfin:
            // Signed in already, same address and user, no new password: keep the token.
            if accountChanged || !secret.isEmpty || s.token == nil {
                do {
                    let session: JellyfinAPI.Session
                    if let t = tested, t.fields == fields { session = t.session } else {
                        session = try await JellyfinClient.signIn(server: s, username: s.username ?? "", password: secret, device: JellyfinAPI.deviceModel)
                    }
                    s.token = session.token
                    s.userID = session.userID
                } catch {
                    result = ServerError.message(error, server: s.displayName).text
                    return
                }
            }
        case .plex:
            let token = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { result = "Paste the server's X-Plex-Token to save."; return }
            s.token = token
        }
        MediaServerStore.shared.upsert(s)
        dismiss()
    }
}
