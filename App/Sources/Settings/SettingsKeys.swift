import Foundation

enum SettingsKey {
    // Playback
    static let hwdec = "hwdec"                       // "auto" | "copy" | "no"
    static let openTitlePage = "openTitlePage"
    static let resumePlayback = "resumePlayback"
    static let defaultSpeed = "defaultSpeed"
    static let seekStep = "seekStep"
    static let autoplayNext = "autoplayNext"
    static let upNextEnabled = "upNextEnabled"
    static let seekBackStep = "seekBackStep"
    static let gestureControl = "gestureControl"
    static let subtitlesDefault = "subtitlesDefault"   // on | off
    static let downmixNormalize = "downmixNormalize"
    static let lfeInDownmix = "lfeInDownmix"
    static let startupTab = "startupTab"
    static let appearance = "appearance"             // system | light | dark
    static let metadataFetching = "metadataFetching"
    static let showRatings = "showRatings"
    static let hideSpoilers = "hideSpoilers"
    static let backgroundAudio = "backgroundAudio"
    static let holdToSpeed = "holdToSpeed"
    static let holdSpeedValue = "holdSpeedValue"
    static let cacheMB = "cacheMB"
    static let landscapeOnOpen = "landscapeOnOpen"
    static let stayLandscape = "stayLandscape"          // player never turns to portrait
    static let controlsWidth = "controlsWidth"
    static let nativePanelMorph = "nativePanelMorph"    // iOS 26: system popover morph (true) or the app's SwiftUI glass
    static let tileArtwork = "tileArtwork"              // poster | frame
    static let castPosition = "castPosition"            // top | bottom (title pages)
    static let episodeTitleLanguage = "episodeTitleLanguage"   // english | original
    static let playlistNames = "playlistNames"          // "episode" | "filename"
    static let titlePageStyle = "titlePageStyle"        // full | files (title, then its files only)
    static let listTransition = "listTransition"        // thumb | row | push: how a page opens from a Home list row
    static let prepareNext = "prepareNext"              // addon seasons: find and load the next episode before it's needed
    static let rememberPerShow = "rememberPerShow"      // 1.20.3: tracks, delays, Fill, Anime4K per show (ShowMemory)

    // Downloads (WebDAV)
    static let downloadConcurrent = "downloadConcurrent"
    static let downloadAutoStart = "downloadAutoStart"
    static let downloadSaveTo = "downloadSaveTo"          // folder | root
    static let downloadSkipExisting = "downloadSkipExisting"
    static let downloadNotify = "downloadNotify"
    static let downloadCellular = "downloadCellular"
    static let downloadPauseLowPower = "downloadPauseLowPower"
    static let downloadOnlyCharging = "downloadOnlyCharging"
    static let downloadRetries = "downloadRetries"
    static let downloadNextEpisodes = "downloadNextEpisodes"    // 1.22.0: 0 (off) | 1 | 2 | 3 episodes after one watched past 70% (AutoDownload)
    static let downloadDeleteWatched = "downloadDeleteWatched"  // 1.22.0: 0 (off) | 1 | 7 days after a downloaded file was finished (WatchedCleanup)
    static let liveActivities = "liveActivities"                // 1.22.0: downloads and now playing on the Lock Screen and Dynamic Island
    static let downloadParts = "downloadParts"                  // 1.22.1: 1...8 connections per file (byte ranges side by side); 8 by default since 1.22.3

    // PiP
    static let pipEnabled = "pipEnabled"
    static let pipAuto = "pipAuto"
    static let pipReturnOnOpen = "pipReturnOnOpen"      // opening the app ends PiP, video continues in the player
    static let pipTrace = "pipTrace"                    // Diagnostics: trace PiP transitions (PiPTrace)
    static let netTrace = "netTrace"                    // Diagnostics: time every addon request (NetTrace)
    static let libTrace = "libTrace"                    // Diagnostics: library, artwork and Discover trace (LibTrace)

    // Subtitles / audio
    static let subLangs = "subLangs"
    static let audioLangs = "audioLangs"
    static let subScale = "subScale"
    static let subBold = "subBold"
    static let subBox = "subBox"
    static let subPos = "subPos"
    static let subStyle = "subStyle"                    // default | large | yellow | boxed (SubtitleStyle)
    static let nightMode = "nightMode"                  // 1.20.3: audio range compression (AudioFilters)
    static let dialogueBoost = "dialogueBoost"          // 1.20.3: centre channel / voice band up (AudioFilters)

    // Skip
    static let skipEnabled = "skipEnabled"
    static let skipAutoIntro = "skipAutoIntro"
    static let skipAutoOutro = "skipAutoOutro"
    static let skipAutoRecap = "skipAutoRecap"
    static let skipAutoPreview = "skipAutoPreview"
    static let skipUseChapters = "skipUseChapters"
    static let skipInjectChapters = "skipInjectChapters"
    static let skipOATLength = "skipOATLength"

