import SwiftUI
import UIKit
import ImageIO
import CryptoKit

/// The app's one image pipeline: memory → disk → network. Images are stored
/// on disk as downloaded and decoded off the main thread, already
/// downsampled to the size they're shown at, so a library full of posters
/// appears instantly on every launch after the first (it used to
/// re-download each one).
///
/// Pictures are also kept by what they show (`picture(forKey:)`): a tile
/// that's made again — a list redrawn, a page gone back — finds its picture
/// in the same memory at once, before any metadata lookup. Until 1.19.0
/// ThumbLoader kept those in a second cache of its own.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let memory = NSCache<NSString, UIImage>()
    private let dir: URL
    private let session: URLSession
    private let lock = NSLock()
    /// Loads under way and how many callers wait for each (1.30.4): one
    /// stops when all of them have gone, so a cancelled caller (iOS ending
    /// a background refresh) isn't held by a download nobody waits for.
    private var inflight: [String: (task: Task<UIImage?, Never>, waiting: Int)] = [:]

    private init() {
        memory.totalCostLimit = 120 * 1024 * 1024
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = nil                       // we keep our own files
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.timeoutIntervalForRequest = 20
        session = URLSession(configuration: cfg)
        // Decoded pictures are the first thing to give back when memory runs
        // short (1.26.0): they come again from disk at once. Nothing let go
        // of them, and the app was ended for memory during playback.
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in
            self?.memory.removeAllObjects()
            dlog("image", "memory warning: decoded pictures dropped")
        }
    }

    private func fileKey(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func memKey(_ url: URL, _ px: Int) -> NSString { "\(px)|\(url.absoluteString)" as NSString }

    /// Already decoded and in memory (safe to call while building a view).
    func cached(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        memory.object(forKey: memKey(url, Int(maxPixel)))
    }

    /// A picture kept for what it shows (an item's key and size), in the
    /// same memory as everything else.
    func picture(forKey key: String) -> UIImage? { memory.object(forKey: ("item|" + key) as NSString) }

    /// The pictures kept in memory, dropped (1.29.0, Fix Match: a title's tile kept its old poster). The files stay.
    func forgetPictures() { memory.removeAllObjects() }

    func remember(_ image: UIImage, forKey key: String) {
        memory.setObject(image, forKey: ("item|" + key) as NSString, cost: Self.cost(image))
    }

    private static func cost(_ img: UIImage) -> Int { Int(img.size.width * img.size.height * img.scale * img.scale * 4) }

    func image(_ url: URL, maxPixel: CGFloat) async -> UIImage? {
        let px = Int(maxPixel)
        let mk = memKey(url, px)
        if let m = memory.object(forKey: mk) { return m }
        let key = "\(px)|\(url.absoluteString)"
        let file = dir.appendingPathComponent(fileKey(url))
        let img = await joinLoad(key) { [session] in
            Task.detached(priority: .userInitiated) { await Self.load(url, file: file, maxPixel: maxPixel, session: session) }
        }
        if let img { memory.setObject(img, forKey: mk, cost: Self.cost(img)) }
        return img
    }

    /// Joins the load under way for `key`, or starts one. A caller that's
    /// cancelled stops waiting at once and, the last to go, stops the load
    /// (1.30.4: the loads were detached, out of cancellation's reach).
    private func joinLoad(_ key: String, start: () -> Task<UIImage?, Never>) async -> UIImage? {
        if Task.isCancelled { return nil }
        lock.lock()
        let task: Task<UIImage?, Never>
        if let out = inflight[key] {
            task = out.task
            inflight[key]?.waiting += 1
        } else {
            task = start()
            inflight[key] = (task, 1)
        }
        lock.unlock()
        let gate = WaitGate()
        let img = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<UIImage?, Never>) in
                gate.set(c)
                Task { gate.resume(await task.value) }
            }
        } onCancel: {
            gate.resume(nil)
            self.leave(key, task)
        }
        // Answered (not given up): the load is over, for everyone. A caller
        // that gave up was counted out by `leave`.
        let gaveUp = Task.isCancelled
        lock.lock()
        if !gaveUp, inflight[key]?.task == task { inflight[key] = nil }
        lock.unlock()
        return img
    }

    private func leave(_ key: String, _ task: Task<UIImage?, Never>) {
        lock.lock(); defer { lock.unlock() }
        guard var out = inflight[key], out.task == task else { return }
        out.waiting -= 1
        if out.waiting <= 0 { task.cancel(); inflight[key] = nil } else { inflight[key] = out }
    }

    /// A continuation resumed once: by the load's answer or by cancellation, whichever is first.
    private final class WaitGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<UIImage?, Never>?
        private var answer: UIImage??

        func set(_ c: CheckedContinuation<UIImage?, Never>) {
            lock.lock()
            if let answer { lock.unlock(); c.resume(returning: answer); return }
            continuation = c
            lock.unlock()
        }

        func resume(_ image: UIImage?) {
            lock.lock()
            guard answer == nil else { lock.unlock(); return }
            answer = .some(image)
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: image)
        }
    }

    /// The stored file, else a download. Only data that decodes is kept on
    /// disk: an error page or a cut-off download used to be saved and then
    /// fail on every launch. A stored file that no longer decodes is dropped
    /// and fetched again.
    private static func load(_ url: URL, file: URL, maxPixel: CGFloat, session: URLSession) async -> UIImage? {
        if let data = try? Data(contentsOf: file) {
            if let img = downsample(data, maxPixel: maxPixel) { return img }
            try? FileManager.default.removeItem(at: file)
        }
        // Everyone waiting has gone (1.30.4): no download.
        if Task.isCancelled { return nil }
        guard let (d, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true, !d.isEmpty,
              let img = downsample(d, maxPixel: maxPixel) else { return nil }
        try? d.write(to: file, options: .atomic)
        return img
    }

    /// Decodes at (at most) `maxPixel` on the long side, fully decoded now
    /// so drawing it on the main thread costs nothing.
    static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let signpost = LibTrace.image.begin("decode")
        defer { LibTrace.image.end("decode", signpost) }
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixel),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// A title's poster, kept on disk under the title's id (an IMDb id when
    /// there is one), not its address: Home's library and the Real-Debrid
    /// library show the same picture for the same title, whichever source
    /// (IMDb, TMDB) brought it first.
    func poster(id: String, url: URL, maxPixel: CGFloat) async -> UIImage? {
        let px = Int(maxPixel)
        let key = "poster|\(id)|\(px)"
        if let m = picture(forKey: key) { return m }
        let file = dir.appendingPathComponent("poster-" + SHA256.hash(data: Data(id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined())
        let img = await joinLoad(key) { [session] in
            Task.detached(priority: .userInitiated) { await Self.load(url, file: file, maxPixel: maxPixel, session: session) }
        }
        if let img { remember(img, forKey: key) }
        return img
    }

    /// Already in memory (safe while building a view).
    func cachedPoster(id: String, maxPixel: CGFloat) -> UIImage? { picture(forKey: "poster|\(id)|\(Int(maxPixel))") }

    /// Size in bytes of the artwork cache on disk.
    func diskSize() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// The folder is moved aside at once and deleted in the background:
    /// thousands of pictures kept the screen frozen (review, 5 Nov).
    func clear() {
        memory.removeAllObjects()
        let fm = FileManager.default
        let old = dir.deletingLastPathComponent().appendingPathComponent("artwork-old-\(UUID().uuidString)", isDirectory: true)
        if (try? fm.moveItem(at: dir, to: old)) != nil {
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: old) }
        } else {
            try? fm.removeItem(at: dir)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

/// Drop-in for AsyncImage backed by `ImageCache`.
struct CachedImage<Content: View, Placeholder: View>: View {
    let url: URL?
    var maxPixel: CGFloat = 900
    @ViewBuilder var content: (Image) -> Content
    @ViewBuilder var placeholder: () -> Placeholder
    /// Kept with its address: a view given a new address (a reused row) shows
    /// the placeholder, not the last title's picture, until the new one loads.
    @State private var loaded: (url: URL, image: UIImage)?

    private var shown: UIImage? {
        guard let url else { return nil }
        if let loaded, loaded.url == url { return loaded.image }
        return ImageCache.shared.cached(url, maxPixel: maxPixel)
    }

    var body: some View {
        Group {
            if let img = shown { content(Image(uiImage: img)) } else { placeholder() }
        }
        .task(id: url) {
            guard let url else { loaded = nil; return }
            if let c = ImageCache.shared.cached(url, maxPixel: maxPixel) { loaded = (url, c); return }
            guard let img = await ImageCache.shared.image(url, maxPixel: maxPixel) else { return }
            withAnimation(.easeOut(duration: 0.2)) { loaded = (url, img) }
        }
    }
}
