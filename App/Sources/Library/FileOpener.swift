import UIKit
import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

/// UIKit document picker (more reliable than SwiftUI's fileImporter when the
/// player has to be presented right after the picker closes).
@MainActor
final class DocumentPicker: NSObject, UIDocumentPickerDelegate {
    static let shared = DocumentPicker()
    private var completion: (([URL]) -> Void)?

    func present(types: [UTType], multiple: Bool = false, completion: @escaping ([URL]) -> Void) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = multiple
        picker.shouldShowFileExtensions = true
        picker.delegate = self
        self.completion = completion
        guard let top = PlayerPresenter.topViewController() else { dlog("open/error", "no view controller to present picker"); return }
        dlog("open", "presenting document picker from \(type(of: top))")
        top.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        dlog("open", "picker returned \(urls.count) url(s)")
        let cb = completion
        completion = nil
        cb?(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        completion = nil
    }
}

/// Opens files coming from the picker, "Open in GlassPlayer" or the share
/// sheet: keeps the security scope, makes sure iCloud/provider files are
/// downloaded, then starts playback.
@MainActor
enum FileOpener {
    static let mediaTypes: [UTType] = [.movie, .video, .audiovisualContent, .audio, .item]

    static func pickAndPlay() {
        DocumentPicker.shared.present(types: mediaTypes, multiple: true) { urls in
            open(urls)
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
                showAlert("Couldn't open file", "iOS didn't give GlassPlayer access to the selected file. Try copying it to On My iPhone → GlassPlayer → Media.")
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

    func refresh() {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: MPVFiles.mediaDir, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        let media = items.filter { TitleParser.isMedia($0.lastPathComponent) }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return a > b
            }
        if media != files { files = media }
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

    func load(key: String, fileURL: URL?, artwork: String?, lookupName: String? = nil, preferMeta: Bool = false) {
        guard loadedKey != key else { return }
        loadedKey = key
        if let c = Self.cache.object(forKey: key as NSString) { image = c }
        else if let img = ThumbnailStore.image(for: key), !preferMeta { set(img, key) }
        if image == nil, let artwork, let u = URL(string: artwork) { fetch(u, key) }
        if let lookupName {
            Task {
                guard let m = await MetadataService.shared.lookup(filename: lookupName) else { return }
                self.meta = m
                if (self.image == nil || preferMeta), let art = m.wideArt, let u = URL(string: art) { self.fetch(u, key) }
            }
        }
        if image == nil, artwork == nil, let fileURL, ["mp4", "m4v", "mov"].contains(fileURL.pathExtension.lowercased()) {
            Task.detached(priority: .utility) {
                let gen = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL))
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 640, height: 360)
                if let cg = try? await gen.image(at: CMTime(seconds: 30, preferredTimescale: 600)).image {
                    let img = UIImage(cgImage: cg)
                    if let data = img.jpegData(compressionQuality: 0.75) { try? data.write(to: ThumbnailStore.url(for: key)) }
                    await MainActor.run { if self.image == nil { self.set(img, key) } }
                }
            }
        }
    }

    private func fetch(_ u: URL, _ key: String) {
        Task {
            if let r = try? await URLSession.shared.data(from: u), let img = UIImage(data: r.0) { set(img, key) }
        }
    }

    private func set(_ img: UIImage, _ key: String) {
        Self.cache.setObject(img, forKey: key as NSString)
        withAnimation(.easeOut(duration: 0.25)) { image = img }
    }
}