    // mpv
    static let activeShaders = "activeShaders"
    static let scriptCommands = "scriptCommands"
    static let flipVideo = "flipVideo"
    static let renderer = "renderer"            // "metal" (default) | "gl"
    static let hdrOutput = "hdrOutput"
    static let surroundAudio = "surroundAudio"
    static let anime4kMode = "anime4kMode"
    static let anime4kQuality = "anime4kQuality"
    static let enhancedQuality = "enhancedQuality"     // 1.9.x; superseded by pictureMode
    static let pictureMode = "pictureMode"             // efficient | balanced | enhanced
    static let audioBoost = "audioBoost"          // 0 | 50 | 100 (percent)
    static let playbackMode = "playbackMode"      // playlist | single | loop
    static let logLevel = "logLevel"

    // Tracking (1.21.0)
    static let airingAlerts = "airingAlerts"            // air | hour | off: new-episode notifications (AiringAlerts)

    // Library
    static let cleanTitles = "cleanTitles"
    static let showOnlyMedia = "showOnlyMedia"
    static let folderSorts = "folderSorts"
    static let folderSortLast = "folderSortLast"         // WebDAV: the last sort chosen, for folders without their own
    // 1.22.0: Home's library filters (LibraryFilter); "" is "any".
    static let libraryFilterWatch = "libraryFilterWatch"     // all | unwatched | inProgress | watched
    static let libraryFilterGenre = "libraryFilterGenre"
    static let libraryFilterYear = "libraryFilterYear"

    // Kids profile (1.22.0, KidsProfile). No registered defaults on purpose:
    // registered keys go into presets, and a preset must never turn it off.
    static let kidsProfile = "kidsProfile"
    static let kidsFilmLimit = "kidsFilmLimit"           // G | PG | PG-13
    static let kidsShowLimit = "kidsShowLimit"           // TV-Y | TV-Y7 | TV-G | TV-PG
    static let kidsBiometrics = "kidsBiometrics"         // Face ID / Touch ID may stand in for the passcode

    // What's new (1.22.0): the last version whose sheet was shown.
    static let whatsNewShown = "whatsNewShown"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            hwdec: "auto",
            resumePlayback: true,
            openTitlePage: true,
            defaultSpeed: 1.0,
            seekStep: 10,
            autoplayNext: true,
            upNextEnabled: true,
            seekBackStep: 10,
            gestureControl: true,
            subtitlesDefault: "on",
            downmixNormalize: false,
            lfeInDownmix: false,
            startupTab: 0,
            metadataFetching: true,
            showRatings: true,
            hideSpoilers: false,
            backgroundAudio: true,
            holdToSpeed: true,
            holdSpeedValue: 2.0,
            cacheMB: 150,
            landscapeOnOpen: true,
            stayLandscape: false,
            controlsWidth: 0.8,
            nativePanelMorph: true,
            tileArtwork: "poster",
            castPosition: "bottom",
            episodeTitleLanguage: "english",
            playlistNames: "episode",
            titlePageStyle: "full",
            prepareNext: true,
            rememberPerShow: true,
            downloadConcurrent: 2,
            downloadAutoStart: true,
            downloadSaveTo: "folder",
            downloadSkipExisting: true,
            downloadNotify: true,
            downloadCellular: false,
            downloadPauseLowPower: true,
            downloadOnlyCharging: false,
            downloadRetries: 3,
            downloadNextEpisodes: 0,
            downloadDeleteWatched: 0,
            downloadParts: 8,
            liveActivities: true,
            pipEnabled: true,
            pipAuto: true,
            pipReturnOnOpen: true,
            subLangs: "eng,en",
            audioLangs: "eng,en",
            subScale: 1.0,
            subBold: true,
            subBox: false,
            subPos: 100,
            subStyle: "default",
            nightMode: false,
            dialogueBoost: false,
            skipEnabled: true,
            skipAutoIntro: false,
            skipAutoOutro: false,
            skipAutoRecap: false,
            skipAutoPreview: false,
            skipUseChapters: true,
            skipInjectChapters: true,
            skipOATLength: 90,
            flipVideo: false,
            renderer: "metal",
            hdrOutput: true,
            surroundAudio: true,
            anime4kMode: "off",
            anime4kQuality: "fast",
            enhancedQuality: false,
            audioBoost: 0,
            playbackMode: "playlist",
            logLevel: "info",
            cleanTitles: true,
            showOnlyMedia: false,
            airingAlerts: "air",
        ])
        // 1.22.1: Metal is the default again. 1.22.0 moved everyone to the
        // OpenGL renderer, which some files didn't play on (user report,
        // 4 Nov); those moved are moved back, once. A later choice stays.
        let d = UserDefaults.standard
        if d.bool(forKey: "rendererMovedToStandard"), !d.bool(forKey: "rendererBackToMetal") {
            d.set(true, forKey: "rendererBackToMetal")
            if d.string(forKey: renderer) == "gl" { d.set("metal", forKey: renderer) }
        }
    }
}
