import SwiftUI

/// Trakt's device sign-in (1.26.0): a code to enter at trakt.tv/activate,
/// while Folio waits for Trakt to say you allowed it.
struct TraktSignInView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var code: TraktClient.DeviceCode?
    @State private var problem: String?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                if let code {
                    Text("Enter this code at \(code.verificationURL.host() ?? "trakt.tv")/activate")
                        .font(.headline).multilineTextAlignment(.center)
                    Text(code.userCode)
                        .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                        .textSelection(.enabled)
                        .accessibilityLabel("Code \(code.userCode.map(String.init).joined(separator: " "))")
                    HStack(spacing: 12) {
                        Button(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc") {
                            UIPasteboard.general.string = code.userCode
                            copied = true
                        }
                        .buttonStyle(.bordered)
                        Button("Open Trakt", systemImage: "safari") { openURL(code.verificationURL) }
                            .buttonStyle(.borderedProminent)
                    }
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Waiting for you to allow Folio…").font(.footnote).foregroundStyle(.secondary)
                    }
                } else if let problem {
                    ContentUnavailableView("Couldn't sign in", systemImage: "exclamationmark.triangle", description: Text(problem))
                } else {
                    ProgressView("Asking Trakt for a code…")
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Connect Trakt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .task { await signIn() }
    }

    private func signIn() async {
        do {
            let c = try await TraktClient.deviceCode()
            code = c
            var interval = c.interval
            while !Task.isCancelled, Date() < c.expires {
                try? await Task.sleep(for: .seconds(interval))
                switch await TraktClient.poll(c) {
                case .pending: continue
                case .slowDown: interval += 1
                case .done(let t):
                    SyncCenter.shared.connected(.trakt, t)
                    dismiss()
                    return
                case .failed(let why):
                    code = nil
                    problem = why
                    return
                }
            }
            if !Task.isCancelled { code = nil; problem = "The code expired. Close this and try again." }
        } catch {
            problem = "Trakt didn't give a code (\(error.localizedDescription)). Check the Client ID."
        }
    }
}
