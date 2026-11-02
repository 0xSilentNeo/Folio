import Foundation
import CryptoKit

/// smb:// addresses, for libsmbclient (browsing) and mpv's FFmpeg (playing):
/// smb://[domain;]user[:password]@host[:port]/share/path. Both decode %XX
/// in every part, so everything but letters, digits and -._~ is encoded:
/// a "#", "?" or "@" in a file name or password can't end a part early.
enum SMBURL {
    private static let plain = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: plain) ?? s }

    /// The host (and port) and a share typed with it, from what was typed:
    /// "nas.local", "smb://nas/Media", "\\NAS\Media", "10.0.0.2:4450/Media".
    static func parseHost(_ typed: String) -> (host: String, share: String?) {
        var s = typed.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/")
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        while s.hasPrefix("/") { s.removeFirst() }
        if let at = s.lastIndex(of: "@"), at < (s.firstIndex(of: "/") ?? s.endIndex) { s = String(s[s.index(after: at)...]) }
        let parts = s.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return (parts.first ?? "", parts.count > 1 ? parts[1] : nil)
    }

    /// "DOMAIN\user" or "DOMAIN;user": the domain apart.
    static func splitDomain(_ user: String) -> (domain: String?, user: String) {
        for sep in ["\\", ";"] {
            if let r = user.range(of: sep) {
                let d = String(user[..<r.lowerBound]), u = String(user[r.upperBound...])
                if !d.isEmpty, !u.isEmpty { return (d, u) }
            }
        }
        return (nil, user)
    }

    /// The host part, with a port only when one was typed. An IPv6 address
    /// gets its brackets.
    static func hostPart(_ host: String) -> String {
        if host.filter({ $0 == ":" }).count > 1, !host.hasPrefix("[") { return "[\(host)]" }
        return host
    }

    /// `path` from the host: "/" (the shares), "/Media", "/Media/Films/Dune.mkv".
    /// With a user and password, the address mpv plays.
    static func address(host: String, path: String, user: String? = nil, password: String? = nil) -> String {
        var login = ""
        if let user, !user.isEmpty {
            let (domain, name) = splitDomain(user)
            login = (domain.map { encode($0) + ";" } ?? "") + encode(name)
            if let password, !password.isEmpty { login += ":" + encode(password) }
            login += "@"
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map { encode(String($0)) }
        return "smb://" + login + hostPart(host) + "/" + parts.joined(separator: "/")
    }

    /// A path one level up: "/Media/Films" → "/Media"; "/Media" → "/".
    static func parent(_ path: String) -> String {
        var parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return "/" }
        parts.removeLast()
        return "/" + parts.joined(separator: "/")
    }

    /// The port typed after the host ("nas:4450"), for the context.
    static func port(_ host: String) -> UInt16? {
        guard !host.hasPrefix("["), host.filter({ $0 == ":" }).count == 1, let p = host.split(separator: ":").last else { return nil }
        return UInt16(p)
    }
}

enum SMBError: LocalizedError, Equatable {
    case noContext, badAddress, wrongLogin, notFound, unreachable, timedOut, notFolder, other(Int32)

    /// From libsmbclient's errno.
    init(errno e: Int32) {
        switch e {
        case EACCES, EPERM: self = .wrongLogin
        case ENOENT, ENODEV: self = .notFound
        case ETIMEDOUT: self = .timedOut
        case EHOSTUNREACH, ENETUNREACH, ECONNREFUSED, EHOSTDOWN, ECONNRESET: self = .unreachable
        case EINVAL: self = .badAddress
        case ENOTDIR: self = .notFolder
        default: self = .other(e)
        }
    }

    var isOffline: Bool { self == .unreachable || self == .timedOut }

    var errorDescription: String? {
        switch self {
        case .noContext: return "SMB could not start."
        case .badAddress: return "Invalid host or share."
        case .wrongLogin: return "Wrong user name or password, or no access to this share."
        case .notFound: return "No such share or folder."
        case .unreachable: return "The host can't be reached."
        case .timedOut: return "The host didn't answer in time."
        case .notFolder: return "Not a folder."
        case .other(let e): return String(cString: strerror(e))
        }
    }
}

