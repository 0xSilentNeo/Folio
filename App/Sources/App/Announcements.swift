import SwiftUI
import UIKit
import UserNotifications

/// News from Folio (1.30.3): announcements and "a new version is out",
/// without a push server (a sideloaded app has no push entitlement). A small
/// file on Folio's GitHub page is read about twice a day while Folio is in
/// front; what's new in it is shown once, as a banner in the app and, where
/// notifications are already allowed, as a local notification.
///
/// The feed: {"announcements":[{"id","title","body","url"?,"version"?,
/// "minVersion"?,"maxVersion"?,"date"?}]}. An entry with `version` announces
/// that app version and is shown only to an older one.
@MainActor
final class Announcements: ObservableObject {
    static let shared = Announcements()

    // Computed, so the pure functions and the tests read them off the main actor.
    nonisolated static var feed: URL { URL(string: "https://raw.githubusercontent.com/0xSilentNeo/Folio/main/docs/announcements.json")! }
    nonisolated static var every: TimeInterval { 12 * 3600 }
    nonisolated static var thread: String { "folio.announcements" }
    nonisolated static var notificationPrefix: String { "folio.announce." }
    nonisolated static var seenCap: Int { 200 }

    struct Entry: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        var body: String
        var url: String?
        /// The app version this entry announces.
        var version: String?
        var minVersion: String?
        var maxVersion: String?
        /// "2026-11-14": newest first.
        var date: String?

        enum CodingKeys: String, CodingKey { case id, title, body, url, version, minVersion, maxVersion, date }

        init(id: String, title: String, body: String = "", url: String? = nil, version: String? = nil,
             minVersion: String? = nil, maxVersion: String? = nil, date: String? = nil) {
            self.id = id; self.title = title; self.body = body; self.url = url
            self.version = version; self.minVersion = minVersion; self.maxVersion = maxVersion; self.date = date
        }

