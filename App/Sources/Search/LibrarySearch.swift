import SwiftUI

/// What's yours in the search (1.28.11): the library's titles, the files on
/// each WebDAV or Real-Debrid server (from its index), and what each Plex
/// and Jellyfin server finds. Until the one list (SearchResults) these were
/// sections of their own, a row style each; now this only finds them, and
/// the page (AddonSearchView) shows them as rows like every other result.
/// The kids profile sees its library titles only: the servers are locked there.
enum LibrarySearchResults {
    /// A Plex or Jellyfin show or season, opened in its server's browser.
    struct OpenedEntry: Hashable {
        let server: UUID
        let entry: CatalogEntry
        static func == (a: Self, b: Self) -> Bool { a.server == b.server && a.entry.id == b.entry.id }
        func hash(into h: inout Hasher) { h.combine(server); h.combine(entry.id) }
    }

    /// What the search looks through: the library, each server by name,
    /// then IMDb.
    @MainActor
    static func sources() -> [SearchSource] {
        var out = [SearchSource(name: "Library", icon: "play.rectangle.fill")]
        if !KidsProfile.shared.isOn {
            out += ServerStore.shared.servers.map { SearchSource(name: $0.name, icon: RealDebrid.isRealDebrid($0) ? "bolt.horizontal.circle.fill" : "externaldrive.fill") }
            out += MediaServerStore.shared.servers.filter { $0.kind != .smb }.map { SearchSource(name: $0.displayName, icon: $0.kind.icon) }
        }
        out.append(SearchSource(name: "Movies & Shows", icon: "sparkles.tv"))
        return out
    }

    /// Library titles whose name has every word: the kids profile's titles
    /// only, as Home shows them.
    ///
    /// Each title of a folder of several is found by its own name too
    /// (1.30.4): only the folder's name and its first file were looked at,
    /// so its other films couldn't be found. The kids profile judges each
    /// title, and only those that match.
    @MainActor
    static func libraryMatches(_ words: [String], in groups: [LibraryGroup], limits: KidsRules.Limits?) -> [LibraryGroup] {
        guard !words.isEmpty else { return [] }
        func found(_ g: LibraryGroup, _ name: String) -> Bool {
            let n = (name + " " + (g.files.first.map { $0.deletingPathExtension().lastPathComponent } ?? "")).lowercased()
            return words.allSatisfy { n.contains($0) }
        }
        func allowed(_ g: LibraryGroup) -> Bool { limits.map { LibraryMetaIndex.shared.kidsAllow(g, $0) } ?? true }
        var out: [LibraryGroup] = []
        var seen = Set<String>()
        func add(_ g: LibraryGroup) { if seen.insert(g.id).inserted { out.append(g) } }
        for g in groups where out.count < 20 {
            guard g.folder != nil else {
                if found(g, g.title), allowed(g) { add(g) }
                continue
            }
            if found(g, g.title), allowed(g) { add(g) }
            for files in LibraryMetaIndex.titles(of: g) where out.count < 20 && files.count < g.files.count {
                guard let first = files.first else { continue }
                let series = LibraryOrganizer.titleKey(first).hasPrefix("s|")
                let title = series ? TitleParser.parse(first.lastPathComponent).title : TitleParser.clean(first.lastPathComponent)
                let name = (title + " " + first.deletingPathExtension().lastPathComponent).lowercased()
                guard words.allSatisfy({ name.contains($0) }) else { continue }
                // The title's own group only for a match: made from its files on the spot.
                let t = LibraryGroup.ofTitle(files)
                if allowed(t) { add(t) }
            }
        }
        return out
    }

    /// How many releases of one server a search lists.
    static let releaseCap = 40

