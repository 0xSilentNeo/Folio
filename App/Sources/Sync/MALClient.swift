import Foundation

/// MyAnimeList (1.26.0): like AniList, the number of episodes you've seen
/// goes up as you finish them, and the last one marks the anime completed.
/// Sign-in is MyAnimeList's OAuth with PKCE in a web sheet, back through
/// folio://auth/mal.
enum MALClient {
    private static let api = "https://api.myanimelist.net/v2"
    private static let tokenURL = URL(string: "https://myanimelist.net/v1/oauth2/token")!

    /// A PKCE verifier (MyAnimeList takes the "plain" method: the challenge is the verifier).
    static func makeVerifier() -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<96).map { _ in chars.randomElement()! })
    }

    static func authorizeURL(verifier: String, state: String) -> URL? {
        var c = URLComponents(string: "https://myanimelist.net/v1/oauth2/authorize")
        c?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: SyncService.mal.clientID),
            URLQueryItem(name: "code_challenge", value: verifier),
            URLQueryItem(name: "code_challenge_method", value: "plain"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "redirect_uri", value: SyncService.mal.redirectURI),
        ]
        return c?.url
    }

    static func exchange(code: String, verifier: String) async throws -> SyncTokens {
        try await token(["client_id": SyncService.mal.clientID, "grant_type": "authorization_code", "code": code,
                         "code_verifier": verifier, "redirect_uri": SyncService.mal.redirectURI])
    }

    static func refresh(_ t: SyncTokens) async throws -> SyncTokens {
        guard let r = t.refresh else { throw SyncHTTP.Failure(status: 401, body: "no refresh token") }
        var fresh = try await token(["client_id": SyncService.mal.clientID, "grant_type": "refresh_token", "refresh_token": r])
        fresh.user = t.user
        return fresh
    }

    private static func token(_ form: [String: String]) async throws -> SyncTokens {
        let (data, status) = try await SyncHTTP.send(tokenURL, method: "POST", form: form)
        guard status == 200, let o = SyncHTTP.object(data), let access = o["access_token"] as? String else {
            throw SyncHTTP.Failure(status: status, body: String(decoding: data, as: UTF8.self))
        }
        let expiresIn = (o["expires_in"] as? NSNumber)?.doubleValue ?? 2_678_400
        return SyncTokens(access: access, refresh: o["refresh_token"] as? String, expires: Date().addingTimeInterval(expiresIn), user: nil)
    }

    static func userName(token: String) async -> String? {
        guard let (data, status) = try? await SyncHTTP.send(URL(string: "\(api)/users/@me")!, headers: ["Authorization": "Bearer \(token)"]),
              status == 200 else { return nil }
        return SyncHTTP.object(data)?["name"] as? String
    }

    /// Episodes seen on an anime up to `episode` (when that's further than you are).
    static func progress(animeID: Int, episode: Int, token: String) async throws -> String {
        let auth = ["Authorization": "Bearer \(token)"]
        let (data, status) = try await SyncHTTP.send(URL(string: "\(api)/anime/\(animeID)?fields=num_episodes,my_list_status")!, headers: auth)
        guard status == 200, let o = SyncHTTP.object(data) else { throw SyncHTTP.Failure(status: status, body: String(decoding: data, as: UTF8.self)) }
        let total = (o["num_episodes"] as? NSNumber)?.intValue ?? 0
        let mine = o["my_list_status"] as? [String: Any]
        let have = (mine?["num_episodes_watched"] as? NSNumber)?.intValue ?? 0
        let current = mine?["status"] as? String
        if have >= episode && current != "plan_to_watch" { return "already at E\(have)" }
        let done = total > 0 && episode >= total
        let (d2, s2) = try await SyncHTTP.send(URL(string: "\(api)/anime/\(animeID)/my_list_status")!, method: "PATCH", headers: auth,
                                               form: ["status": done ? "completed" : "watching", "num_watched_episodes": String(episode)])
        guard s2 == 200 else { throw SyncHTTP.Failure(status: s2, body: String(decoding: d2, as: UTF8.self)) }
        return done ? "completed" : "E\(episode)\(total > 0 ? " of \(total)" : "")"
    }
}
