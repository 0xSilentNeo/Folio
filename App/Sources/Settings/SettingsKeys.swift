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

    // PiP
    static let pipEnabled = "pipEnabled"
    static let pipAuto = "pipAuto"
    static let pipReturnOnOpen = "pipReturnOnOpen"      // opening the app ends PiP, video continues in the player

    // Subtitles / audio
    static let subLangs = "subLangs"
    static let audioLangs = "audioLangs"
    static let subScale = "subScale"
    static let subBold = "subBold"
    static let subBox = "subBox"
    static let subPos = "subPos"

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
    static let renderer = "renderer"            // "metal" | "gl"
    static let hdrOutput = "hdrOutput"
    static let surroundAudio = "surroundAudio"
    static let anime4kMode = "anime4kMode"
    static let anime4kQuality = "anime4kQuality"
    static let enhancedQuality = "enhancedQuality"     // 1.9.x; superseded by pictureMode
    static let pictureMode = "pictureMode"             // efficient | balanced | enhanced
    static let audioBoost = "audioBoost"          // 0 | 50 | 100 (percent)
    static let playbackMode = "playbackMode"      // playlist | single | loop
    static let logLevel = "logLevel"

    // Library
    static let cleanTitles = "cleanTitles"
    static let showOnlyMedia = "showOnlyMedia"
    static let folderSorts = "folderSorts"

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
            downloadConcurrent: 2,
            downloadAutoStart: true,
            downloadSaveTo: "folder",
            downloadSkipExisting: true,
            downloadNotify: true,
            downloadCellular: false,
            downloadPauseLowPower: true,
            downloadOnlyCharging: false,
            downloadRetries: 3,
            pipEnabled: true,
            pipAuto: true,
            pipReturnOnOpen: true,
            subLangs: "eng,en",
            audioLangs: "eng,en",
            subScale: 1.0,
            subBold: true,
            subBox: false,
            subPos: 100,
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
        ])
    }
}
