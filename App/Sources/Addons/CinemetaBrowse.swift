import Foundation

/// Discover's grid from Cinemeta (1.27.1): its Popular catalog for
/// Trending, Featured (by IMDb rating) for Top Rated, and New by year,
/// a page of titles at a time.
enum CinemetaBrowse {
    static func catalogID(_ sort: BrowseModel.Sort) -> String {
        switch sort {
        case .trending: "top"
        case .topRated: "imdbRating"
        case .new: "year"
        }
    }

    /// The catalog a sort asks for, or Popular when the addon hasn't it.
    static func catalog(in manifest: AddonManifest, sort: BrowseModel.Sort, type: String) -> AddonManifest.Catalog? {
        let ofType = manifest.catalogs.filter { $0.type == type }
        return ofType.first { $0.id == catalogID(sort) } ?? ofType.first { $0.id == "top" }
    }

    /// The extras for a page: New's year is its genre; `skip` is how many
    /// titles came before.
    static func extra(for catalog: AddonManifest.Catalog, genre: String?, year: String, skip: Int) -> [String: String] {
        var extra: [String: String] = [:]
        if catalog.id == "year" { extra["genre"] = year } else if let genre { extra["genre"] = genre }
        if skip > 0 { extra["skip"] = String(skip) }
        return extra
    }

    static func page(_ addon: InstalledAddon, sort: BrowseModel.Sort, type: String, genre: String?, year: String, skip: Int) async throws -> [MetaItem] {
        guard let cat = catalog(in: addon.manifest, sort: sort, type: type) else { return [] }
        return try await AddonAPI.catalog(addon, cat, extra: extra(for: cat, genre: genre, year: year, skip: skip))
    }
}
