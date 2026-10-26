import UIKit
import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

/// Opens files coming from the picker, "Open in GlassPlayer" or the share
/// sheet: keeps the security scope, makes sure iCloud/provider files are
/// downloaded, then starts playback.
@MainActor
enum FileOpener {
    static let mediaTypes: [UTType] = [.movie, .video, .audiovisualContent, .audio, .item]

    /// Files chosen in import mode (iOS copied them into our sandbox already):
    /// move them into Documents/Media so they appear in the library. One
    /// file starts playing straight away.
    static func addFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var added: [URL] = []
        for src in urls {
            var dest = MPVFiles.mediaDir.appendingPathComponent(src.lastPathComponent)
            let isDir = (try? src.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDir {
                // A folder picked in the Files browser: iOS copied it whole; keep it as a folder in Media.
                if FileManager.default.fileExists(atPath: dest.path) {
                    let base = dest.lastPathComponent
                    var n = 2
                    repeat { dest = MPVFiles.mediaDir.appendingPathComponent("\(base) \(n)"); n += 1 } while FileManager.default.fileExists(atPath: dest.path)
                }
                do { try FileManager.default.moveItem(at: src, to: dest); dlog("open", "added folder to Media: \(dest.lastPathComponent)") }
                catch { dlog("open/error", "folder add failed: \(error.localizedDescription)") }
                continue
            }
            if FileManager.default.fileExists(atPath: dest.path) {
                // Same name already in the library: keep the existing file if it's
                // the same size, otherwise store the new one next to it.
                let a = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? -1
                let b = (try? FileManager.default.attributesOfItem(atPath: src.path)[.size] as? Int) ?? -2
                if a == b { try? FileManager.default.removeItem(at: src); added.append(dest); continue }
                let base = dest.deletingPathExtension().lastPathComponent, ext = dest.pathExtension
                var n = 2
                repeat { dest = MPVFiles.mediaDir.appendingPathComponent("\(base) \(n).\(ext)"); n += 1 } while FileManager.default.fileExists(atPath: dest.path)
            }
            do {
                try FileManager.default.moveItem(at: src, to: dest)
                added.append(dest)
                dlog("open", "added to Media: \(dest.lastPathComponent)")
            } catch {
                dlog("open/error", "add failed for \(src.lastPathComponent): \(error.localizedDescription)")
            }
        }
        LocalMediaStore.shared.refresh()
        if added.count == 1, urls.count == 1, let f = added.first, TitleParser.isMedia(f.lastPathComponent) {
            var m = MediaItem(url: f.path, title: TitleParser.clean(f.lastPathComponent), source: .local)
            m.historyKey = f.path
            PlayerPresenter.play(m)
        }
    }

    static func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        dlog("open", "open \(urls.count) url(s): \(urls.map { $0.lastPathComponent })")
        Task {
            var items: [MediaItem] = []
            for url in urls {
                if let item = await prepare(url) { items.append(item) }
            }
            if items.isEmpty {
                dlog("open/error", "no readable items")
                showAlert("Couldn't open file", "iOS didn't give Folio access to the selected file. Try copying it to On My iPhone → Folio → Media.")
                return
            }
            PlayerPresenter.play(queue: items, index: 0)
        }
    }

    private static func prepare(_ url: URL) async -> MediaItem? {
        let scoped = url.startAccessingSecurityScopedResource()
        var playURL = url
        if !FileManager.default.isReadableFile(atPath: url.path) || isCloudPlaceholder(url) {
            // Coordinated read makes the provider (iCloud Drive, SMB, …) deliver the file.
            if let coordinated = await coordinatedURL(url) { playURL = coordinated }
        }
        guard FileManager.default.fileExists(atPath: playURL.path) else {
            dlog("open/error", "file not found after coordination: \(url.path) scoped=\(scoped)")
            if scoped { url.stopAccessingSecurityScopedResource() }
            return nil
        }
        dlog("open", "prepared \(playURL.lastPathComponent) scoped=\(scoped) readable=\(FileManager.default.isReadableFile(atPath: playURL.path))")
        var m = MediaItem(url: playURL.path, title: TitleParser.clean(playURL.lastPathComponent), source: .local)
        if playURL == url, !url.path.hasPrefix(MPVFiles.documents.path) {
            m.bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        m.historyKey = "file:" + playURL.lastPathComponent
        let p = TitleParser.parse(playURL.lastPathComponent)
        if p.episode != nil { m.anime = AnimeHint(title: p.title, episode: p.episode) }
        return m
    }

    private static func isCloudPlaceholder(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        if let s = v?.ubiquitousItemDownloadingStatus, s != .current { return true }
        return false
    }

    private static func coordinatedURL(_ url: URL) async -> URL? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var err: NSError?
                var result: URL?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &err) { readURL in
                    result = readURL
                }
                cont.resume(returning: result)
            }
        }
    }

    static func showAlert(_ title: String, _ message: String) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        PlayerPresenter.topViewController()?.present(a, animated: true)
    }
}

