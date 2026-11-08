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
                .font(.body.monospaced())
        }
        if service == .trakt {
            LabeledContent("Client Secret") {
                SecureField("Client Secret", text: $secret, prompt: Text("Paste here"))
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .onAppear { secret = Keychain.get(SyncService.traktSecretAccount) ?? "" }
            .onChange(of: secret) { _, v in
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                Keychain.set(t.isEmpty ? nil : t, for: SyncService.traktSecretAccount)
            }
        }
        Button(action: connect) {
            if busy { ProgressView() } else { Text("Connect \(service.name)") }
        }
        .disabled(!ready || blocked)
    }
}
