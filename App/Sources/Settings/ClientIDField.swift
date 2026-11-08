import SwiftUI

/// A sync service's Client ID (and Trakt's Client Secret, kept in the
/// Keychain), and its Connect button, ready once there's an id.
struct ClientIDField: View {
    let service: SyncService
    var busy = false
    var blocked = false
    let connect: () -> Void
    @AppStorage private var clientID: String
    @State private var secret = ""

    init(service: SyncService, busy: Bool = false, blocked: Bool = false, connect: @escaping () -> Void) {
        self.service = service
        self.busy = busy
        self.blocked = blocked
        self.connect = connect
        _clientID = AppStorage(wrappedValue: "", service.clientIDKey)
    }

    private var ready: Bool {
        !(clientID.trimmingCharacters(in: .whitespaces).isEmpty && service.builtInClientID.isEmpty)
            && (service != .trakt || !secret.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        LabeledContent("Client ID") {
            TextField("Client ID", text: $clientID, prompt: Text("Paste here"))
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                // The id in monospace, the prompt like the secret's.
                .font(clientID.isEmpty ? .body : .body.monospaced())
        }
        if service == .trakt {
            LabeledContent("Client Secret") {
                SecureField("Client Secret", text: $secret, prompt: Text("Paste here"))
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .onAppear { secret = Keychain.get(SyncService.traktSecretAccount) ?? "" }
            .onSubmit(saveSecret)
            .onDisappear(perform: saveSecret)
        }
        Button {
            saveSecret()
            connect()
        } label: {
            if busy { ProgressView() } else { Text("Connect \(service.name)") }
        }
        .disabled(!ready || blocked)
    }

    /// Into the Keychain when you're done with the field, or connect (1.26.1):
    /// until then every keystroke of a paste was a Keychain write.
    private func saveSecret() {
        guard service == .trakt else { return }
        let t = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t != (Keychain.get(SyncService.traktSecretAccount) ?? "") else { return }
        Keychain.set(t.isEmpty ? nil : t, for: SyncService.traktSecretAccount)
    }
}
