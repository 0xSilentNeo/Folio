import UIKit

/// The picture for Control Center and the Lock Screen (1.23.0): what the
/// rest of Folio shows for the title. In order:
///   - an addon or server item's own picture (its poster),
///   - the title's art from its file name (MetadataService, as Home's rows
///     and title pages): the episode's still, else the backdrop, else the
///     poster,
///   - the frame saved when it was last closed.
enum NowPlayingArt {
    /// The Lock Screen's large artwork fills the width of a Pro Max (1320 px):
    /// 1.23.0 used the rows' 480 px episode pictures, blurry there (5 Nov).
    static let maxPixel: CGFloat = 1400

    static func find(for it: MediaItem) async -> (image: UIImage, source: String)? {
        if let a = it.artwork.map(large), let u = URL(string: a), ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
           let img = await ImageCache.shared.image(u, maxPixel: maxPixel) {
            return (img, "its own picture")
        }
        if let m = await MetadataService.shared.lookup(filename: lookupName(it)) {
            for (kind, address) in [("episode still", m.episodeThumb), ("backdrop", m.background), ("poster", m.poster)] {
                guard let address, let u = URL(string: large(address)) else { continue }
                if let img = await ImageCache.shared.image(u, maxPixel: maxPixel) { return (img, kind) }
            }
        }
        let id = it.id
        if let img = await Task.detached(priority: .utility, operation: { ThumbnailStore.image(for: id) }).value {
            return (img, "saved frame")
        }
        return nil
    }

    /// The name the title is looked up by: the file's own name, or the
    /// title for links whose file name says nothing ("stream.mkv").
    static func lookupName(_ it: MediaItem) -> String {
        let name = it.fileName
        let parsed = TitleParser.parse(name)
        return parsed.title.count >= 2 ? name : it.displayTitle
    }

    /// The same picture at the size the Lock Screen needs: IMDb and TMDB
    /// serve any width from the same address (IMDb's "._V1_…UX480_" part,
    /// TMDB's "/t/p/w300/").
    static func large(_ address: String) -> String {
        if address.contains("._V1_") { return IMDbSource.sized(address, width: Int(maxPixel)) ?? address }
        if let r = address.range(of: #"/t/p/w\d+/"#, options: .regularExpression) {
            return address.replacingCharacters(in: r, with: "/t/p/w1280/")
        }
        return address
    }
}
