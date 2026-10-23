import SwiftUI

/// A language as mpv matches it: every code a track may be tagged with.
struct PlaybackLanguage: Identifiable, Hashable {
    let name: String
    let codes: [String]
    var id: String { codes.first ?? name }

    static let all: [PlaybackLanguage] = [
        .init(name: "English", codes: ["eng", "en"]),
        .init(name: "Japanese", codes: ["jpn", "ja"]),
        .init(name: "Arabic", codes: ["ara", "ar"]),
        .init(name: "Bengali", codes: ["ben", "bn"]),
        .init(name: "Chinese", codes: ["chi", "zho", "zh"]),
        .init(name: "Czech", codes: ["cze", "ces", "cs"]),
        .init(name: "Danish", codes: ["dan", "da"]),
        .init(name: "Dutch", codes: ["dut", "nld", "nl"]),
        .init(name: "Filipino", codes: ["fil", "tgl", "tl"]),
        .init(name: "Finnish", codes: ["fin", "fi"]),
        .init(name: "French", codes: ["fre", "fra", "fr"]),
        .init(name: "German", codes: ["ger", "deu", "de"]),
        .init(name: "Greek", codes: ["gre", "ell", "el"]),
        .init(name: "Hebrew", codes: ["heb", "he"]),
        .init(name: "Hindi", codes: ["hin", "hi"]),
        .init(name: "Hungarian", codes: ["hun", "hu"]),
        .init(name: "Indonesian", codes: ["ind", "id"]),
        .init(name: "Italian", codes: ["ita", "it"]),
        .init(name: "Korean", codes: ["kor", "ko"]),
        .init(name: "Malay", codes: ["may", "msa", "ms"]),
        .init(name: "Norwegian", codes: ["nor", "nob", "no", "nb"]),
        .init(name: "Persian", codes: ["per", "fas", "fa"]),
        .init(name: "Polish", codes: ["pol", "pl"]),
        .init(name: "Portuguese", codes: ["por", "pt"]),
        .init(name: "Punjabi", codes: ["pan", "pa"]),
        .init(name: "Romanian", codes: ["rum", "ron", "ro"]),
        .init(name: "Russian", codes: ["rus", "ru"]),
        .init(name: "Spanish", codes: ["spa", "es"]),
        .init(name: "Swedish", codes: ["swe", "sv"]),
        .init(name: "Tamil", codes: ["tam", "ta"]),
        .init(name: "Telugu", codes: ["tel", "te"]),
        .init(name: "Thai", codes: ["tha", "th"]),
        .init(name: "Turkish", codes: ["tur", "tr"]),
        .init(name: "Ukrainian", codes: ["ukr", "uk"]),
        .init(name: "Urdu", codes: ["urd", "ur"]),
        .init(name: "Vietnamese", codes: ["vie", "vi"]),
    ]

    /// Parses mpv's comma list ("jpn,ja,eng,en") into languages, in order.
    /// Codes we don't know stay as their own entry.
    static func parse(_ list: String) -> [PlaybackLanguage] {
        var out: [PlaybackLanguage] = []
        for raw in list.split(separator: ",") {
            let code = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard !code.isEmpty else { continue }
            if let l = all.first(where: { $0.codes.contains(code) }) {
                if !out.contains(l) { out.append(l) }
            } else if !out.contains(where: { $0.codes == [code] }) {
                out.append(PlaybackLanguage(name: code, codes: [code]))
            }
        }
        return out
    }

    static func join(_ langs: [PlaybackLanguage]) -> String { langs.flatMap(\.codes).joined(separator: ",") }

    static func summary(_ list: String) -> String {
        let l = parse(list)
        if l.isEmpty { return "Track default" }
        return l.prefix(3).map(\.name).joined(separator: ", ") + (l.count > 3 ? " +\(l.count - 3)" : "")
    }
}

/// Ordered list of preferred languages for audio or subtitles: the first one
/// a file has is picked. Drag to reorder, swipe to remove.
struct LanguageListEditor: View {
    let title: String
    let explanation: String
    @Binding var list: String
    @State private var langs: [PlaybackLanguage] = []
    @State private var adding = false

    var body: some View {
        List {
            Section {
                if langs.isEmpty {
                    Text("None — the file's default track is used").foregroundStyle(.secondary)
                }
                ForEach(Array(langs.enumerated()), id: \.element.id) { i, l in
                    HStack {
                        Text("\(i + 1)").font(.subheadline.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.accent).frame(width: 22)
                        Text(l.name)
                        Spacer()
                        Text(l.codes.first ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .onMove { from, to in langs.move(fromOffsets: from, toOffset: to); save() }
                .onDelete { idx in langs.remove(atOffsets: idx); save() }
                Button { adding = true } label: { Label("Add language", systemImage: "plus.circle.fill") }
            } footer: { Text(explanation) }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { langs = PlaybackLanguage.parse(list) }
        .sheet(isPresented: $adding) {
            NavigationStack {
                List(PlaybackLanguage.all.filter { !langs.contains($0) }) { l in
                    Button {
                        langs.append(l); save(); adding = false
                    } label: { Text(l.name).foregroundStyle(.primary) }
                }
                .navigationTitle("Add language")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { adding = false } } }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func save() { list = PlaybackLanguage.join(langs) }
}
