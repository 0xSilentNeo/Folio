import SwiftUI

/// "What's new" (1.22.0): a short list of what changed, shown once on the
/// first launch after an update (not after a first install), and in
/// Settings → Help & Diagnostics → What's new.
///
/// The list is written by hand here, newest version first; a version
/// without its own entries shows nothing. The last version shown is kept in
/// UserDefaults (SettingsKey.whatsNewShown).
///
/// The version numbers started again at 0.90.0 (after 1.30.6): see
/// `resetVersionLine`, which runs once before anything here is read.
enum WhatsNew {
    struct Item: Hashable {
        let icon: String
        let title: String
        let text: String
    }

    struct Release: Hashable {
        let version: String
        let items: [Item]
    }

    /// Empty at 0.90.0, where the version numbers start again: the lists
    /// of 1.21.0 to 1.30.6 are gone, and nothing is shown until a version
    /// has entries here. Newest version first.
    ///
    /// The house rule for an entry:
    /// - The title names the thing.
    /// - The text is one short plain sentence saying what you'll see.
    /// - One fact per item.
    /// - No "so that" and no "instead of" clauses.
    /// - No reference to earlier versions.
    /// - At most five per release.
    ///
    ///     Release(version: "0.90.1", items: [
    ///         Item(icon: "magnifyingglass", title: "Search", text: "Results appear as you type."),
    ///     ]),
    static let releases: [Release] = []

    static func release(_ version: String) -> Release? { releases.first { $0.version == version } }

    /// Every version's list after `last` up to `current`, newest first
    /// (1.28.11): an update over several versions shows what each one
    /// brought, not only the newest's. With no `last`, the current one's.
    static func releases(after last: String?, upTo current: String) -> [Release] {
        releases(after: last, upTo: current, in: releases)
    }

    /// The same from any list (the tests have their own, the app's being
    /// empty at 0.90.0).
    static func releases(after last: String?, upTo current: String, in list: [Release]) -> [Release] {
        list.filter { r in
            guard newer(current, than: r.version) || r.version == current else { return false }
            guard let last else { return r.version == current }
            return newer(r.version, than: last)
        }
    }

    /// Versions as numbers, part by part (0.90.0): 0.90.0 is after 0.9.0,
    /// 0.100.0 after 0.90.0 and 1.0.0 after them all. The same comparison
    /// as the announcements'.
    static func newer(_ a: String, than b: String) -> Bool {
        Announcements.compare(a, b) == .orderedDescending
    }

    /// The version this install showed last, before this launch: what the
    /// sheet lists from.
    @MainActor static var updatedFrom: String?

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    // MARK: Once per version

    /// What to do at launch: show the sheet or not, and what to remember as shown.
    struct Decision: Equatable {
        var show: Bool
        var remember: String?
    }

    /// - First install (nothing saved yet): nothing shown, this version remembered.
    /// - An update (a version before this one was used, or one from before
    ///   1.22.0, which kept nothing): shown once, then remembered.
    /// - The same version again, or an older one: nothing.
    static func decide(current: String, lastShown: String?, existingInstall: Bool, hasEntries: Bool) -> Decision {
        guard !current.isEmpty else { return Decision(show: false, remember: nil) }
        guard let last = lastShown else {
            return Decision(show: existingInstall && hasEntries, remember: current)
        }
        guard last != current else { return Decision(show: false, remember: nil) }
        return Decision(show: newer(current, than: last) && hasEntries, remember: current)
    }

    // MARK: The version numbers start again (0.90.0)

    /// Once per install, before What's New and the announcements read what
    /// they kept (0.90.0). After 1.30.6 the version is 0.90.0, then 0.90.1,
    /// 0.91.0 … and 1.0.0 at launch: lower than what an install remembers,
    /// and later the same numbers as old ones.
    ///
    /// - The version What's New remembers is forgotten: this launch shows
    ///   the running version's list if it has one (0.90.0 has none).
    /// - "A new version is out" banners waiting are dropped (they announce
    ///   1.x), with the copy of the feed they came from.
    ///
    /// Kept by a flag, not by comparing versions: an install that goes
    /// from 1.30.6 straight to 1.0.0 or 1.2.0, when those come round again,
    /// can't be told from one that was always there by its number. A new
    /// install has nothing saved, so nothing changes but the flag. Returns
    /// whether this call was the one that did it.
    @discardableResult
    static func resetVersionLine(current: String = currentVersion, defaults d: UserDefaults = .standard) -> Bool {
        guard !d.bool(forKey: SettingsKey.versionLineReset) else { return false }
        // Forgotten, not set to the running version (review): an install
        // that comes from 1.x straight to a 0.9x with a list is shown that
        // list, as an update. At 0.90.0 the list is empty, so nothing shows.
        d.removeObject(forKey: SettingsKey.whatsNewShown)
        Announcements.forgetUpdates(defaults: d)
        d.set(true, forKey: SettingsKey.versionLineReset)
        return true
    }

