import Foundation

/// What Settings' search finds (1.26.1): every setting by the name its page
/// shows, with the words people use for it, and the page it's on. A result
/// opens that page; the setting isn't scrolled to.
enum SettingsIndex {
    struct Entry: Identifiable, Hashable {
        let title: String
        /// The root page it's under: the result's tile, and where it is.
        let page: SettingsPage
        let keywords: String
        let route: LibraryRoute

        var id: String { title + "|" + page.rawValue }

        /// The root page's name, shown under the title.
        var location: String { page.title }
    }

    /// Every word of the query has to be in the title or the keywords (not
    /// the page's name: "subtitle" listed every setting on Audio & Subtitles);
    /// titles that start with the query come first.
    static func search(_ query: String) -> [Entry] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let found = all.filter { e in
            let text = "\(e.title) \(e.keywords)"
            return words.allSatisfy { text.localizedStandardContains($0) }
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        func rank(_ e: Entry) -> Int {
            if e.title.lowercased().hasPrefix(q.lowercased()) { return 0 }
            if e.title.localizedStandardContains(q) { return 1 }
            return 2
        }
        return found.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    private static func e(_ title: String, _ page: SettingsPage, _ keywords: String = "", _ sub: SettingsSubpage? = nil) -> Entry {
        Entry(title: title, page: page, keywords: keywords, route: sub.map { .settingsSubpage($0) } ?? .settingsPage(page))
    }

    static let all: [Entry] = pages + notifications + sync + settings

    /// The root pages themselves.
    private static let pages: [Entry] = SettingsPage.allCases.map { e($0.title, $0) }

    private static let notifications: [Entry] = NotifyGroup.allCases.map {
        e($0.title, .notifications, "notification alert \($0.subtitle)", .notifyGroup($0))
    }

    private static let sync: [Entry] = SyncService.allCases.map {
        e($0.name, .sync, "sync scrobble account sign in connect", .syncService($0))
    }

    private static let settings: [Entry] = [
        // General
        e("Appearance", .general, "theme dark light mode colour"),
        e("Startup Page", .general, "open launch first tab home discover network"),
        e("Open Title Page on Tap", .general, "tile details play"),
        e("Hide Spoilers", .general, "episode titles thumbnails blur"),
        e("IMDb Ratings", .general, "score stars"),
        e("Cast on Title Pages", .general, "actors people"),
        e("Episode Titles", .general, "names spoilers"),

        // Notifications
        e("Personality", .notifications, "tone subtle balanced wording notification"),
        e("Quiet Hours", .notifications, "do not disturb night sleep notification"),
        e("Notifications a Day", .notifications, "at most limit daily how many"),
        e("Notification Sounds", .notifications, "tone sound alert", .notifySounds),
        e("Weather City", .notifications, "just for fun weather location", .notifyCity),
        e("Notification Test", .help, "try every kind send now debug", .notifyTest),
        e("Sent Notifications", .notifications, "history log test", .notifySent),

        // Kids Profile
        e("Change Passcode", .kids, "kids pin code lock"),
        e("Age Ratings", .kids, "films shows up to rating parental children"),

        // Playback
        e("Resume Where I Left Off", .playback, "continue position"),
        e("Remember Per Show", .playback, "tracks delay fill anime4k each show"),
        e("Remembered Shows", .playback, "per show forget", .rememberedShows),
        e("Play Next File Automatically", .playback, "autoplay next episode"),
        e("Up Next Card", .playback, "credits countdown next episode"),
        e("Get the Next Episode Ready", .playback, "prepare preload debrid addon"),
        e("Open in Landscape", .playback, "rotate orientation"),
        e("Stay in Landscape", .playback, "rotate orientation lock"),
        e("Keep Audio Playing in Background", .playback, "background audio lock screen"),
        e("Forward & Backward Skip", .playback, "double tap seek step seconds jump"),
        e("Swipe Gestures", .playback, "seek volume brightness"),
        e("Hold to Speed Up", .playback, "fast 2x press"),
        e("Default Speed", .playback, "playback rate"),
        e("Playlist Names", .playback, "episode file names"),
        e("Controls Width", .playback, "player buttons size"),
        e("Progress Bar", .playback, "seek bar chapter markers marker colour scrubbing skip segments"),
        e("Picture in Picture", .playback, "pip automatically leaving"),

        // Audio & Subtitles
        e("Audio Languages", .audioSubtitles, "preferred audio track dub", .audioLanguages),
        e("Surround & Spatial Audio", .audioSubtitles, "downmix 5.1 7.1 lfe stereo"),
        e("Night Mode", .audioSubtitles, "dynamic range compression loudness quiet"),
        e("Dialogue Boost", .audioSubtitles, "voice speech louder"),
        e("Show Subtitles", .audioSubtitles, "captions on off"),
        e("Subtitle Languages", .audioSubtitles, "preferred subtitle track captions", .subtitleLanguages),
        e("Subtitle Style", .audioSubtitles, "size bold background box font captions zoomed"),

        // Skip Intro & Credits
        e("Skip Button", .skip, "intro outro credits recap preview opening ending"),
        e("Skip Automatically", .skip, "auto intro credits"),
        e("Skip Sources", .skip, "file chapters online markers aniskip"),
        e("Hide Intros I Watch", .skip, "intro watched"),
        e("Find Intros on This iPhone", .skip, "intro on device local sound audio compare episodes"),

        // Video Engine
        e("Renderer", .engine, "vulkan opengl metal gpu"),
        e("Picture", .engine, "efficient balanced enhanced quality battery"),
        e("HDR Output", .engine, "dolby vision tone mapping brightness"),
        e("Hardware Decoding", .engine, "videotoolbox hwdec decoder"),
        e("Flip Video", .engine, "mirror"),
        e("Streaming", .engine, "cache buffer network readahead"),
        e("Scripts", .engine, "lua mpv", .scripts),
        e("Shaders", .engine, "anime4k glsl upscaling sharpen", .shaders),
        e("mpv.conf", .engine, "config options", .config(MPVFiles.mpvConf, "mpv.conf", true)),
        e("input.conf", .engine, "keys bindings keyboard", .config(MPVFiles.inputConf, "input.conf", true)),
        e("script-opts", .engine, "script options conf", .scriptOptions),
        e("Player Commands", .engine, "keyboard shortcuts custom buttons", .commands),
        e("Last Playback Log", .engine, "log errors mpv", .playbackLog),

        // Library
        e("Scan for Changes", .library, "rescan files media folder"),
        e("Refresh Metadata", .library, "posters titles tmdb tvmaze"),
        e("Metadata Fetching", .library, "tmdb tvmaze anilist online"),
        e("Tile Artwork", .library, "poster thumbnail backdrop"),
        e("Clear Artwork Cache", .library, "storage images space"),
        e("Clear Watch History", .library, "history progress storage"),

        // Discover
        e("Airing Now", .discover, "currently airing series anime row"),
        e("Discover Rows", .discover, "sections trending popular"),
        e("Discover Language", .discover, "region country"),
        e("Top Rated Minimum Votes", .discover, "imdb rating votes"),
        e("TMDB API Key", .discover, "themoviedb v3 key discover source", .addons),
        e("Discover's Titles", .discover, "source cinemeta tmdb imdb order 250", .addons),
        e("Cinemeta", .discover, "install discover source catalog", .addons),
        e("Streaming Services", .discover, "platforms netflix disney prime"),
        e("Addons", .discover, "stremio catalogs streams", .addons),

        // Downloads
        e("Start Downloads Automatically", .downloads, "queue"),
        e("Save Downloads To", .downloads, "folder location files"),
        e("Use Mobile Data", .downloads, "cellular network"),
        e("Pause in Low Power Mode", .downloads, "battery"),
        e("Only While Charging", .downloads, "battery power"),
        e("Download Next Episodes", .downloads, "automatic offline"),
        e("Delete Watched Downloads", .downloads, "automatic storage space"),
        e("Live Activities", .downloads, "lock screen dynamic island progress"),

        // Tracked Shows
        e("New Episode Alerts", .trackedShows, "notify me airing calendar notifications"),

        // Import & Export
        e("Save Settings to a File", .importExport, "backup export preset"),
        e("Load Settings from a File", .importExport, "restore import preset"),

        // Help & Diagnostics
        e("Diagnostics & Report", .help, "bug report logs energy cpu battery", .diagnostics),
        e("Native Menu Morph", .help, "experimental animation"),

        // About
        e("Version", .about, "build number"),
        e("What's New", .about, "release notes changes"),
        e("mpv Folder", .about, "files location"),
        e("Playback Engine & Data", .about, "acknowledgements licenses credits mpv ffmpeg libplacebo libass moltenvk anime4k tmdb tvmaze anilist imdb"),
    ]
}