struct SMBEntry: Hashable {
    enum Kind { case share, folder, file }
    var name: String
    var kind: Kind
    var size: Int64?
    var modified: Date?
}

/// The login handed to libsmbclient when it asks (the auth callback), as C
/// strings that live as long as the context.
final class SMBLogin {
    let domain: [CChar]?
    let user: [CChar]
    let password: [CChar]
    var hasUser: Bool { user.count > 1 }

    init(username: String, password: String) {
        let (d, u) = SMBURL.splitDomain(username)
        domain = d.map { Array($0.utf8CString) }
        user = Array(u.utf8CString)
        self.password = Array(password.utf8CString)
    }

    /// Copies a C string (with its 0) into a buffer of `capacity` bytes, cut to fit.
    static func copy(_ src: [CChar], to dst: UnsafeMutablePointer<CChar>?, capacity: Int32) {
        guard let dst, capacity > 0 else { return }
        let n = min(src.count, Int(capacity))
        src.withUnsafeBufferPointer { b in dst.update(from: b.baseAddress!, count: n) }
        dst[n - 1] = 0
    }
}

/// libsmbclient asks for the login through a C function: the login is found
/// from the context's user data (an SMBLogin), not captured.
private let smbAuthData: smbc_get_auth_data_with_context_fn = { ctx, _, _, wg, wglen, un, unlen, pw, pwlen in
    guard let ctx, let raw = smbc_getOptionUserData(ctx) else { return }
    let login = Unmanaged<SMBLogin>.fromOpaque(raw).takeUnretainedValue()
    if let d = login.domain { SMBLogin.copy(d, to: wg, capacity: wglen) }
    SMBLogin.copy(login.user, to: un, capacity: unlen)
    SMBLogin.copy(login.password, to: pw, capacity: pwlen)
}

/// One SMB host through libsmbclient: one context (smbc_new_context) used
/// only on its own serial queue, as a context isn't thread-safe. mpv plays
/// through its own contexts (FFmpeg's), not this one.
final class SMBClient: @unchecked Sendable {
    let host: String
    private let login: SMBLogin
    private let queue = DispatchQueue(label: "dev.silentneo.folio.smb", qos: .userInitiated)
    /// Made on first use, on `queue`, and only touched there.
    private var context: UnsafeMutablePointer<SMBCCTX>?

    /// libsmbclient's own wait for a connection or an answer.
    static let timeoutMS: Int32 = 12_000
    /// Folders with more entries than this aren't asked each file's size and date.
    static let statLimit = 600

    init(host: String, username: String, password: String) {
        self.host = host
        login = SMBLogin(username: username, password: password)
    }

    deinit {
        let ctx = context, login = login
        queue.async {
            if let ctx { smbc_free_context(ctx, 1) }
            withExtendedLifetime(login) {}
        }
    }

    // MARK: One client per server

    private static let lock = NSLock()
    nonisolated(unsafe) private static var clients: [UUID: (key: String, client: SMBClient)] = [:]

    /// The server's client, made again when its host or login changed.
    static func shared(for server: MediaServer) -> SMBClient? {
        guard let host = server.smbHost else { return nil }
        let user = server.username ?? "", password = server.password ?? ""
        let key = SHA256.hash(data: Data("\(host)\u{1}\(user)\u{1}\(password)".utf8)).map { String(format: "%02x", $0) }.joined()
        lock.lock(); defer { lock.unlock() }
        if let c = clients[server.id], c.key == key { return c.client }
        let c = SMBClient(host: host, username: user, password: password)
        clients[server.id] = (key, c)
        return c
    }

    static func forget(_ id: UUID) {
        lock.lock(); clients[id] = nil; lock.unlock()
    }

    // MARK: Listing

    /// A folder's entries ("/" lists the host's shares), without "." and "..",
    /// printer and IPC shares or hidden ones ("C$"). Files and folders get
    /// their size and date (one stat each, up to `statLimit`).
    func list(_ path: String) async throws -> [SMBEntry] {
        try await run(seconds: Double(Self.timeoutMS) / 1000 + 8) { try self.listNow(path) }
    }

