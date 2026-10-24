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
    static let panelTransition = "panelTransition"      // quick | morph | morphFrozen
    static let tileArtwork = "tileArtwork"              // poster | frame
    static let castPosition = "castPosition"            // top | bottom (title pages)
    static let playlistNames = "playlistNames"          // "episode" | "filename"

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
            panelTransition: "quick",
            tileArtwork: "poster",
            castPosition: "bottom",
            playlistNames: "episode",
            pipEnabled: true,
            pipAuto: true,
            pipReturnOnOpen: true,
            subLangs: "eng,en",
            audioLangs: "jpn,ja,eng,en",
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
