import Foundation

enum SettingsKey {
    // Playback
    static let hwdec = "hwdec"                       // "auto" | "copy" | "no"
    static let resumePlayback = "resumePlayback"
    static let defaultSpeed = "defaultSpeed"
    static let seekStep = "seekStep"
    static let autoplayNext = "autoplayNext"
    static let backgroundAudio = "backgroundAudio"
    static let holdToSpeed = "holdToSpeed"
    static let holdSpeedValue = "holdSpeedValue"
    static let cacheMB = "cacheMB"
    static let landscapeOnOpen = "landscapeOnOpen"

    // PiP
    static let pipEnabled = "pipEnabled"
    static let pipAuto = "pipAuto"

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
    static let logLevel = "logLevel"

    // Library
    static let cleanTitles = "cleanTitles"
    static let showOnlyMedia = "showOnlyMedia"
    static let folderSorts = "folderSorts"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            hwdec: "auto",
            resumePlayback: true,
            defaultSpeed: 1.0,
            seekStep: 10,
            autoplayNext: true,
            backgroundAudio: true,
            holdToSpeed: true,
            holdSpeedValue: 2.0,
            cacheMB: 150,
            landscapeOnOpen: true,
            pipEnabled: true,
            pipAuto: true,
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
            logLevel: "info",
            cleanTitles: true,
            showOnlyMedia: false,
        ])
    }
}