    /// Each server's indexed files whose name has every word, of at most
    /// 40 releases a server. The page leaves the kids profile out.
    ///
    /// 1.30.3: the first 40 files were taken, before they were put together
    /// by release, so a season's row said "40 files" of its 60 or stopped
    /// mid-season, and a broad search showed the first two or three releases.
    @MainActor
    static func serverMatches(_ words: [String], servers: [WebDAVServer], index: LibraryIndexStore) -> [ServerFile] {
        guard !words.isEmpty else { return [] }
        return servers.flatMap { server -> [ServerFile] in
            let state = index.state(server.id)
            let matched = state.searchable.filter { s in words.allSatisfy { s.haystack.contains($0) } }.map(\.file)
            return capByRelease(matched, root: state.index?.root, cap: releaseCap).map { ServerFile(server: server, file: $0) }
        }
    }

    /// The files of the first `cap` releases, every file of each, in the
    /// order found.
    static func capByRelease(_ files: [LibraryIndex.File], root: String?, cap: Int) -> [LibraryIndex.File] {
        var kept = Set<String>()
        var out: [LibraryIndex.File] = []
        for f in files {
            let key = releaseKey(f.url.absoluteString, root: root)
            if kept.contains(key) { out.append(f) }
            else if kept.count < cap { kept.insert(key); out.append(f) }
        }
        return out
    }

    /// The folder at the server's top a file is in (`root`: the start
    /// folder's address, LibraryIndex.key); the file's own address when
    /// it's at the top, or not under the start folder.
    static func releaseKey(_ address: String, root: String?) -> String {
        guard let root, !root.isEmpty, address.hasPrefix(root) else { return address }
        let rest = address.dropFirst(root.count)
        guard let slash = rest.firstIndex(of: "/") else { return address }
        return String(rest[..<slash])
    }
}

/// The typed words: two letters at least, lowercased, split on spaces.
enum LibrarySearchText {
    static func words(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return q.count >= 2 ? q.split(separator: " ").map(String.init) : []
    }
}

/// A file one of the WebDAV or Real-Debrid servers has, from its index.
struct ServerFile: Identifiable {
    let server: WebDAVServer
    let file: LibraryIndex.File
    var id: String { server.id.uuidString + "|" + file.url.absoluteString }

    var davItem: DAVItem {
        DAVItem(url: file.url, name: file.name, isDirectory: false, size: file.size, modified: file.added, contentType: nil)
    }

    /// The server's start folder. An address needs no login: with a
    /// password given the client doesn't read the Keychain, which it did
    /// here once a server at every keystroke.
    var root: URL? { WebDAVClient(server: server, password: "").url(forPath: server.rootPath) }

    /// Where the file is, under the start folder: ["Show.S01.1080p", "E01.mkv"].
    static func components(of url: URL, under root: URL?) -> [String] {
        let all = url.standardized.pathComponents.filter { $0 != "/" }
        guard let root else { return [all.last].compactMap { $0 } }
        let base = root.standardized.pathComponents.filter { $0 != "/" }
        guard all.count > base.count, Array(all.prefix(base.count)) == base else { return [all.last].compactMap { $0 } }
        return Array(all.dropFirst(base.count))
    }

    /// The page "Open folder" opens: the folder the file is in (the
    /// server's library when that's the start folder).
    var folderRoute: LibraryRoute {
        let parts = Self.components(of: file.url, under: root)
        guard parts.count > 1 else { return .webdav(server.id.uuidString) }
        let folder = file.url.deletingLastPathComponent()
        return .webdavFolder(server.id.uuidString, folder.absoluteString, parts[parts.count - 2])
    }

    /// The files found, one entry for each release (the folder at the
    /// server's top they're in, or the file itself when it's there), in the
    /// order found.
    struct Release: Identifiable {
        let server: WebDAVServer
        /// nil: a file at the server's top, which plays.
        let folder: URL?
        let name: ReleaseName
        var files: [ServerFile]
        var count: Int { files.count }
        var id: String { server.id.uuidString + "|" + (folder?.absoluteString ?? files.first?.file.url.absoluteString ?? name.raw) }
    }

