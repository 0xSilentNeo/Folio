import XCTest
@testable import Folio

/// The search's one list: what's yours first, IMDb's titles, then the
/// addons' without the ones already there; a release's files as one row;
/// and what "All" leaves for the chips.
@MainActor
final class SearchResultsTests: XCTestCase {
    private func meta(_ n: Int, series: Bool = false) -> MetaItem {
        MetaItem(id: "tt\(n)", type: series ? "series" : "movie", name: "Title \(n)", poster: nil, description: nil,
                 releaseInfo: "2024", imdbRating: nil, genres: nil)
    }

    private func entry(_ n: Int) -> SearchItem {
        SearchItem(entry: CatalogEntry(id: "e\(n)", kind: .movie, name: "Film \(n)"), server: MediaServer(kind: .plex, name: "Plex"))
    }

    func testAddonTitlesAlreadyFoundAreLeftOut() {
        let addon = AddonSearchView.SearchResult(id: "a", title: "Catalog", addon: nil, metas: [meta(2), meta(3), meta(3)])
        let r = SearchResults(imdb: [meta(1), meta(2)], addons: [addon])
        XCTAssertEqual(r.titles.map(\.id), ["title|tt1", "title|tt2", "title|tt3"])
        XCTAssertTrue(r.owned.isEmpty)
        XCTAssertNil(r.top)
    }

    func testChipsOnlyWithSomethingUnderThem() {
        XCTAssertEqual(SearchResults().scopes, [.all])
        XCTAssertEqual(SearchResults(imdb: [meta(1)]).scopes, [.all, .movies])
        XCTAssertEqual(SearchResults(owned: [entry(1)], imdb: [meta(1, series: true)]).scopes, [.all, .yours, .shows])
    }

    func testAllShowsTheFirstFewAndCountsTheRest() {
        let owned = (1...7).map { entry($0) }
        let titles = (1...6).map { meta($0) } + (7...11).map { meta($0, series: true) }
        let r = SearchResults(owned: owned, imdb: titles)
        // The top result and four more of what's yours; the rest under Library.
        XCTAssertEqual(r.top?.id, owned[0].id)
        XCTAssertEqual(r.ownedShort.map(\.id), owned[1...4].map(\.id))
        XCTAssertEqual(r.hiddenOwned, 2)
        XCTAssertEqual(r.titlesShort.count, SearchResults.titlesCap)
        XCTAssertEqual(r.movies.count, 6)
        XCTAssertEqual(r.shows.count, 5)
        // Eight titles shown (six films, two shows): three shows are left for their chip.
        XCTAssertEqual(r.hiddenMovies, 0)
        XCTAssertEqual(r.hiddenShows, 3)
    }

    func testTitleRow() {
        let film = SearchItem(meta: meta(1), addon: nil)
        XCTAssertEqual(film.detail, "2024 · Movie")
        XCTAssertNil(film.badge)                        // IMDb's titles carry no badge
        XCTAssertFalse(film.isSeries)
        let show = SearchItem(meta: meta(2, series: true), addon: nil)
        XCTAssertEqual(show.detail, "2024 · Series")
        XCTAssertTrue(show.isSeries)
        XCTAssertEqual(show.spoken, "Title 2, 2024 · Series")
    }

    func testAReleasesFilesAreOneRow() {
        let server = WebDAVServer(name: "Real-Debrid", baseURL: "https://dav.real-debrid.com/", username: "u")
        let root = WebDAVClient(server: server, password: "").url(forPath: server.rootPath)!
        let folder = root.appendingPathComponent("MobLand.S01.1080p.Blu-ray.Remux-SiCFoI", isDirectory: true)
        func file(_ dir: URL, _ name: String) -> ServerFile {
            ServerFile(server: server, file: LibraryIndex.File(url: dir.appendingPathComponent(name), name: name, size: 1_500_000_000, added: nil))
        }
        let files = [file(folder, "MobLand.S01E01.mkv"), file(folder, "MobLand.S01E02.mkv"), file(root, "Conclave.2024.1080p.WEB-DL.mkv")]
        let rows = ServerFile.releases(files).map { SearchItem(release: $0, clean: true) }
        XCTAssertEqual(rows.count, 2)
        // The show: one row for its files, which opens the release's folder.
        XCTAssertEqual(rows[0].title, "MobLand")
        XCTAssertTrue(rows[0].detail.hasSuffix("2 files"), rows[0].detail)
        XCTAssertEqual(rows[0].badge, "Real-Debrid")
        XCTAssertEqual(rows[0].identifier, "searchRelease:MobLand")
        if case .webdavFolder(_, let address, let name)? = rows[0].folderRoute {
            XCTAssertEqual(name, "MobLand.S01.1080p.Blu-ray.Remux-SiCFoI")
            XCTAssertTrue(address.hasSuffix("MobLand.S01.1080p.Blu-ray.Remux-SiCFoI/"), address)
        } else { XCTFail("not a folder: \(String(describing: rows[0].folderRoute))") }
        // One file on its own: it plays, and keeps the file row's identifier.
        XCTAssertEqual(rows[1].title, "Conclave")
        XCTAssertEqual(rows[1].identifier, "searchFile:Conclave.2024.1080p.WEB-DL.mkv")
        XCTAssertTrue(rows[1].isRelease)
        if case .webdav? = rows[1].folderRoute {} else { XCTFail("not the library: \(String(describing: rows[1].folderRoute))") }
    }

    func testAServersEntryNamesItsServer() {
        let row = entry(1)
        XCTAssertEqual(row.badge, "Plex")
        XCTAssertEqual(row.identifier, "searchCatalog:Film 1")
        XCTAssertEqual(row.detail, "Movie")
    }
}
