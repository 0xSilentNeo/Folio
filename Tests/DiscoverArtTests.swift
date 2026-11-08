import XCTest
@testable import Folio

/// 1.26.0: the title page keeps the tile's picture (TileArt), and an
/// anime from Discover's Airing now row finds its IMDb title by its own
/// name only (AnimeLink).
final class DiscoverArtTests: XCTestCase {
    func testIMDbPosterGetsSharperCopyOfTheSamePicture() {
        let tile = "https://m.media-amazon.com/images/M/MV5BabcXkFqcGc@._V1_QL75_UX240_.jpg"
        let page = TileArt.sharper(poster: tile)
        XCTAssertEqual(page, "https://m.media-amazon.com/images/M/MV5BabcXkFqcGc@._V1_QL80_UX500_.jpg")
        XCTAssertTrue(TileArt.sameImage(page!, tile))
    }

    func testTMDBPosterAndBackdropSizes() {
        XCTAssertEqual(TileArt.sharper(poster: "https://image.tmdb.org/t/p/w342/abc.jpg"), "https://image.tmdb.org/t/p/w500/abc.jpg")
        XCTAssertEqual(TileArt.sharper(backdrop: "https://image.tmdb.org/t/p/w780/wide.jpg"), "https://image.tmdb.org/t/p/w1280/wide.jpg")
        XCTAssertTrue(TileArt.sameImage("https://image.tmdb.org/t/p/w342/abc.jpg", "https://image.tmdb.org/t/p/original/abc.jpg"))
        XCTAssertFalse(TileArt.sameImage("https://image.tmdb.org/t/p/w342/abc.jpg", "https://image.tmdb.org/t/p/w342/def.jpg"))
    }

    func testOtherAddressesAreKeptAsTheyAre() {
        let anilist = "https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx1.jpg"
        XCTAssertEqual(TileArt.sharper(poster: anilist), anilist)
        XCTAssertNil(TileArt.sharper(poster: nil))
    }

    func testAnimeShowNameDropsTheSeasonsOwnWords() {
        XCTAssertEqual(AnimeLink.showName("Blue Box Season 2"), "Blue Box")
        XCTAssertEqual(AnimeLink.showName("Aoashi Season 2"), "Aoashi")
        XCTAssertEqual(AnimeLink.showName("Mushoku Tensei: Jobless Reincarnation 2nd Season Part 2"), "Mushoku Tensei: Jobless Reincarnation")
        XCTAssertEqual(AnimeLink.showName("Attack on Titan: The Final Chapters"), "Attack on Titan")
        XCTAssertEqual(AnimeLink.showName("Frieren: Beyond Journey's End"), "Frieren: Beyond Journey's End")
    }

    func testAnimeNamesCompareWithoutCaseOrPunctuation() {
        XCTAssertEqual(AnimeLink.normalized("Frieren: Beyond Journey’s End"), AnimeLink.normalized("FRIEREN - Beyond Journey's End"))
        XCTAssertNotEqual(AnimeLink.normalized("Blue Box"), AnimeLink.normalized("Blues of War"))
    }
}
