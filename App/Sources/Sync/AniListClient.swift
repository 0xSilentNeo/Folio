import Foundation

/// AniList (1.26.0): an anime episode you finish moves your progress on
/// it, never back (an earlier episode watched again changes nothing), and
/// the last one marks it completed. Sign-in is AniList's implicit grant in
/// a web sheet, back through folio://auth/anilist.
enum AniListClient {
    private static let graphQL = URL(string: "https://graphql.anilist.co")!

    static func authorizeURL() -> URL? {
        var c = URLComponents(string: "https://anilist.co/api/v2/oauth/authorize")
        c?.queryItems = [URLQueryItem(name: "client_id", value: SyncService.anilist.clientID),
                         URLQueryItem(name: "response_type", value: "token")]
        return c?.url
    }

    /// The token in the address AniList sent you back to ("…#access_token=…&expires_in=…").
    static func tokens(fromCallback url: URL) -> SyncTokens? {
        let fragment = url.fragment ?? URLComponents(url: url, resolvingAgainstBaseURL: false)?.query ?? ""
        var fields: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { fields[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
        }
        guard let access = fields["access_token"], !access.isEmpty else { return nil }
        let expires = fields["expires_in"].flatMap(Double.init).map { Date().addingTimeInterval($0) }
        return SyncTokens(access: access, refresh: nil, expires: expires, user: nil)
    }

    private static func query(_ q: String, _ vars: [String: Any] = [:], token: String) async throws -> [String: Any] {
        let (data, status) = try await SyncHTTP.send(graphQL, method: "POST",
                                                     headers: ["Authorization": "Bearer \(token)", "Accept": "application/json"],
                                                     json: ["query": q, "variables": vars])
        guard status == 200, let d = SyncHTTP.object(data)?["data"] as? [String: Any] else {
            throw SyncHTTP.Failure(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return d
    }

    static func viewerName(token: String) async -> String? {
        ((try? await query("query { Viewer { name } }", token: token))?["Viewer"] as? [String: Any])?["name"] as? String
    }

    /// Progress on an anime to `episode` (when that's further than you are).
    /// The outcome for the log: "E5 of 12", "already at E7", "completed".
    static func progress(mediaID: Int, episode: Int, token: String) async throws -> String {
        let read = try await query("query($id:Int){ Media(id:$id){ episodes mediaListEntry { progress status } } }", ["id": mediaID], token: token)
        let media = read["Media"] as? [String: Any]
        let total = (media?["episodes"] as? NSNumber)?.intValue
        let entry = media?["mediaListEntry"] as? [String: Any]
        let have = (entry?["progress"] as? NSNumber)?.intValue ?? 0
        let status = entry?["status"] as? String
        if have >= episode && status != "PLANNING" { return "already at E\(have)" }
        let done = total.map { episode >= $0 } ?? false
        let newStatus = done ? "COMPLETED" : (status == "REPEATING" ? "REPEATING" : "CURRENT")
        _ = try await query("mutation($m:Int,$p:Int,$s:MediaListStatus){ SaveMediaListEntry(mediaId:$m, progress:$p, status:$s){ id } }",
                            ["m": mediaID, "p": episode, "s": newStatus], token: token)
        return done ? "completed" : "E\(episode)\(total.map { " of \($0)" } ?? "")"
    }
}
