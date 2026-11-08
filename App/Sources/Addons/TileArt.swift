import Foundation

/// A tile's artwork at another size (1.26.0). Lists give small copies of
/// their pictures (IMDb's at 240 px, TMDB's at w342); a title page keeps the
/// same picture, asked for at its own size, so the poster you tapped is the
/// poster you get.
enum TileArt {
    /// The same poster, big enough for the title page (122 pt at 3×).
    static func sharper(poster: String?) -> String? {
        guard let poster else { return nil }
        if poster.contains("._V1_") { return IMDbSource.sized(poster, width: 500) }
        return tmdb(poster, size: "w500")
    }

    /// The same wide picture, sharp across a phone on its side.
    static func sharper(backdrop: String) -> String {
        if backdrop.contains("._V1_") { return backdrop }      // sized to the screen where it's drawn
        return tmdb(backdrop, size: "w1280")
    }

    /// Two addresses for one picture at different sizes (IMDb's lists use
    /// the poster as their "background").
    static func sameImage(_ a: String, _ b: String?) -> Bool {
        guard let b else { return false }
        return base(a) == base(b)
    }

    private static func base(_ url: String) -> String {
        if let r = url.range(of: "._V1_", options: .backwards) { return String(url[..<r.lowerBound]) }
        if url.hasPrefix(TMDB.image), let slash = url.dropFirst(TMDB.image.count).firstIndex(of: "/") {
            return String(url[slash...])
        }
        return url
    }

    /// TMDB's address with another size segment (".../t/p/w342/abc.jpg").
    private static func tmdb(_ url: String, size: String) -> String {
        guard url.hasPrefix(TMDB.image) else { return url }
        let rest = url.dropFirst(TMDB.image.count)
        guard let slash = rest.firstIndex(of: "/") else { return url }
        return TMDB.image + size + rest[slash...]
    }
}
