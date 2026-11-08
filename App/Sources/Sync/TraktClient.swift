import Foundation

/// Trakt (1.26.0): films and episodes you finish go into your Trakt
/// history; the watchlist follows Folio's. Sign-in is Trakt's device flow:
/// a code you enter at trakt.tv/activate, so no web page has to come back
/// into the app. It needs your Trakt app's Client ID and Client Secret.
enum TraktClient {
    static let api = "https://api.trakt.tv"

    struct DeviceCode: Sendable {
        var deviceCode: String
        var userCode: String
        var verificationURL: URL
        var expires: Date
        var interval: TimeInterval
    }

    enum PollResult: Sendable { case pending, slowDown, done(SyncTokens), failed(String) }

    private static var clientID: String { SyncService.trakt.clientID }
    private static var secret: String { Keychain.get(SyncService.traktSecretAccount) ?? "" }

    private static func headers(_ token: String? = nil) -> [String: String] {
        var h = ["trakt-api-version": "2", "trakt-api-key": clientID]
        if let token { h["Authorization"] = "Bearer \(token)" }
        return h
    }

    // MARK: Sign-in

    static func deviceCode() async throws -> DeviceCode {
        let (data, status) = try await SyncHTTP.send(URL(string: "\(api)/oauth/device/code")!, method: "POST",
                                                     headers: headers(), json: ["client_id": clientID])
        guard status == 200, let o = SyncHTTP.object(data), let device = o["device_code"] as? String, let user = o["user_code"] as? String,
              let u = (o["verification_url"] as? String).flatMap(URL.init(string:)) else {
            throw SyncHTTP.Failure(status: status, body: String(decoding: data, as: UTF8.self))
        }
        let expiresIn = (o["expires_in"] as? NSNumber)?.doubleValue ?? 600
        let interval = (o["interval"] as? NSNumber)?.doubleValue ?? 5
        return DeviceCode(deviceCode: device, userCode: user, verificationURL: u, expires: Date().addingTimeInterval(expiresIn), interval: interval)
    }

    static func poll(_ code: DeviceCode) async -> PollResult {
        guard let (data, status) = try? await SyncHTTP.send(URL(string: "\(api)/oauth/device/token")!, method: "POST", headers: headers(),
                                                            json: ["code": code.deviceCode, "client_id": clientID, "client_secret": secret]) else {
            return .pending
        }
        switch status {
        case 200:
            guard var t = tokens(data) else { return .failed("Trakt's answer couldn't be read.") }
            t.user = await username(t.access)
            return .done(t)
        case 400: return .pending
        case 429: return .slowDown
        case 404: return .failed("The code wasn't accepted. Check the Client ID and Secret.")
        case 409: return .failed("That code was already used.")
        case 410: return .failed("The code expired. Try again.")
        case 418: return .failed("You declined on Trakt.")
        default: return .failed("Trakt answered HTTP \(status).")
        }
    }

    static func refresh(_ t: SyncTokens) async throws -> SyncTokens {
        guard let r = t.refresh else { throw SyncHTTP.Failure(status: 401, body: "no refresh token") }
        let (data, status) = try await SyncHTTP.send(URL(string: "\(api)/oauth/token")!, method: "POST", headers: headers(),
                                                     json: ["refresh_token": r, "client_id": clientID, "client_secret": secret,
                                                            "redirect_uri": SyncService.trakt.redirectURI, "grant_type": "refresh_token"])
        guard status == 200, var fresh = tokens(data) else { throw SyncHTTP.Failure(status: status, body: String(decoding: data, as: UTF8.self)) }
        fresh.user = t.user
        return fresh
    }

    private static func tokens(_ data: Data) -> SyncTokens? {
        guard let o = SyncHTTP.object(data), let access = o["access_token"] as? String else { return nil }
        let created = (o["created_at"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970
        let expiresIn = (o["expires_in"] as? NSNumber)?.doubleValue ?? 7_776_000
        return SyncTokens(access: access, refresh: o["refresh_token"] as? String, expires: Date(timeIntervalSince1970: created + expiresIn), user: nil)
    }

    private static func username(_ token: String) async -> String? {
        guard let (data, status) = try? await SyncHTTP.send(URL(string: "\(api)/users/settings")!, headers: headers(token)), status == 200,
              let user = SyncHTTP.object(data)?["user"] as? [String: Any] else { return nil }
        return user["username"] as? String
    }

    // MARK: History and watchlist

    /// Adds a finished film or episode to your history. False: nothing to send it by (no IMDb id).
    static func addToHistory(_ e: SyncEvent, token: String) async throws -> Bool {
        guard let imdb = e.imdb else { return false }
        let at = ISO8601DateFormatter().string(from: e.watchedAt)
        let body: [String: Any]
        if e.isMovie {
            body = ["movies": [["ids": ["imdb": imdb], "watched_at": at]]]
        } else {
            guard let s = e.season, let n = e.episode else { return false }
            body = ["shows": [["ids": ["imdb": imdb], "seasons": [["number": s, "episodes": [["number": n, "watched_at": at]]]]]]]
        }
        let (data, status) = try await SyncHTTP.send(URL(string: "\(api)/sync/history")!, method: "POST", headers: headers(token), json: body)
        guard status == 201 || status == 200 else { throw SyncHTTP.Failure(status: status, body: String(decoding: data, as: UTF8.self)) }
        return true
    }

    /// Adds a title to (or removes it from) your Trakt watchlist. Titles without an IMDb id are left out.
    static func watchlist(_ item: WatchlistItem, add: Bool, token: String) async throws {
        guard item.id.hasPrefix("tt") else { return }
        let key = item.isSeries ? "shows" : "movies"
        let url = URL(string: "\(api)/sync/watchlist\(add ? "" : "/remove")")!
        let (data, status) = try await SyncHTTP.send(url, method: "POST", headers: headers(token), json: [key: [["ids": ["imdb": item.id]]]])
        guard status == 201 || status == 200 else { throw SyncHTTP.Failure(status: status, body: String(decoding: data, as: UTF8.self)) }
    }

    /// Your Trakt watchlist, as tiles (pictures come from IMDb when the page opens).
    static func fetchWatchlist(token: String) async throws -> [MetaItem] {
        let (data, status) = try await SyncHTTP.send(URL(string: "\(api)/sync/watchlist?sort=added,desc")!, headers: headers(token))
        guard status == 200, let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw SyncHTTP.Failure(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return rows.compactMap { row in
            let type = row["type"] as? String
            guard type == "movie" || type == "show", let o = row[type!] as? [String: Any],
                  let ids = o["ids"] as? [String: Any], let imdb = ids["imdb"] as? String, imdb.hasPrefix("tt"),
                  let title = o["title"] as? String else { return nil }
            return MetaItem(id: imdb, type: type == "movie" ? "movie" : "series", name: title, poster: nil, description: nil,
                            releaseInfo: (o["year"] as? NSNumber).map { $0.stringValue }, imdbRating: nil, genres: nil)
        }
    }
}
