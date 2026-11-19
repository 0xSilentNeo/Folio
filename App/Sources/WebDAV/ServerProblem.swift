import SwiftUI

/// What went wrong reaching a file or folder on a server, said plainly
/// (1.23.0). Until then a file Real-Debrid had removed only gave the player's
/// "Playback failed: loading failed", and a folder page an orange line.
struct ServerProblem: Equatable {
    enum Kind: Equatable {
        /// 404 or 410: not there any more (Real-Debrid: the torrent was removed).
        case gone
        /// 401 or 403: the login was refused.
        case refused
        /// 5xx or 429: the server is there but failing.
        case serverError(Int)
        case offline
        /// No answer: a timeout, the host not found, the connection refused.
        case unreachable
        /// The server sends the file: it's the file itself that didn't play.
        case fileItself
        /// A stream that ended well before its length (the connection dropped).
        case stoppedEarly
        case other
    }

    let kind: Kind
    let title: String
    let detail: String
    let icon: String

    /// Worth trying again as it is (not a removed file or a refused login).
    var retryable: Bool {
        switch kind {
        case .gone, .refused: return false
        default: return true
        }
    }

    /// From what the server answered (`status`) or the error reaching it.
    /// `folder`: a folder page, not a file. `reason`: mpv's own words, for a
    /// file the server does send. `afterRedirect`: the answer came from a
    /// host the server sent Folio on to (a debrid service's download host),
    /// not from the server itself.
    static func classify(status: Int?, error: Error?, server: String, realDebrid: Bool,
                         folder: Bool = false, reason: String? = nil, afterRedirect: Bool = false) -> ServerProblem {
        let thing = folder ? (realDebrid ? "release" : "folder") : "file"
        if let status {
            switch status {
            case 404, 410:
                if realDebrid {
                    return ServerProblem(kind: .gone, title: "Real-Debrid removed this \(thing)",
                                         detail: "It's no longer in your Real-Debrid account: the torrent was deleted, or Real-Debrid took it down. Add it again on Real-Debrid to watch it.",
                                         icon: "bolt.horizontal.circle")
                }
                return ServerProblem(kind: .gone, title: "This \(thing) isn't on \(server) any more",
                                     detail: "It was moved, renamed or deleted on the server.", icon: "questionmark.folder")
            case 401, 403:
                return ServerProblem(kind: .refused, title: "\(server) refused the login",
                                     detail: realDebrid ? "Use the WebDAV password from real-debrid.com/account, not your login password. Change it in Network → \(server)."
                                                        : "Check the user name and password in Network → \(server).",
                                     icon: "lock.trianglebadge.exclamationmark")
            case 429:
                return ServerProblem(kind: .serverError(429), title: "\(server) asks Folio to slow down",
                                     detail: "Too many requests in a short time. Try again in a minute.", icon: "hourglass")
            case 500...599:
                // One of the hosts the server hands its files out from
                // (0.90.0), not the server: the next try is sent to another.
                // 18 Nov log: a Real-Debrid download host answered 503, the
                // card said "Try again in a few minutes", and a try at once
                // played from another host.
                if afterRedirect {
                    return ServerProblem(kind: .serverError(status), title: "One of \(server)'s download hosts didn't answer",
                                         detail: "It answered with error \(status). Trying again usually works: each try is sent to another host.",
                                         icon: "exclamationmark.icloud")
                }
                return ServerProblem(kind: .serverError(status), title: "\(server) is having trouble",
                                     detail: "It answered with error \(status). Try again in a few minutes.", icon: "exclamationmark.icloud")
            case 200...299:
                let why = reason.map { " (\($0))" } ?? ""
                return ServerProblem(kind: .fileItself, title: "Folio couldn't play this file",
                                     detail: "\(server) sends it, but it couldn't be opened\(why). It may be damaged, or in a format Folio can't play.",
                                     icon: "film.stack")
            default:
                return ServerProblem(kind: .other, title: "\(server) answered with error \(status)",
                                     detail: "Try again, or open the \(thing) from Network.", icon: "exclamationmark.triangle")
            }
        }
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                return ServerProblem(kind: .offline, title: "You're offline",
                                     detail: "Connect to the internet, then try again.", icon: "wifi.slash")
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost, .secureConnectionFailed:
                return ServerProblem(kind: .unreachable, title: "Can't reach \(server)",
                                     detail: "It didn't answer. Check your connection, or try again later.", icon: "wifi.exclamationmark")
            default: break
            }
        }
        if let e = error as? WebDAVError {
            switch e {
            case .unauthorized: return classify(status: 401, error: nil, server: server, realDebrid: realDebrid, folder: folder)
            case .http(let code): return classify(status: code, error: nil, server: server, realDebrid: realDebrid, folder: folder)
            default: break
            }
        }
        return ServerProblem(kind: .other, title: folder ? "Couldn't open this folder" : "Couldn't play this file",
                             detail: reason ?? error?.localizedDescription ?? "Something went wrong reaching \(server).",
                             icon: "exclamationmark.triangle")
    }

    /// Asks the server for the file's first byte with the player's headers:
    /// its answer says whether the file is there (8 s at most), and whether
    /// it came from another host than the one asked (0.90.0, `redirected`).
    /// `retryAfter`: the answer's Retry-After, in seconds.
    static func probe(_ url: URL, headers: [String: String]) async -> (status: Int?, error: Error?, redirected: Bool, retryAfter: Double?) {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        req.httpMethod = "GET"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(for: req)
            let from = response.url?.host
            let http = response as? HTTPURLResponse
            return (http?.statusCode, nil, from != nil && from != url.host, LinkWarmer.retryAfter(http?.value(forHTTPHeaderField: "Retry-After")))
        } catch {
            return (nil, error, false, nil)
        }
    }
}

/// A problem, in Folio's style: the picture in a soft circle, what happened,
/// why, and what you can do. `onVideo`: over the player (white on glass).
struct ProblemCard: View {
    struct Action: Identifiable {
        let title: String
        var primary = false
        var role: ButtonRole? = nil
        let run: () -> Void
        var id: String { title }
    }

    let problem: ServerProblem
    var onVideo = false
    var checking = false
    let actions: [Action]

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(onVideo ? Color.white.opacity(0.14) : Theme.accentSoft).frame(width: 64, height: 64)
                if checking {
                    FolioSpinner(tint: onVideo ? .white : Theme.accent)
                } else {
                    Image(systemName: problem.icon).font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(onVideo ? .white : Theme.accent)
                }
            }
            .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(checking ? "Checking what went wrong…" : problem.title)
                    .font(.headline).multilineTextAlignment(.center)
                if !checking {
                    Text(problem.detail).font(.subheadline).multilineTextAlignment(.center)
                        .foregroundStyle(onVideo ? Color.white.opacity(0.75) : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !actions.isEmpty {
                VStack(spacing: 8) {
                    ForEach(actions) { a in
                        Button(role: a.role, action: a.run) {
                            Text(a.title).font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .foregroundStyle(a.primary ? (onVideo ? Color.black : Theme.onAccent) : (a.role == .destructive ? Color.red : (onVideo ? Color.white : Theme.accent)))
                                .background(Capsule().fill(a.primary ? (onVideo ? Color.white : Theme.accent) : (onVideo ? Color.white.opacity(0.14) : Theme.fill)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(PressStyle(scale: 0.97))
                        .accessibilityIdentifier("problem:" + a.title)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(22)
        .frame(maxWidth: 380)
        .foregroundStyle(onVideo ? .white : .primary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("problemCard")
    }
}