    /// Starts the context without connecting anywhere: that libsmbclient
    /// starts in this build at all (unit test).
    func startContext() async throws {
        try await run(seconds: 10) { _ = try self.makeContext() }
    }

    /// The work on the queue, with a deadline of our own too: a call stuck
    /// past libsmbclient's timeout (a name that never resolves) still ends
    /// in an answer for the browser.
    private func run<T>(seconds: Double, _ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let once = Once()
            queue.async {
                let r = Result { try work() }
                if once.claim() { cont.resume(with: r) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if once.claim() { cont.resume(throwing: SMBError.timedOut) }
            }
        }
    }

    private func makeContext() throws -> UnsafeMutablePointer<SMBCCTX> {
        if let context { return context }
        guard let ctx = smbc_new_context() else { throw SMBError.noContext }
        smbc_setDebug(ctx, 0)
        smbc_setTimeout(ctx, Self.timeoutMS)
        smbc_setOptionUserData(ctx, Unmanaged.passUnretained(login).toOpaque())
        smbc_setFunctionAuthDataWithContext(ctx, smbAuthData)
        smbc_setOptionUseKerberos(ctx, 0)
        smbc_setOptionFallbackAfterKerberos(ctx, 1)
        // With a user name, a refused login is said, not turned into a guest login.
        if login.hasUser { smbc_setOptionNoAutoAnonymousLogin(ctx, 1) }
        if let p = SMBURL.port(host) { smbc_setPort(ctx, p) }
        guard smbc_init_context(ctx) != nil else {
            smbc_free_context(ctx, 0)
            throw SMBError.noContext
        }
        context = ctx
        return ctx
    }

    private static let nameOffset = MemoryLayout<smbc_dirent>.offset(of: \smbc_dirent.name) ?? 0

    private func listNow(_ path: String) throws -> [SMBEntry] {
        let ctx = try makeContext()
        guard let opendir = smbc_getFunctionOpendir(ctx), let readdir = smbc_getFunctionReaddir(ctx),
              let closedir = smbc_getFunctionClosedir(ctx), let statFn = smbc_getFunctionStat(ctx) else { throw SMBError.noContext }
        let folder = SMBURL.address(host: host, path: path)
        errno = 0
        guard let dir = opendir(ctx, folder) else {
            let code = errno
            let e = SMBError(errno: code)
            dlog("servers/error", "smb: listing a folder on \(host) failed: \(e.localizedDescription) (errno \(code))")
            throw e
        }
        var out: [SMBEntry] = []
        while let d = readdir(ctx, dir) {
            let name = String(cString: UnsafeRawPointer(d).advanced(by: Self.nameOffset).assumingMemoryBound(to: CChar.self))
            guard name != ".", name != "..", !name.isEmpty else { continue }
            switch Int32(d.pointee.smbc_type) {
            case SMBC_FILE_SHARE: if !name.hasSuffix("$") { out.append(SMBEntry(name: name, kind: .share)) }
            case SMBC_DIR: out.append(SMBEntry(name: name, kind: .folder))
            case SMBC_FILE: out.append(SMBEntry(name: name, kind: .file))
            default: break      // workgroups, servers, printers, IPC, links
            }
        }
        _ = closedir(ctx, dir)
        // Sizes and dates: one round trip each. Other files (artwork, .nfo) aren't asked.
        let wanted = out.indices.filter { i in
            out[i].kind == .folder || out[i].kind == .file && (TitleParser.isMedia(out[i].name) || TitleParser.isSubtitle(out[i].name))
        }
        for i in wanted.prefix(Self.statLimit) {
            var st = Darwin.stat()
            let address = SMBURL.address(host: host, path: SMBPath.join(path, out[i].name))
            guard statFn(ctx, address, &st) == 0 else { continue }
            if out[i].kind == .file { out[i].size = Int64(st.st_size) }
            out[i].modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        }
        return out
    }
}
