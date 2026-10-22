import SwiftUI
import UIKit
import ImageIO
import CryptoKit

/// Artwork cache: memory → disk → network. Images are stored on disk as
/// downloaded and decoded off the main thread, already downsampled to the
/// size they're shown at, so a library full of posters appears instantly on
/// every launch after the first (it used to re-download each one).
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let memory = NSCache<NSString, UIImage>()
    private let dir: URL
    private let session: URLSession
    private let lock = NSLock()
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        memory.totalCostLimit = 120 * 1024 * 1024
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = nil                       // we keep our own files
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.timeoutIntervalForRequest = 20
        session = URLSession(configuration: cfg)
    }

    private func fileKey(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func memKey(_ url: URL, _ px: Int) -> NSString { "\(px)|\(url.absoluteString)" as NSString }

    /// Already decoded and in memory (safe to call while building a view).
    func cached(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        memory.object(forKey: memKey(url, Int(maxPixel)))
    }

    func image(_ url: URL, maxPixel: CGFloat) async -> UIImage? {
        let px = Int(maxPixel)
        let mk = memKey(url, px)
        if let m = memory.object(forKey: mk) { return m }
        let key = "\(px)|\(url.absoluteString)"
        lock.lock()
        if let t = inflight[key] { lock.unlock(); return await t.value }
        let file = dir.appendingPathComponent(fileKey(url))
        let task = Task.detached(priority: .userInitiated) { [session] () -> UIImage? in
            var data = try? Data(contentsOf: file)
            if data == nil {
                guard let (d, resp) = try? await session.data(from: url),
                      (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true, !d.isEmpty else { return nil }
                try? d.write(to: file, options: .atomic)
                data = d
            }
            guard let data else { return nil }
            return Self.downsample(data, maxPixel: maxPixel)
        }
        inflight[key] = task
        lock.unlock()
        let img = await task.value
        lock.lock(); inflight[key] = nil; lock.unlock()
        if let img { memory.setObject(img, forKey: mk, cost: Int(img.size.width * img.size.height * img.scale * img.scale * 4)) }
        return img
    }

    /// Decodes at (at most) `maxPixel` on the long side, fully decoded now
    /// so drawing it on the main thread costs nothing.
    static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
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

    /// Size in bytes of the artwork cache on disk.
    func diskSize() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

/// Drop-in for AsyncImage backed by `ImageCache`.
struct CachedImage<Content: View, Placeholder: View>: View {
    let url: URL?
    var maxPixel: CGFloat = 900
    @ViewBuilder var content: (Image) -> Content
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let img = image ?? url.flatMap({ ImageCache.shared.cached($0, maxPixel: maxPixel) }) { content(Image(uiImage: img)) } else { placeholder() }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let c = ImageCache.shared.cached(url, maxPixel: maxPixel) { image = c; return }
            let img = await ImageCache.shared.image(url, maxPixel: maxPixel)
            withAnimation(.easeOut(duration: 0.2)) { image = img }
        }
    }
}
