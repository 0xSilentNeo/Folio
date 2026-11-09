import SwiftUI

/// Settings → About Folio (1.26.1): the version, what's new, where the mpv
/// folder is, and the work Folio is built on (the FOLIO card and scattered
/// footers until then; the engine's licences had no home). 1.27.0: no link
/// to Folio's own source.
struct AboutSettings: View {
    @State private var whatsNew = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? ""
        let b = info?["CFBundleVersion"] as? String ?? ""
        return b.isEmpty || b == v ? v : "\(v) (\(b))"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    FolioLeaf().frame(width: 44, height: 44)
                    Wordmark(size: 22)
                    Text("All your media, together.").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
                .accessibilityElement(children: .combine)
            }
            Section {
                LabeledContent("Version", value: version)
                Button("What's New") { whatsNew = true }
                LabeledContent("mpv folder") {
                    Text("Files → On My iPhone → Folio → mpv").multilineTextAlignment(.trailing)
                }
            }
            Section {
                ForEach(Self.engine, id: \.name) { credit($0) }
            } header: { Text("Playback Engine") }
            Section {
                ForEach(Self.data, id: \.name) { credit($0) }
            } header: { Text("Data") } footer: {
                Text("Titles, posters and ratings come from IMDb, or from TMDB with your own key. This product uses the TMDB API but is not endorsed or certified by TMDB.")
            }
        }
        .navigationTitle("About Folio")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $whatsNew) { WhatsNewSheet(all: true) }
    }

    private func credit(_ c: Credit) -> some View {
        Link(destination: c.url) {
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name).foregroundStyle(.primary)
                Text(c.detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    struct Credit {
        let name: String
        let detail: String
        let url: URL
    }

    private static let engine: [Credit] = [
        Credit(name: "mpv", detail: "Playback engine · LGPL 2.1+ / GPL", url: URL(string: "https://mpv.io")!),
        Credit(name: "FFmpeg", detail: "Demuxing and decoding · built as GPL v3", url: URL(string: "https://ffmpeg.org")!),
        Credit(name: "libplacebo", detail: "GPU rendering · LGPL 2.1+", url: URL(string: "https://code.videolan.org/videolan/libplacebo")!),
        Credit(name: "libass", detail: "Styled subtitles · ISC", url: URL(string: "https://github.com/libass/libass")!),
        Credit(name: "MoltenVK", detail: "Vulkan on Metal · Apache 2.0", url: URL(string: "https://github.com/KhronosGroup/MoltenVK")!),
        Credit(name: "MPVKit", detail: "Engine build system · LGPL / GPL", url: URL(string: "https://github.com/mpvkit/MPVKit")!),
        Credit(name: "Anime4K", detail: "Upscaling shaders · MIT", url: URL(string: "https://github.com/bloc97/Anime4K")!),
        Credit(name: "FSRCNNX", detail: "Upscaling shader · MIT", url: URL(string: "https://github.com/igv/FSRCNN-TensorFlow")!),
    ]

    private static let data: [Credit] = [
        Credit(name: "TVmaze", detail: "Series schedules · CC BY-SA", url: URL(string: "https://www.tvmaze.com")!),
        Credit(name: "AniList", detail: "Anime schedules, ids and sync", url: URL(string: "https://anilist.co")!),
        Credit(name: "AniSkip", detail: "Anime opening and ending times", url: URL(string: "https://aniskip.com")!),
        Credit(name: "Open Anime Timestamps", detail: "Anime opening times", url: URL(string: "https://github.com/jonbarrow/open-anime-timestamps")!),
        Credit(name: "ids.moe", detail: "Anime id mapping", url: URL(string: "https://ids.moe")!),
        Credit(name: "Stremio addon protocol", detail: "Addons", url: URL(string: "https://github.com/Stremio/stremio-addon-sdk")!),
    ]
}