    static func releases(_ files: [ServerFile]) -> [Release] {
        var out: [Release] = []
        var at: [String: Int] = [:]
        var roots: [UUID: URL?] = [:]
        for f in files {
            let root: URL?
            if let r = roots[f.server.id] { root = r } else { root = f.root; roots[f.server.id] = root }
            let parts = components(of: f.file.url, under: root)
            let folder: URL?
            let raw: String
            if parts.count > 1, let root {
                folder = root.appendingPathComponent(parts[0], isDirectory: true)
                raw = parts[0]
            } else {
                folder = nil
                raw = f.file.name
            }
            let key = f.server.id.uuidString + "|" + (folder?.absoluteString ?? f.file.url.absoluteString)
            if let i = at[key] { out[i].files.append(f); continue }
            let name = (folder != nil ? ReleaseName.folder(raw) : ReleaseName.file(raw))
                ?? ReleaseName(title: (raw as NSString).deletingPathExtension, label: nil, year: nil, episodeTitle: nil,
                               group: nil, alt: nil, attributes: [], raw: raw)
            at[key] = out.count
            out.append(Release(server: f.server, folder: folder, name: name, files: [f]))
        }
        return out
    }
}

/// A place the search looks.
struct SearchSource: Hashable {
    let name: String
    let icon: String
}

// MARK: - The one list

/// Which results the list shows: everything, what's yours (the library,
/// the servers, Plex and Jellyfin), or IMDb's and the addons' titles by kind.
enum SearchScope: String, CaseIterable, Identifiable {
    case all, yours, movies, shows
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        // "Library" (1.30.3); the case and the chip's identifier keep the old name.
        case .yours: return "Library"
        case .movies: return "Movies"
        case .shows: return "Shows"
        }
    }
}

/// One result, whatever found it: every kind is the same row (a picture,
/// a title, one line under it, and where you have it).
struct SearchItem: Identifiable {
    enum Kind {
        case library(LibraryGroup)
        /// A release's files on a WebDAV or Real-Debrid server, as one row.
        case release(ServerFile.Release)
        case catalog(CatalogEntry, MediaServer)
        /// An IMDb title (no addon) or one an addon's catalog found.
        case title(MetaItem, InstalledAddon?)
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    /// Where you have it: "Library", the server's or the addon's name. None for IMDb's titles.
    let badge: String?
    let identifier: String

    init(id: String, kind: Kind, title: String, detail: String, badge: String?, identifier: String) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail; self.badge = badge; self.identifier = identifier
    }

    /// A library title: "12 episodes", or its year and "Movie".
    @MainActor
    init(library g: LibraryGroup) {
        let detail: String
        if g.folder != nil {
            detail = "\(g.count) file\(g.count == 1 ? "" : "s")"
        } else if g.isSeries {
            detail = "\(g.count) episode\(g.count == 1 ? "" : "s")"
        } else {
            let year = g.files.first.flatMap { LibraryMetaIndex.shared.meta(for: $0)?.year }.flatMap { $0.isEmpty ? nil : $0 }
            detail = [year, "Movie"].compactMap { $0 }.joined(separator: " · ")
        }
        self.init(id: "library|" + g.id, kind: .library(g), title: g.title, detail: detail, badge: "Library", identifier: "searchLibrary:" + g.title)
    }

    /// A release: "S01 · 10 files", or one file's quality and size.
    init(release r: ServerFile.Release, clean: Bool) {
        let single = r.count == 1 ? r.files.first : nil
        let parts: [String?]
        if let single {
            parts = [r.name.label, r.name.year, r.name.attribute(.resolution), single.file.size.map { $0.byteString }]
        } else {
            parts = [r.name.label, "\(r.count) files"]
        }
        self.init(id: "release|" + r.id, kind: .release(r),
                  title: clean ? r.name.title : (single?.file.name ?? r.name.raw),
                  detail: parts.compactMap { $0 }.joined(separator: " · "),
                  badge: r.server.name,
                  identifier: single.map { "searchFile:" + $0.file.name } ?? "searchRelease:" + r.name.title)
    }

    init(entry e: CatalogEntry, server: MediaServer) {
        self.init(id: "catalog|" + server.id.uuidString + "|" + e.id, kind: .catalog(e, server), title: CatalogTitles.rowTitle(e),
                  detail: Self.detail(e), badge: server.displayName, identifier: "searchCatalog:" + e.name)
    }

