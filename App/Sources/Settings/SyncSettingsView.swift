import SwiftUI
import AuthenticationServices

/// Settings → Sync (1.26.0): connect Trakt, AniList and MyAnimeList, and
/// choose which of them get what you watch. Each needs a free app of your
/// own registered with the service (its Client ID): Folio has no server, so
/// it can't hold one for everyone.
struct SyncSettingsView: View {
    @ObservedObject private var center = SyncCenter.shared
    @Environment(\.webAuthenticationSession) private var webAuth
    @Environment(\.openURL) private var openURL
    @State private var traktSignIn = false
    @State private var busy: SyncService?
    @State private var message: String?
    @State private var importing = false

    var body: some View {
        Form {
            Section {
                Text("When you finish a film or an episode, Folio can mark it watched on these services. Trakt gets films and episodes; AniList and MyAnimeList get anime episodes, moving your progress forward. Nothing is sent until you connect a service.")
                    .font(.footnote).foregroundStyle(.secondary)
                if center.waiting > 0 {
                    Label("\(center.waiting) waiting to be sent", systemImage: "clock.arrow.circlepath")
                        .font(.footnote)
                }
            }
            ForEach(SyncService.allCases) { s in serviceSection(s) }
            if let message {
                Section { Text(message).font(.footnote) }
            }
        }
        .brandListBackground()
        .navigationTitle("Sync")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $traktSignIn) { TraktSignInView() }
    }

    @ViewBuilder
    private func serviceSection(_ s: SyncService) -> some View {
        Section {
            if center.isConnected(s) {
                let account = center.accounts[s] ?? ""
                LabeledContent("Account", value: account.isEmpty ? "Connected" : account)
                SyncEnabledToggle(service: s)
                if s == .trakt {
                    Button {
                        importing = true
                        Task { message = await center.importTraktWatchlist(); importing = false }
                    } label: {
                        Label(importing ? "Importing…" : "Import Trakt watchlist", systemImage: "square.and.arrow.down")
                    }
                    .disabled(importing)
                }
                if let last = center.lastResult[s] {
                    Text(last).font(.footnote).foregroundStyle(.secondary)
                }
                Button("Disconnect", role: .destructive) { center.disconnect(s) }
            } else {
                ClientIDField(service: s, busy: busy == s, blocked: busy != nil) { connect(s) }
            }
        } header: {
            Label(s.name, systemImage: s.symbol)
        } footer: {
            if !center.isConnected(s) { setupNote(s) }
        }
    }

    private func setupNote(_ s: SyncService) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch s {
            case .trakt:
                Text("Create an app at trakt.tv (Settings → Your API Apps) with the redirect URI \(s.redirectURI), then paste its Client ID and Client Secret here.")
            case .anilist:
                Text("Create a client at anilist.co (Settings → Developer) with the redirect URL \(s.redirectURI), then paste its ID here.")
            case .mal:
                Text("Create an API client at myanimelist.net (Account → API) of type \"other\" with the redirect URL \(s.redirectURI), then paste its Client ID here.")
            }
            if let u = s.developerURL {
                Button("Open \(s.name)'s developer page") { openURL(u) }.font(.footnote)
            }
        }
    }

    private func connect(_ s: SyncService) {
        message = nil
        switch s {
        case .trakt:
            traktSignIn = true
        case .anilist:
            guard let url = AniListClient.authorizeURL() else { return }
            busy = s
            Task {
                defer { busy = nil }
                do {
                    let back = try await webAuth.authenticate(using: url, callbackURLScheme: "folio")
                    guard var t = AniListClient.tokens(fromCallback: back) else { message = "AniList didn't send a sign-in back."; return }
                    t.user = await AniListClient.viewerName(token: t.access)
                    center.connected(.anilist, t)
                } catch {
                    if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin { message = "AniList: \(error.localizedDescription)" }
                }
            }
        case .mal:
            let verifier = MALClient.makeVerifier()
            let state = UUID().uuidString
            guard let url = MALClient.authorizeURL(verifier: verifier, state: state) else { return }
            busy = s
            Task {
                defer { busy = nil }
                do {
                    let back = try await webAuth.authenticate(using: url, callbackURLScheme: "folio")
                    let items = URLComponents(url: back, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    guard items.first(where: { $0.name == "state" })?.value == state,
                          let code = items.first(where: { $0.name == "code" })?.value else {
                        message = "MyAnimeList didn't send a sign-in back."
                        return
                    }
                    var t = try await MALClient.exchange(code: code, verifier: verifier)
                    t.user = await MALClient.userName(token: t.access)
                    center.connected(.mal, t)
                } catch {
                    if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin { message = "MyAnimeList: \(error.localizedDescription)" }
                }
            }
        }
    }
}
