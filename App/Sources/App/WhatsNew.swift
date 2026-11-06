import SwiftUI

/// "What's new" (1.22.0): a short list of what changed, shown once on the
/// first launch after an update (not after a first install), and in
/// Settings → Help & Diagnostics → What's new.
///
/// The list is written by hand here, newest version first; a version
/// without its own entries shows nothing. The last version shown is kept in
/// UserDefaults (SettingsKey.whatsNewShown).
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

    static let releases: [Release] = [
        Release(version: "1.24.0", items: [
            Item(icon: "rectangle.3.group", title: "New widgets",
                 text: "Continue Watching in four styles, Airing in three, and Downloads, Your week, New on your server and Pick for tonight. Each follows your Home Screen's look: light, dark, clear or tinted."),
            Item(icon: "play.circle", title: "Straight from the widget",
                 text: "Resume, go on to the next episode, play an episode that's just out, or shuffle tonight's pick, without opening a menu first."),
            Item(icon: "switch.2", title: "A Resume control",
                 text: "Add Resume to Control Center, the Lock Screen or the Action button: one tap plays what you watched last."),
            Item(icon: "quote.bubble", title: "Reminders, with some cheek",
                 text: "Now and then a line about what you're watching, at most one a day and never at night. Turn them off in Settings → Reminders."),
        ]),
        Release(version: "1.23.4", items: [
            Item(icon: "captions.bubble", title: "Subtitles stay in view",
                 text: "Fill and pinching no longer push subtitles off the screen: they move and resize with the picture. Turn it off in the player's Subtitles menu (When zoomed)."),
            Item(icon: "arrow.up.left.and.arrow.down.right", title: "A cleaner pinch",
                 text: "No jump when your fingers lift: Fill and Fit take over in the same frame."),
        ]),
        Release(version: "1.23.3", items: [
            Item(icon: "play.circle", title: "Resume resumes",
                 text: "After an update, Resume on a title page and a tap on an episode started from the beginning though the button showed your place. They go on from it now."),
            Item(icon: "rectangle.stack", title: "One place per file",
                 text: "Each downloaded file keeps one saved place, not one per install, and a file no longer shows the progress of another with the same name."),
        ]),
        Release(version: "1.23.2", items: [
            Item(icon: "forward.end", title: "On to the next episode",
                 text: "A show you added on Real-Debrid one episode at a time now goes on to the next one, wherever its folder is."),
            Item(icon: "bolt", title: "Real-Debrid opens faster",
                 text: "Folio finds the file's download address first, so opening, resuming and seeking no longer go back through Real-Debrid's WebDAV each time."),
            Item(icon: "text.badge.checkmark", title: "Up Next says what it covers",
                 text: "Watch Ending, Watch Preview: named after the part. No card over a scene after the credits; a preview keeps it."),
            Item(icon: "forward.frame", title: "Intros you watch",
                 text: "Watch an intro through in two episodes and its Skip button stops showing for that show. Bring it back in Settings → Skip Intro & Credits."),
            Item(icon: "circle.dashed", title: "Calmer seeks",
                 text: "Seeking in a downloaded file no longer flashes the loading spinner."),
        ]),
        Release(version: "1.23.1", items: [
            Item(icon: "rectangle.on.rectangle", title: "Widgets, another way in",
                 text: "Without an App Group, the widgets now look in the Keychain the signing gives the app and the widget alike."),
            Item(icon: "photo", title: "Sharp artwork in Control Center",
                 text: "The Lock Screen and Control Center get the picture at full size, not the list's small one."),
            Item(icon: "sparkles", title: "Anime4K, lighter",
                 text: "On this screen a 1080p video gets the restore stages at its own size, not a 4K image every frame; it eases off when the phone is hot."),
            Item(icon: "play.rectangle", title: "HDR on OpenGL no longer stuck loading",
                 text: "The renderer stopped switching decoding back and forth while a 4K HDR file started."),
            Item(icon: "slider.horizontal.3", title: "A steady time bar",
                 text: "The bar no longer grows and shrinks while you press the menu buttons on iOS 27."),
            Item(icon: "arrow.up.left.and.arrow.down.right", title: "Pinch follows your fingers",
                 text: "Pinching the video moves the picture as you pinch, then settles on Fit or Fill."),
        ]),
        Release(version: "1.23.0", items: [
            Item(icon: "magnifyingglass", title: "A smoother, tidier search",
                 text: "Opens without the stall, starts with what it searches, shows server files as a list or as posters, and a pill opens a file's folder."),
            Item(icon: "exclamationmark.icloud", title: "When a server lets you down",
                 text: "A file Real-Debrid removed, a refused login or a server that's down is now said plainly, with what you can do."),
            Item(icon: "photo", title: "Artwork in Control Center",
                 text: "Control Center and the Lock Screen show the title's picture. The player's own Live Activity is gone: Now Playing does its job."),
            Item(icon: "square.grid.2x2", title: "More on Discover",
                 text: "Lists go on past 100 as you scroll, up to the 250 IMDb gives."),
            Item(icon: "leaf", title: "Folio's own loading",
                 text: "A light runs round the Folio leaf wherever something is loading."),
            Item(icon: "rectangle.on.rectangle", title: "Widgets without an App Group",
                 text: "When the install has no App Group, Folio tries to reach its widgets through the Keychain."),
        ]),
        Release(version: "1.22.7", items: [
            Item(icon: "play.rectangle.on.rectangle", title: "Control Center and the Lock Screen",
                 text: "What's playing should show there now. Like Music and TV, Folio's sound now pauses other apps' sound instead of mixing with it."),
        ]),
        Release(version: "1.22.6", items: [
            Item(icon: "magnifyingglass", title: "Search on its own, on iOS 27 too",
                 text: "The round search button sits beside the tab bar and opens into the field where it is. Cancel takes you back."),
            Item(icon: "bell.slash", title: "No tracking for shows that have ended",
                 text: "Dragon Ball no longer picks up another series' times, and an ended show is no longer tracked."),
            Item(icon: "calendar", title: "Episode dates checked",
                 text: "Coming and recent episodes are checked against TVmaze, and a release with no known hour shows its day only."),
            Item(icon: "tv", title: "Streaming services' logos",
                 text: "Netflix, Prime Video and the others on Discover show their own logos."),
        ]),
        Release(version: "1.22.5", items: [
            Item(icon: "magnifyingglass", title: "Search the page you're on",
                 text: "From Home: your library, Real-Debrid, WebDAV, Plex and Jellyfin. From Discover: titles on IMDb and your addons."),
            Item(icon: "popcorn", title: "Loading, with popcorn",
                 text: "A title page that takes a moment shows a line or two of nonsense instead of a spinner."),
            Item(icon: "circle", title: "Round buttons stay round",
                 text: "Settings and the other round buttons open from their own shape."),
        ]),
        Release(version: "1.22.4", items: [
            Item(icon: "magnifyingglass", title: "Search beside the tab bar",
                 text: "One search for your library, your servers' files and titles on IMDb and your addons, from the button beside the tab bar."),
            Item(icon: "arrow.up.left.and.arrow.down.right", title: "Zoom between tabs",
                 text: "An experiment, off at first: Settings → General → Zoom between tabs."),
        ]),
        Release(version: "1.22.3", items: [
            Item(icon: "arrow.down.circle", title: "iOS's own download progress",
                 text: "On iOS 26 and later, iOS shows your downloads in the Dynamic Island and on the Lock Screen, with a button to stop them."),
            Item(icon: "speedometer", title: "Faster downloads",
                 text: "Up to 8 connections per file, a slow connection is taken over, and the file is written straight into place."),
            Item(icon: "chevron.down.circle", title: "Fold titles in Downloads",
                 text: "Tap a title to hide its files, and again to show them."),
            Item(icon: "square.grid.2x2", title: "A tidier Home",
                 text: "Recently added is gone (the library sorts by date added too), and the round buttons open their menus smoothly."),
        ]),
        Release(version: "1.22.2", items: [
            Item(icon: "lock", title: "One kids passcode",
                 text: "Chosen the first time and kept until you change it. Turning the kids profile on again asks for nothing."),
            Item(icon: "rectangle.expand.vertical", title: "Player controls, evenly",
                 text: "Every width is the same distance from both edges, and the menu buttons no longer cover the time bar."),
            Item(icon: "goforward.10", title: "Quick skips",
                 text: "Taps while a skip lands go as one, with the sound off until the picture is there."),
            Item(icon: "pip", title: "Sharper PiP with OpenGL",
                 text: "Picture in Picture shows the video at its own size, up to 1080p."),
            Item(icon: "bell", title: "Track only what's still running",
                 text: "Shows that have ended have no Track button, and episodes not out yet don't open the streams page."),
        ]),
        Release(version: "1.22.1", items: [
            Item(icon: "cpu", title: "Metal is the default again",
                 text: "And the OpenGL renderer now plays 10-bit files and shows HDR as HDR, with Picture in Picture that never pauses. Try it in Settings → mpv → Renderer."),
            Item(icon: "arrow.down.circle", title: "Faster, safer downloads",
                 text: "Big files download in several parts at once, a download queued before an update no longer fails at the end, and the Live Activity keeps counting in the background."),
            Item(icon: "lock", title: "The kids profile really locks",
                 text: "Turning it off, its limits and Settings all ask for the passcode or Face ID, on a Lock Screen-style keypad. For you shows only titles rated within your limits."),
            Item(icon: "bell.badge", title: "Tracking, clearer",
                 text: "A tracked show says so on its page, and episode tiles show when the next one airs, in your own time zone."),
            Item(icon: "rectangle.portrait.and.arrow.right", title: "The player closes at the end",
                 text: "No more Replay card: the player closes when a file ends. Controls sit a little closer to the edges in landscape."),
        ]),
        Release(version: "1.22.0", items: [
            Item(icon: "pip", title: "Picture in Picture without the pause",
                 text: "The screen and Picture in Picture now show one and the same picture, so PiP, Notification Centre and the app switcher no longer pause the video. For HDR brightness, choose HDR (Metal) in Settings → mpv → Renderer."),
            Item(icon: "livephoto", title: "Live Activities",
                 text: "What's playing, with play/pause and skip, and your downloads, on the Lock Screen and in the Dynamic Island."),
            Item(icon: "captions.bubble", title: "Two subtitles at once",
                 text: "A second subtitle at the top of the picture, from the Tracks menu. Speed, and \"always skip openings\", are now remembered per show too."),
            Item(icon: "arrow.down.circle", title: "Downloads that look after themselves",
                 text: "The next episodes download on Wi-Fi while you watch, and watched downloads can delete themselves after a day or a week."),
            Item(icon: "slider.horizontal.3", title: "Filter your library",
                 text: "Show only unwatched titles, ones in progress or ones you've watched, by genre or by year. The filters stay set, and Clear filters brings everything back."),
            Item(icon: "clock.arrow.circlepath", title: "Recently added",
                 text: "The titles you added last, in a row on Home under Continue Watching."),
            Item(icon: "dice", title: "Pick something for me",
                 text: "Can't choose? Folio picks an unwatched film from your library, newer ones more often. Don't like it? Pick again."),
            Item(icon: "figure.and.child.holdinghands", title: "Kids profile",
                 text: "Only titles rated for kids in Discover, search and your library, with Settings locked behind a passcode (or Face ID). Settings → Kids profile."),
            Item(icon: "iphone.and.arrow.forward", title: "Handoff",
                 text: "A title page open on your iPhone opens on your iPad too, and the other way round; a video you're watching picks up where you were."),
        ]),
        Release(version: "1.21.0", items: [
            Item(icon: "bell.badge", title: "Track airing shows",
                 text: "A Track button on a series' page. Folio tells you when the next episode airs, in your own time zone, with a notification, a Home row, a widget and Siri."),
            Item(icon: "xmark.circle", title: "Siri goes away when the video starts",
                 text: "Continue watching with Siri, and its card no longer stays over the player."),
            Item(icon: "externaldrive.connected.to.line.below", title: "Real-Debrid on Home without a restart",
                 text: "Saving a server checks its library at once, and Home says when it's still reading it or the login was refused."),
            Item(icon: "doc.text", title: "mpv files explained",
                 text: "mpv.conf, input.conf, scripts and shaders now explain what you can do with them."),
            Item(icon: "wrench.and.screwdriver", title: "14 more fixes",
                 text: "Brightness goes back when the player closes, a deleted file's progress goes with it, and more."),
        ]),
    ]

    static func release(_ version: String) -> Release? { releases.first { $0.version == version } }

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
        let newer = current.compare(last, options: .numeric) == .orderedDescending
        return Decision(show: newer && hasEntries, remember: current)
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
        let last = d.string(forKey: SettingsKey.whatsNewShown)
        var decision = decide(current: current, lastShown: last, existingInstall: usedBefore(), hasEntries: release(current) != nil)
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
    @Environment(\.dismiss) private var dismiss

    private var releases: [WhatsNew.Release] {
        all ? WhatsNew.releases : WhatsNew.release(version).map { [$0] } ?? []
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