    init(meta m: MetaItem, addon: InstalledAddon?) {
        let year = m.releaseInfo.flatMap { $0.isEmpty ? nil : $0 }
        self.init(id: "title|" + m.id, kind: .title(m, addon), title: m.name,
                  detail: [year, m.type == "series" ? "Series" : "Movie"].compactMap { $0 }.joined(separator: " · "),
                  badge: addon?.manifest.name, identifier: "searchTitle:" + m.name)
    }

    /// A film's year is in its title already ("Dune (2021)").
    static func detail(_ e: CatalogEntry) -> String {
        switch e.kind {
        case .series: return [e.year.map { String($0) }, "Series"].compactMap { $0 }.joined(separator: " · ")
        case .season: return ([e.seriesName ?? "Season"] + CatalogTitles.details(e)).joined(separator: " · ")
        case .episode: return [e.seriesName, e.season.map { "S\($0)" }.map { s in e.episode.map { s + "E\($0)" } ?? s }].compactMap { $0 }.joined(separator: " · ")
        case .movie: return (["Movie"] + CatalogTitles.details(e)).joined(separator: " · ")
        case .video: return (["Video"] + CatalogTitles.details(e)).joined(separator: " · ")
        case .audio: return (["Audio"] + CatalogTitles.details(e)).joined(separator: " · ")
        case .library, .folder: return CatalogTitles.details(e).joined(separator: " · ")
        }
    }

    /// An IMDb or addon series (the Shows chip); every other title is under Movies.
    var isSeries: Bool {
        if case .title(let m, _) = kind { return m.type == "series" }
        return false
    }

    var isTitle: Bool {
        if case .title = kind { return true }
        return false
    }

    var isRelease: Bool {
        if case .release = kind { return true }
        return false
    }

    /// "Open folder" on a release's row: the folder its file is in, or the release's own.
    var folderRoute: LibraryRoute? {
        guard case .release(let r) = kind else { return nil }
        if r.count == 1, let f = r.files.first { return f.folderRoute }
        if let folder = r.folder { return .webdavFolder(r.server.id.uuidString, folder.absoluteString, r.name.raw) }
        return r.files.first?.folderRoute
    }

