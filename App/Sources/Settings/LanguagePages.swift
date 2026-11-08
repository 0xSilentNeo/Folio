import SwiftUI

/// Audio & Subtitles → Audio Languages, as a page of its own (1.26.1: pushed by value).
struct AudioLanguagesPage: View {
    @AppStorage(SettingsKey.audioLangs) private var audioLangs = "eng,en"
    var body: some View {
        LanguageListEditor(title: "Audio Languages",
                           explanation: "When a file has several audio tracks, the first language on this list that the file has is played. With none of them, the file's default track plays.",
                           list: $audioLangs)
    }
}

/// Audio & Subtitles → Subtitle Languages.
struct SubtitleLanguagesPage: View {
    @AppStorage(SettingsKey.subLangs) private var subLangs = "eng,en"
    var body: some View {
        LanguageListEditor(title: "Subtitle Languages",
                           explanation: "The first language on this list that the file has subtitles in is shown. Subtitles can always be switched in the player's Tracks menu.",
                           list: $subLangs)
    }
}