/// Files in Documents/Media, kept live with a directory watcher so files
/// saved from the Files app appear immediately.
@MainActor
final class LocalMediaStore: ObservableObject {
    static let shared = LocalMediaStore()
    @Published private(set) var files: [URL] = []
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    private init() {
        refresh()
        watch()
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LocalMediaStore.shared.refresh() }
        }
    }

    private var scanTask: Task<Void, Never>?

    /// Lists the library off the main thread (it used to run on the main
    /// thread at launch, before Home could draw).
    func refresh() {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            let media = await Task.detached(priority: .userInitiated) { LocalMediaStore.scan() }.value
            guard let self, !Task.isCancelled else { return }
            if media != self.files { self.files = media }
        }
    }

    nonisolated static func scan() -> [URL] {
        let fm = FileManager.default
        // Media and any folders added inside it (two levels, hidden files skipped).
        var items: [(URL, Date)] = []
        if let e = fm.enumerator(at: MPVFiles.mediaDir, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let u as URL in e {
                if e.level > 2 { e.skipDescendants(); continue }
                let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey])
                if v?.isDirectory == true || !TitleParser.isMedia(u.lastPathComponent) { continue }
                items.append((u, v?.creationDate ?? .distantPast))
            }
        }
        LibraryOrganizer.warmInfo(items.map(\.0))
        return items.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private func watch() {
        let fd = open(MPVFiles.mediaDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            // Files app writes in several steps; settle before listing.
            self?.pending?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.refresh() }
            self?.pending = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: ThumbnailStore.url(for: url.path))
        refresh()
    }
}