    /// What VoiceOver says for the row: "MobLand, S01 · 10 files, Real-Debrid".
    var spoken: String {
        [title, detail, badge ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// Everything a query found, in the list's order, worked out when the
/// query or what was found changes (not at each redraw): what's yours
/// first (library, servers, Plex and Jellyfin), then IMDb's titles, then
/// the addons' (a title IMDb or an earlier addon already gave is left out).
struct SearchResults {
    /// How many of what's yours "All" shows (the top result is one of them).
    static let ownedCap = 5
    /// How many IMDb and addon titles "All" shows.
    static let titlesCap = 8

    let owned: [SearchItem]
    let titles: [SearchItem]
    let movies: [SearchItem]
    let shows: [SearchItem]
    /// "All": what's yours after the top result, and the first titles.
    let ownedShort: [SearchItem]
    let titlesShort: [SearchItem]
    /// Titles "All" leaves out, by the chip that lists them.
    let hiddenMovies: Int
    let hiddenShows: Int

    init(owned: [SearchItem] = [], imdb: [MetaItem] = [], addons: [AddonSearchView.SearchResult] = []) {
        var seen = Set<String>()
        var titles: [SearchItem] = []
        for m in imdb where seen.insert(m.id).inserted { titles.append(SearchItem(meta: m, addon: nil)) }
        for r in addons {
            for m in r.metas where seen.insert(m.id).inserted { titles.append(SearchItem(meta: m, addon: r.addon)) }
        }
        self.owned = owned
        self.titles = titles
        movies = titles.filter { !$0.isSeries }
        shows = titles.filter(\.isSeries)
        ownedShort = Array(owned.dropFirst().prefix(Self.ownedCap - 1))
        titlesShort = Array(titles.prefix(Self.titlesCap))
        let hidden = titles.dropFirst(Self.titlesCap)
        hiddenShows = hidden.filter(\.isSeries).count
        hiddenMovies = hidden.count - hiddenShows
    }

    /// The first of what's yours, shown as a card above the rest.
    var top: SearchItem? { owned.first }
    var hiddenOwned: Int { max(0, owned.count - Self.ownedCap) }

    /// The chips to show: All always, the others only with something under them.
    var scopes: [SearchScope] {
        var out: [SearchScope] = [.all]
        if !owned.isEmpty { out.append(.yours) }
        if !movies.isEmpty { out.append(.movies) }
        if !shows.isEmpty { out.append(.shows) }
        return out
    }
}

// MARK: - Rows

/// The one row every result is: picture, title, a line under it, and a
/// small badge for where you have it. `prominent`: the top result's card.
struct SearchResultRow: View {
    let item: SearchItem
    /// A Plex or Jellyfin entry's picture (its server's client makes the request).
    var artwork: URLRequest? = nil
    var prominent = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 12) {
            SearchThumb(item: item, artwork: artwork, width: prominent ? 60 : 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(prominent ? .headline : .body.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                if !item.detail.isEmpty {
                    Text(item.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                // At the largest text sizes the badge goes under the title, not beside it.
                if typeSize.isAccessibilitySize, let badge = item.badge { SearchBadge(text: badge) }
            }
            Spacer(minLength: 0)
            if !typeSize.isAccessibilitySize, let badge = item.badge { SearchBadge(text: badge) }
        }
        .contentShape(Rectangle())
    }
}

/// Where you have a result: "Library", a server's name, an addon's name.
struct SearchBadge: View {
    let text: String
    /// A long server name is cut here, so the badge never squeezes the title.
    private var short: String { text.count > 18 ? String(text.prefix(17)) + "…" : text }

    var body: some View {
        Text(short).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.fill, in: Capsule())
            .fixedSize()
            .accessibilityLabel(text)
    }
}

/// A result's picture, 2:3: the library title's poster, the release's, the
/// server's own picture of the entry, or the title's poster from IMDb or
/// the addon.
private struct SearchThumb: View {
    let item: SearchItem
    let artwork: URLRequest?
    let width: CGFloat

    var body: some View {
        Group {
            switch item.kind {
            case .library(let g):
                if g.folder == nil, let file = g.files.first { LibraryPosterThumb(file: file, points: width * 1.5) }
                else { SearchPlaceholder(symbol: "folder") }
            case .release(let r):
                ReleasePoster(release: r.name, width: width, cornerRadius: 8)
            case .catalog(let e, _):
                CatalogPosterThumb(entry: e, request: artwork, points: width * 1.5)
            case .title(let m, _):
                // Decoded for the thumbnail's width, not at 700 px (1.30.3).
                PosterImage(url: m.poster, cornerRadius: 8, width: width)
            }
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// No picture: the card colour and a symbol.
private struct SearchPlaceholder: View {
    let symbol: String
    var body: some View {
        ZStack {
            Theme.card
            Image(systemName: symbol).font(.body).foregroundStyle(.secondary)
        }
    }
}

/// A library title's poster, as Home's tiles load it.
private struct LibraryPosterThumb: View {
    let file: URL
    let points: CGFloat
    @StateObject private var thumb = ThumbLoader()

    var body: some View {
        Color.clear
            .overlay {
                if let img = thumb.image ?? ThumbLoader.cached(key: file.path, art: .poster, points: points) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else { SearchPlaceholder(symbol: "film") }
            }
            .clipped()
            .onAppear { thumb.load(key: file.path, fileURL: file, artwork: nil, lookupName: file.lastPathComponent, art: .poster, points: points) }
    }
}

/// A Plex or Jellyfin entry's picture, as its server's browser loads it.
private struct CatalogPosterThumb: View {
    let entry: CatalogEntry
    let request: URLRequest?
    let points: CGFloat
    @StateObject private var art = ServerArtLoader()

    private var symbol: String {
        switch entry.kind {
        case .series, .season: return "tv"
        case .episode: return "play.rectangle"
        default: return "film"
        }
    }

    var body: some View {
        Color.clear
            .overlay {
                if let img = art.image { Image(uiImage: img).resizable().scaledToFill() }
                else { SearchPlaceholder(symbol: symbol) }
            }
            .clipped()
            .onAppear { art.load(request, key: request?.url?.absoluteString, pixels: points * UIScreen.main.scale) }
    }
}

/// What the top result's capsule does and says: "Resume", "Play", or
/// "Open" for what has no one file to play.
struct SearchPlay {
    let title: String
    let icon: String
    let run: () -> Void
}

/// The top result (the first of what's yours): the same row, a little
/// larger, on a card, with a capsule that plays it.
struct SearchTopCard: View {
    let item: SearchItem
    var artwork: URLRequest? = nil
    let play: SearchPlay
    let open: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // The capsule under the row at the largest text sizes: beside it, the title had no room.
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            Button(action: open) {
                SearchResultRow(item: item, artwork: artwork, prominent: true)
            }
            .buttonStyle(.plain)
            Button(action: play.run) {
                Label(play.title, systemImage: play.icon)
                    .labelStyle(ChipLabelStyle())
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Theme.accent, in: Capsule())
                    .contentShape(Capsule())
                    .fixedSize()
            }
            .buttonStyle(PressStyle(scale: 0.95))
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        // One button to VoiceOver: the row's own tap, with the capsule as an action.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Top result, " + item.spoken)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
        .accessibilityAction(named: play.title, play.run)
        .accessibilityIdentifier(item.identifier)
    }
}

/// All, Library, Movies, Shows: the chosen one filled. Only the chips with
/// something under them are given (SearchResults.scopes).
struct SearchScopeChips: View {
    let scopes: [SearchScope]
    let selection: SearchScope
    let select: (SearchScope) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(scopes) { s in
                    let on = s == selection
                    Button { select(s) } label: {
                        Text(s.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(on ? Theme.onAccent : Color.primary.opacity(0.8))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(on ? Theme.accent : Theme.fill, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityIdentifier("searchScope:" + s.rawValue)
                }
            }
        }
        // The chips run to the screen's edge when they don't fit, not to the row's margin.
        .scrollClipDisabled()
        // A sideways swipe isn't scrolling the results: the keyboard stays (1.30.3).
        .scrollDismissesKeyboard(.never)
    }
}

// MARK: - Before anything is typed

/// Before anything is typed: your recent searches as chips, then what
/// you were watching (Home's Continue Watching, as posters). With neither,
/// one line saying what the search looks through. Until the one list this
/// was a magnifier, a tagline and a chip for each source, with Recent
/// squeezed under them.
struct SearchEmptyState: View {
    /// Newest first; empty in the kids profile (the grown-ups' searches).
    let recent: [SearchHistoryEntry]
    let run: (SearchHistoryEntry) -> Void
    let delete: (SearchHistoryEntry) -> Void
    let clear: () -> Void

    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var kids = KidsProfile.shared

    /// The newest searches shown as chips; the store keeps more.
    static let recentShown = 12
    static let continueShown = 12

    /// Home's Continue Watching; in the kids profile, only library files it
    /// allows (an addon or server item's rating isn't known here).
    private var continuing: [HistoryEntry] {
        let all = history.continueWatching
        guard let limits = kids.activeLimits else { return Array(all.prefix(Self.continueShown)) }
        return Array(all.filter { e in
            guard case .local = e.item.source else { return false }
            return KidsRules.allows(LibraryMetaIndex.shared.meta(for: URL(fileURLWithPath: e.item.historyKey ?? e.item.url)), limits: limits)
        }.prefix(Self.continueShown))
    }

    var body: some View {
        let items = continuing
        VStack(alignment: .leading, spacing: 24) {
            if !recent.isEmpty { recentChips }
            if !items.isEmpty { continueRow(items) }
            if recent.isEmpty, items.isEmpty {
                Text(kids.isOn ? "Search your library, and movies and shows." : "Search your library, your servers, and movies and shows.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 32)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("librarySearchIntro")
    }

    private var recentChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SearchHeader(title: "Recent")
                Spacer()
                // A menu the pill itself opens into (1.28.9). 1.28.7 hung
                // a confirmation dialog on the pill: iOS drew it as a
                // separate question, and after a few taps it stopped
                // coming up at all. A menu is the pill's own glass morphing
                // open, and keeps no state that can stick.
                Menu {
                    Section("Clear recent searches?") {
                        Button("Clear", systemImage: "trash", role: .destructive) {
                            withAnimation(.smooth(duration: 0.3)) { clear() }
                        }
                    }
                } label: {
                    Label("Clear", systemImage: "trash").font(.caption.weight(.semibold))
                }
                .menuStyle(.button)
                .modifier(ClearPillStyle())
                .accessibilityLabel("Clear recent searches")
                .accessibilityIdentifier("searchClearRecent")
            }
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(Array(recent.prefix(Self.recentShown))) { entry in
                    Button { run(entry) } label: {
                        Label(entry.query, systemImage: "clock.arrow.circlepath")
                            .labelStyle(ChipLabelStyle())
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.primary.opacity(0.85))
                            // A long search is cut, not run past the screen's edge.
                            .frame(maxWidth: 240)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Theme.fill, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressStyle(scale: 0.96))
                    // Each chip's own long-press menu: `.contextMenu` in a
                    // List belongs to the whole row (TileContextMenu).
                    .tileContextMenu(cornerRadius: 18) {
                        [TileMenuAction(title: "Delete", systemImage: "trash", destructive: true) { delete(entry) }]
                    }
                    .accessibilityLabel("Recent search, \(entry.query)")
                    .accessibilityHint("Searches again")
                    .accessibilityAction(named: "Delete") { delete(entry) }
                }
            }
        }
    }

    private func continueRow(_ items: [HistoryEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SearchHeader(title: "Continue watching")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items) { e in
                        // Resumed as Home's card does it: the show's queue, not the one file.
                        Button { ContinueQueue.play(e.item) } label: { SearchContinueCard(entry: e) }
                            .buttonStyle(PressStyle(scale: 0.97))
                            // Its label is the card's own: the name it shows (1.30.3).
                            .accessibilityHint(e.canResume ? "Resumes it" : "Plays it")
                            .accessibilityIdentifier("searchContinue:" + (e.item.title.isEmpty ? e.item.id : e.item.title))
                    }
                }
            }
            .scrollClipDisabled()
            .scrollDismissesKeyboard(.never)
        }
    }
}