    /// Something an earlier launch of Folio left behind: the library's
    /// metadata flag (every version since 1.19.0 sets it), or its files.
    /// Read before anything this launch writes.
    static func usedBefore() -> Bool {
        if UserDefaults.standard.object(forKey: "metadataTextDecoded") != nil { return true }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ["history.json", "metadata.json"].contains { FileManager.default.fileExists(atPath: support.appendingPathComponent($0).path) }
    }

    /// Set at launch (FolioApp.init, first thing): the sheet waits for the splash.
    @MainActor static var pending = false

    /// UI tests and the lab launch with arguments; the sheet would cover what they look at.
    static var suppressed: Bool {
        let args = CommandLine.arguments
        if args.contains("-whatsNew") { return false }
        return args.contains { $0 == "-noSplash" || $0 == "-noWhatsNew" || $0.hasPrefix("-ui") || $0.hasPrefix("-lab") || $0.hasPrefix("-shots") }
    }

    @MainActor
    static func noteLaunch() {
        let d = UserDefaults.standard
        let current = currentVersion
        // The version numbers started again (0.90.0): what was remembered
        // of 1.x is put right first. FolioApp calls this before the
        // announcements are first touched.
        let before = d.string(forKey: SettingsKey.whatsNewShown)
        if resetVersionLine(current: current, defaults: d), let before, before != current {
            dlog("app", "version numbers start again: \(before) was remembered, now \(current)")
        }
        let last = d.string(forKey: SettingsKey.whatsNewShown)
        let used = usedBefore()
        // The first install's welcome (1.27.0), from the same evidence.
        FirstRun.decide(lastShown: last, usedBefore: used)
        updatedFrom = last
        var decision = decide(current: current, lastShown: last, existingInstall: used,
                              hasEntries: !releases(after: last, upTo: current).isEmpty)
        if CommandLine.arguments.contains("-whatsNew") { decision.show = true }
        if suppressed { decision.show = false }
        if let r = decision.remember { d.set(r, forKey: SettingsKey.whatsNewShown) }
        pending = decision.show
        dlog("app", "what's new: \(current), last shown \(last ?? "none")\(decision.show ? " — shown" : "")")
    }
}

/// The sheet: the version's list and Continue.
struct WhatsNewSheet: View {
    var version: String = WhatsNew.currentVersion
    /// From Settings: every version's list, newest first.
    var all = false
    /// After an update (1.28.11): the version Folio was updated from, so the
    /// sheet lists everything since.
    var since: String? = nil
    @Environment(\.dismiss) private var dismiss

    private var releases: [WhatsNew.Release] {
        if all { return WhatsNew.releases }
        let list = WhatsNew.releases(after: since, upTo: version)
        return list.isEmpty ? (WhatsNew.release(version).map { [$0] } ?? []) : list
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            FolioLeaf().frame(width: 30, height: 30).padding(.leading, -5)
                            Wordmark(size: 22)
                        }
                        Text("What's new").font(.system(.largeTitle, design: .rounded, weight: .bold))
                        // No list (0.90.0: none yet, from Settings → About
                        // or `-whatsNew`): said, not a page with only a title.
                        if releases.isEmpty {
                            Text("Nothing to list for this version.")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .accessibilityIdentifier("whatsNewEmpty")
                        }
                        if !all, let since, releases.count > 1 {
                            Text("Since \(since), the version you had")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 36)
                    ForEach(releases, id: \.version) { r in
                        VStack(alignment: .leading, spacing: 20) {
                            if all || releases.count > 1 {
                                Text("Version \(r.version)").font(.headline).foregroundStyle(.secondary)
                            }
                            ForEach(r.items, id: \.self) { item in
                                HStack(alignment: .top, spacing: 16) {
                                    Image(systemName: item.icon)
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundStyle(Theme.accent)
                                        .frame(width: 36)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title).font(.headline)
                                        Text(item.text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            Button { dismiss() } label: {
                Text("Continue").font(.headline)
                    .frame(maxWidth: 420).frame(height: 52)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(Theme.onAccent)
            }
            .buttonStyle(PressStyle(scale: 0.97))
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .accessibilityIdentifier("whatsNewContinue")
        }
        .background(HomeBackdrop().ignoresSafeArea())
    }
}