        /// An id and a title are needed; anything else may be missing or of
        /// another type, and fields this version doesn't know are ignored.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decode(String.self, forKey: .title)
            guard !id.isEmpty, !title.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "an empty id or title")
            }
            body = (try? c.decode(String.self, forKey: .body)) ?? ""
            url = try? c.decode(String.self, forKey: .url)
            version = try? c.decode(String.self, forKey: .version)
            minVersion = try? c.decode(String.self, forKey: .minVersion)
            maxVersion = try? c.decode(String.self, forKey: .maxVersion)
            date = try? c.decode(String.self, forKey: .date)
        }
    }

    // MARK: Reading the feed (pure)

    /// An entry, or nothing where it can't be read: one bad entry doesn't
    /// drop the list.
    private struct Maybe: Decodable {
        let entry: Entry?
        init(from decoder: Decoder) throws { entry = try? Entry(from: decoder) }
    }

    private struct Feed: Decodable {
        let announcements: [Maybe]
        enum CodingKeys: String, CodingKey { case announcements }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            announcements = (try? c.decode([Maybe].self, forKey: .announcements)) ?? []
        }
    }

    /// The feed's entries; none from anything that isn't the feed.
    nonisolated static func parse(_ data: Data) -> [Entry] {
        guard let feed = try? JSONDecoder().decode(Feed.self, from: data) else { return [] }
        return feed.announcements.compactMap(\.entry)
    }

    /// Dotted versions as numbers: 1.30.10 is after 1.30.9, 1.30 is 1.30.0,
    /// and a leading "v" or a suffix ("3-beta") doesn't count.
    nonisolated static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ s: String) -> [Int] {
            var t = s.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
            return t.split(separator: ".", omittingEmptySubsequences: false).map { Int($0.prefix { $0.isASCII && $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// The running app is within the entry's minVersion…maxVersion.
    nonisolated static func inRange(_ e: Entry, appVersion: String) -> Bool {
        if let min = e.minVersion, !min.isEmpty, compare(appVersion, min) == .orderedAscending { return false }
        if let max = e.maxVersion, !max.isEmpty, compare(appVersion, max) == .orderedDescending { return false }
        return true
    }

    /// The entry announces a version after the running one.
    nonisolated static func isUpdate(_ e: Entry, appVersion: String) -> Bool {
        guard let v = e.version, !v.isEmpty, !appVersion.isEmpty else { return false }
        return compare(v, appVersion) == .orderedDescending
    }

    /// Still worth showing by this version of the app (a banner kept from
    /// before an update isn't, once the update it announced is installed).
    nonisolated static func relevant(_ e: Entry, appVersion: String) -> Bool {
        guard inRange(e, appVersion: appVersion) else { return false }
        return (e.version ?? "").isEmpty || isUpdate(e, appVersion: appVersion)
    }

    struct Selection: Equatable {
        /// What to show now, the first in the banner.
        var show: [Entry]
        /// Ids not to look at again (those shown among them).
        var markSeen: [String]
    }

    /// Which entries of a fetched feed are shown.
    /// - Seen before: never again.
    /// - Outside minVersion…maxVersion: not shown (and not marked, so an
    ///   update into the range still shows it).
    /// - With `version`: only the newest one after the running app, first
    ///   in the list; the others are marked seen.
    /// - The first run: only a newer version; everything else is marked
    ///   seen, so a new install isn't told a year of news.
    /// - At most `limit` a check, newest date first; the rest wait for the next.
    nonisolated static func select(_ entries: [Entry], seen: Set<String>, firstRun: Bool, appVersion: String, limit: Int = 2) -> Selection {
        var ids = seen
        var fresh: [Entry] = []
        for e in entries where !ids.contains(e.id) { ids.insert(e.id); fresh.append(e) }

        var mark: [String] = []
        var update: Entry?
        var news: [Entry] = []
        for e in fresh {
            let ranged = inRange(e, appVersion: appVersion)
            if let v = e.version, !v.isEmpty {
                guard !appVersion.isEmpty else { continue }
                guard isUpdate(e, appVersion: appVersion) else { mark.append(e.id); continue }
                guard ranged else { continue }
                if let u = update {
                    if compare(v, u.version ?? "") == .orderedDescending { mark.append(u.id); update = e } else { mark.append(e.id) }
                } else {
                    update = e
                }
            } else if firstRun {
                mark.append(e.id)
            } else if ranged {
                news.append(e)
            }
        }
        // Newest first; the feed's order among those of one day.
        let ordered = news.enumerated().sorted {
            let a = $0.element.date ?? "", b = $1.element.date ?? ""
            return a != b ? a > b : $0.offset < $1.offset
        }.map(\.element)
        let show = Array(((update.map { [$0] } ?? []) + ordered).prefix(max(0, limit)))
        return Selection(show: show, markSeen: mark + show.map(\.id))
    }

    /// Time for another look: never looked, 12 hours ago or more, or the clock went back.
    nonisolated static func due(now: Date, last: Double, every: TimeInterval = Announcements.every) -> Bool {
        let t = now.timeIntervalSince1970
        return last <= 0 || t - last >= every || last > t
    }

    /// The only links opened: https on github.com or a subdomain of it.
    nonisolated static func link(_ s: String?) -> URL? {
        guard let s, let u = URL(string: s), u.scheme?.lowercased() == "https", let host = u.host?.lowercased() else { return nil }
        return host == "github.com" || host.hasSuffix(".github.com") ? u : nil
    }

    nonisolated static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    // MARK: State

    private enum Key {
        static let seen = "announcementsSeen"
        static let seeded = "announcementsSeeded"
        static let checked = "announcementsChecked"
        static let etag = "announcementsETag"
        static let cache = "announcementsFeed"
        static let current = "announcementsCurrent"
    }

    /// The newest entry not yet dismissed: the banner. Kept over a relaunch.
    @Published private(set) var current: Entry?

    private var started = false
    private var task: Task<Void, Never>?
    private var lastAttempt: Date?
    /// Shown in the app, waiting to be posted as notifications when Folio
    /// leaves the screen (the app's delegate shows none of these over it).
    private var toNotify: [Entry] = []

    private var enabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.announcements) }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Key.current), let e = try? JSONDecoder().decode(Entry.self, from: data) {
            if Self.relevant(e, appVersion: Self.appVersion) { current = e } else { UserDefaults.standard.removeObject(forKey: Key.current) }
        }
    }

    // MARK: Checking

    /// Once, at launch (FolioApp): looks each time Folio comes to the front.
    func start() {
        guard !started else { return }
        started = true
        // Not under tests or the labs: no network of its own there.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              !CommandLine.arguments.contains(where: { $0.hasPrefix("-ui") || $0.hasPrefix("-lab") || $0.hasPrefix("-shots") }) else { return }
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Announcements.shared.becameActive() }
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Announcements.shared.deliver() }
        }
    }

    private func becameActive() {
        // Off: no request at all. The kids profile: nothing shown, so nothing asked.
        guard enabled, !KidsProfile.shared.isOn, task == nil else { return }
        let now = Date()
        guard Self.due(now: now, last: UserDefaults.standard.double(forKey: Key.checked)) else { return }
        // A look that failed isn't tried again at every return to Folio.
        if let l = lastAttempt, now.timeIntervalSince(l) < 15 * 60 { return }
        lastAttempt = now
        task = Task(priority: .utility) {
            // A few seconds in, after launch's own work.
            try? await Task.sleep(for: .seconds(4))
            await Announcements.shared.check()
            Announcements.shared.task = nil
        }
    }

    /// No cookies, no cache, nothing kept between requests.
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 10
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private func check() async {
        guard enabled else { return }
        let d = UserDefaults.standard
        var request = URLRequest(url: Self.feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        let cached = d.data(forKey: Key.cache)
        // "Not changed" answers with nothing, so the last copy is kept to read again.
        if cached != nil, let tag = d.string(forKey: Key.etag) { request.setValue(tag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            let body: Data
            switch http.statusCode {
            case 304:
                guard let cached else { return }
                body = cached
            case 200:
                // A list of a few lines; anything huge isn't it.
                guard data.count <= 256 * 1024 else { dlog("news", "feed too large (\(data.count) bytes)"); return }
                body = data
                d.set(data, forKey: Key.cache)
                if let tag = http.value(forHTTPHeaderField: "ETag") { d.set(tag, forKey: Key.etag) } else { d.removeObject(forKey: Key.etag) }
            default:
                dlog("news", "feed: HTTP \(http.statusCode)")
                return
            }
            d.set(Date().timeIntervalSince1970, forKey: Key.checked)
            apply(Self.parse(body))
        } catch {
            dlog("news", "feed: \(error.localizedDescription)")
        }
    }

    private func apply(_ entries: [Entry]) {
        // Turned off, or the kids profile turned on, while it was fetched:
        // nothing is marked, so it's shown when they're back.
        guard enabled, !KidsProfile.shared.isOn else { return }
        let d = UserDefaults.standard
        let seen = d.stringArray(forKey: Key.seen) ?? []
        let firstRun = !d.bool(forKey: Key.seeded)
        let s = Self.select(entries, seen: Set(seen), firstRun: firstRun, appVersion: Self.appVersion)
        d.set(true, forKey: Key.seeded)
        if !s.markSeen.isEmpty { d.set(Array((seen + s.markSeen).suffix(Self.seenCap)), forKey: Key.seen) }
        dlog("news", "\(entries.count) in the feed, \(s.show.count) new\(firstRun ? " (first look)" : "")")
        guard let first = s.show.first else { return }
        setCurrent(first)
        toNotify = s.show
        deliver()
    }

    private func setCurrent(_ e: Entry?) {
        current = e
        if let e, let data = try? JSONEncoder().encode(e) {
            UserDefaults.standard.set(data, forKey: Key.current)
        } else {
            UserDefaults.standard.removeObject(forKey: Key.current)
        }
    }

    // MARK: Notifications

    /// Posts what's waiting as local notifications, if iOS already allows
    /// them (never asked for here). While Folio is in front they wait: the
    /// banner is there, and the app's notification delegate shows nothing of
    /// these over the app. They go when Folio leaves the screen.
    private func deliver() {
        guard !toNotify.isEmpty, UIApplication.shared.applicationState != .active else { return }
        let entries = toNotify
        toNotify = []
        guard enabled, !KidsProfile.shared.isOn, !UserDefaults.standard.bool(forKey: SettingsKey.notifyAllOff) else { return }
        Task(priority: .utility) {
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            guard [.authorized, .provisional, .ephemeral].contains(status) else { return }
            for e in entries {
                let content = UNMutableNotificationContent()
                content.title = e.title
                content.body = e.body
                content.sound = .default
                content.threadIdentifier = Announcements.thread
                var info: [String: Any] = ["announcement": e.id]
                if let u = Announcements.link(e.url) { info["url"] = u.absoluteString }
                content.userInfo = info
                // No trigger: at once.
                let request = UNNotificationRequest(identifier: Announcements.notificationPrefix + e.id, content: content, trigger: nil)
                do { try await center.add(request) } catch { dlog("news", "notification: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: The banner's buttons

    /// Closes the banner; the entry isn't shown again.
    func dismiss() {
        guard let e = current else { return }
        toNotify.removeAll { $0.id == e.id }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationPrefix + e.id])
        setCurrent(nil)
    }

    /// Opens the entry's page (GitHub only) and closes the banner.
    func open() {
        guard let e = current else { return }
        if let u = Self.link(e.url) { UIApplication.shared.open(u) }
        dismiss()
    }
}

/// The banner for the newest announcement (1.30.3): its title, two lines
/// of text, View where it has a page, and a close button. Nothing at all
/// when there's none, in the kids profile, or with News from Folio off.
struct AnnouncementBanner: View {
    @ObservedObject private var model = Announcements.shared
    @ObservedObject private var kids = KidsProfile.shared
    @AppStorage(SettingsKey.announcements) private var on = true

    var body: some View {
        if let a = model.current, on, !kids.isOn {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(a.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if !a.body.isEmpty {
                        Text(a.body)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if Announcements.link(a.url) != nil {
                        Button("View") { model.open() }
                            .buttonStyle(.plain)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.action)
                            .padding(.top, 3)
                            .accessibilityHint("Opens Folio's page on GitHub")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    withAnimation(.smooth(duration: 0.3)) { model.dismiss() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 10)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("announcementBanner")
            .transition(.opacity)
        }
    }
}