/// One of the Continue watching posters: the title's poster, how far in
/// you are, and its name.
private struct SearchContinueCard: View {
    let entry: HistoryEntry
    @StateObject private var thumb = ThumbLoader()
    private static let width: CGFloat = 104
    private static let points: CGFloat = 156

    private var shownName: String { thumb.meta?.name ?? entry.item.displayTitle }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay {
                    if let img = thumb.image ?? ThumbLoader.cached(key: entry.item.id, art: .poster, points: Self.points) {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else { SearchPlaceholder(symbol: "play.rectangle") }
                }
                .clipped()
                .overlay { if entry.progress > 0.01 { ArtProgressBar(progress: entry.progress) } }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            Text(shownName)
                .font(.caption.weight(.semibold)).foregroundStyle(.primary)
                .lineLimit(2).multilineTextAlignment(.leading)
        }
        .frame(width: Self.width, alignment: .leading)
        // VoiceOver says the name the card shows (1.30.3: it said the file's).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shownName)
        .onAppear {
            // An addon stream's link names nothing: its poster is the item's artwork.
            let name = entry.item.addonRef == nil ? (entry.item.resolvedURL?.lastPathComponent ?? entry.item.title) : nil
            thumb.load(key: entry.item.id, fileURL: nil, artwork: entry.item.artwork, lookupName: name, art: .poster, points: Self.points)
        }
    }
}