/// Async artwork for a tile: saved player frame → explicit artwork →
/// metadata lookup from the file name → embedded frame (MP4/MOV).
@MainActor
final class ThumbLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var meta: MediaMeta?
    private static let cache = NSCache<NSString, UIImage>()
    private var loadedKey: String?

    /// Which picture a view wants from the metadata.
    enum Art { case wide, poster }

    /// - `art: .poster`: the show/film's portrait poster (library tiles). Falls
    ///   back to the backdrop, never to an episode still or a saved frame.
    /// - `art: .wide`: 16:9 art — episode still, then backdrop, then poster.
    /// Pixel width for a title page backdrop (`hero`): the art is fetched and
    /// decoded at that size instead of tile size.
    private var hero: Int?

    func load(key: String, fileURL: URL?, artwork: String?, lookupName: String? = nil, preferMeta: Bool? = nil, art: Art = .wide, hero: Int? = nil) {
        self.hero = hero
        let cacheKey = (art == .poster ? key + "|poster" : key) + (hero.map { "|hero\($0)" } ?? "")
        guard loadedKey != cacheKey else { return }
        loadedKey = cacheKey
        // Poster / episode still first (Settings → Library → Tile artwork);
        // the saved player frame is the fallback, not the default.
        let preferMeta = art == .poster || (preferMeta ?? (UserDefaults.standard.string(forKey: SettingsKey.tileArtwork) != "frame"))
        if let c = Self.cache.object(forKey: cacheKey as NSString) { image = c }
        Task {
            // Saved frame (Continue Watching) from disk, decoded off the main thread.
            if image == nil, !preferMeta, let img = await Self.decodeFile(ThumbnailStore.url(for: key)) { set(img, cacheKey) }
            if image == nil, art == .wide, let artwork, let u = URL(string: artwork) { await fetch(u, cacheKey) }
            if let lookupName {
                // Metadata is cached on disk forever; artwork on disk too (ImageCache).
                if let m = await MetadataService.shared.lookup(filename: lookupName) {
                    self.meta = m
                    let pick = art == .poster ? (m.poster ?? m.background) : m.wideArt
                    if (self.image == nil || preferMeta), let pick, let u = URL(string: pick) { await self.fetch(u, cacheKey) }
                }
            }
            if art == .poster, image == nil, let artwork, let u = URL(string: artwork) { await fetch(u, cacheKey) }
            if image == nil, artwork == nil, art == .wide, let fileURL, ["mp4", "m4v", "mov"].contains(fileURL.pathExtension.lowercased()) {
                let img: UIImage? = await Task.detached(priority: .utility) {
                    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL))
                    gen.appliesPreferredTrackTransform = true
                    gen.maximumSize = CGSize(width: 640, height: 360)
                    guard let cg = try? await gen.image(at: CMTime(seconds: 30, preferredTimescale: 600)).image else { return nil }
                    let img = UIImage(cgImage: cg)
                    if let data = img.jpegData(compressionQuality: 0.75) { try? data.write(to: ThumbnailStore.url(for: key)) }
                    return img
                }.value
                if let img, self.image == nil { set(img, cacheKey) }
            }
        }
    }

    /// Addon items ("type|metaId|videoId"): a 16:9 picture from IMDb by id —
    /// the episode still, else the title's backdrop — else the given poster.
    func loadAddonArt(key: String, ref: String, fallback: String?) {
        let cacheKey = key + "|wide"
        guard loadedKey != cacheKey else { return }
        loadedKey = cacheKey
        if let c = Self.cache.object(forKey: cacheKey as NSString) { image = c; return }
        Task {
            let parts = ref.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            var wide: String?
            if parts.count >= 3, parts[1].hasPrefix("tt") {
                let v = parts[2].split(separator: ":")
                if v.count >= 3, let season = Int(v[1]), let episode = Int(v[2]) {
                    wide = await IMDbSource.episodes(id: parts[1], season: season).first { $0.episode == episode }?.thumbnail
                }
                if wide == nil { wide = await IMDbSource.details(id: parts[1], type: parts[0])?.background }
            }
            let pick = wide.flatMap { IMDbSource.sized($0, width: 1280) } ?? fallback
            if let pick, let u = URL(string: pick) { await fetch(u, cacheKey) }
        }
    }

    private static func decodeFile(_ url: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let d = try? Data(contentsOf: url) else { return nil }
            return ImageCache.downsample(d, maxPixel: 800)
        }.value
    }

    private func fetch(_ u: URL, _ key: String) async {
        if let hero {
            // IMDb serves any width of its images (`._V1_UX…_`); other hosts are left as they are.
            let big = IMDbSource.sized(u.absoluteString, width: hero).flatMap(URL.init(string:)) ?? u
            if let img = await ImageCache.shared.image(big, maxPixel: CGFloat(hero)) { set(img, key); return }
        }
        if let img = await ImageCache.shared.image(u, maxPixel: 900) { set(img, key) }
    }

    private func set(_ img: UIImage, _ key: String) {
        Self.cache.setObject(img, forKey: key as NSString)
        if image == nil { withAnimation(.easeOut(duration: 0.2)) { image = img } } else { image = img }
    }
}

/// The Files browser as a SwiftUI view (so it can be presented in a sheet
/// with a zoom transition). Import mode: iOS copies the picked files into
/// our sandbox, which works with every provider regardless of how the app
/// was signed; `FileOpener.addFiles` then moves them into the library.
struct AddFilesPicker: UIViewControllerRepresentable {
    var onDone: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: FileOpener.mediaTypes + [.folder], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        dlog("open", "add-files picker shown")
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            dlog("open", "add-files picker returned \(urls.count) file(s)")
            onDone()
            // Let the sheet finish dismissing before the player window appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { FileOpener.addFiles(urls) }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            dlog("open", "add-files picker cancelled")
            onDone()
        }
    }
}