private struct ChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.imageScale(.small)
            configuration.title.lineLimit(1)
        }
    }
}

/// A part's name on the search page, in the page's own type (not the list's small caps).
struct SearchHeader: View {
    let title: String
    var body: some View {
        Text(title).font(.subheadline.weight(.bold)).foregroundStyle(.primary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Plex and Jellyfin

/// The Plex and Jellyfin part of the search: each signed-in server asked
/// 300 ms after the last change (as Discover's search waits), all at once,
/// the newest question's answers kept.
@MainActor
final class CatalogSearch: ObservableObject {
    struct Result: Identifiable {
        let server: MediaServer
        var entries: [CatalogEntry]
        var error: String?
        var id: UUID { server.id }
    }

    @Published private(set) var results: [Result] = []
    /// The words `results` answer (1.30.3): the page lists them only for
    /// the same words, so the last query's entries aren't under the next
    /// one's while its answer is on the way.
    private(set) var resultsWords: [String] = []
    @Published private(set) var searching = false
    private var task: Task<Void, Never>?
    /// The last text and servers asked for: the same again asks nothing
    /// (the page calls this each time it comes back, 1.30.3).
    private var lastAsked: String?
    /// The clients the last search asked, kept for its rows (their
    /// pictures, playing one): made once a search, not once a row.
    private var clients: [UUID: any CatalogSource] = [:]

    /// The client for a Plex or Jellyfin server that's signed in.
    static func source(for id: UUID) -> (any CatalogSource)? {
        guard let s = MediaServerStore.shared.servers.first(where: { $0.id == id }) else { return nil }
        switch s.kind {
        case .plex: return PlexClient(server: s)
        case .jellyfin: return JellyfinClient(server: s, device: JellyfinAPI.deviceModel)
        case .smb: return nil
        }
    }

    /// The client the last search used for this server; a new one if it used none.
    func client(for id: UUID) -> (any CatalogSource)? {
        if let c = clients[id] { return c }
        let c = Self.source(for: id)
        clients[id] = c
        return c
    }

    func textChanged(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only counted here: a client reads its login from the Keychain,
        // so they're made after the pause, not at each keystroke.
        let servers = MediaServerStore.shared.servers.filter { $0.kind != .smb }
        let asked = q + "|" + servers.map(\.id.uuidString).joined(separator: ",")
        guard asked != lastAsked else { return }
        lastAsked = asked
        task?.cancel()
        guard q.count >= 2, !servers.isEmpty else {
            // Only what changes is written: an empty field at each visit redrew the page.
            if !results.isEmpty { results = [] }
            if searching { searching = false }
            return
        }
        if !searching { searching = true }
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let sources = self?.signedIn(servers) ?? []
            guard !sources.isEmpty else {
                if self?.results.isEmpty == false { self?.results = [] }
                self?.searching = false
                return
            }
            let t0 = CACurrentMediaTime()
            let found = await withTaskGroup(of: (Int, Result).self) { group in
                for (n, (server, source)) in sources.enumerated() {
                    group.addTask {
                        do { return (n, Result(server: server, entries: try await source.search(q))) }
                        catch { return (n, Result(server: server, entries: [], error: ServerError.message(error, server: server.displayName).text)) }
                    }
                }
                var out: [(Int, Result)] = []
                for await r in group { out.append(r) }
                return out.sorted { $0.0 < $1.0 }.map(\.1)
            }
            guard let self, !Task.isCancelled else { return }
            self.resultsWords = LibrarySearchText.words(q)
            self.results = found.filter { !$0.entries.isEmpty || $0.error != nil }
            self.searching = false
            dlog("search", "Plex/Jellyfin: " + found.map { "\($0.server.displayName) \($0.error == nil ? "\($0.entries.count)" : "error")" }.joined(separator: ", ")
                 + String(format: " in %.0f ms", (CACurrentMediaTime() - t0) * 1000))
        }
    }

    /// A fresh client for each server that's signed in (a login changed
    /// since the last search is read again).
    private func signedIn(_ servers: [MediaServer]) -> [(MediaServer, any CatalogSource)] {
        let sources = servers.compactMap { s in Self.source(for: s.id).map { (s, $0) } }
        clients = Dictionary(sources.map { ($0.0.id, $0.1) }, uniquingKeysWith: { a, _ in a })
        return sources
    }
}
