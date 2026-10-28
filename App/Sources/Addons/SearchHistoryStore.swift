import Foundation

/// One search you made on Discover.
struct SearchHistoryEntry: Codable, Hashable, Identifiable {
    /// As you last typed it (spaces tidied).
    var query: String
    var date: Date
    var id: String { SearchHistoryStore.key(query) }
}

/// Discover's recent searches, in Application Support/search-history.json.
///
/// An actor: every read and write of the list and the file happens on its
/// own executor, never on the main thread. The file is read the first time
/// something asks (not at launch) and written atomically after each change
/// (`Data.WritingOptions.atomic`: a temporary file, then a rename, so a
/// crash mid-write leaves the old file whole). A missing file is an empty
/// history; an unreadable one is logged, set aside as
/// search-history.corrupt.json, and the history starts empty.
///
/// A search is kept only once it's committed (Search pressed, or a result
/// opened), never per keystroke. The same search typed differently — case,
/// extra spaces — is one entry; using it again moves it to the top. At most
/// `limit` entries; the oldest go.
actor SearchHistoryStore {
    static let shared = SearchHistoryStore()

    /// The file's format. Version 1: `{"version": 1, "entries": [{"query", "date"}]}`.
    static let schemaVersion = 1
    static let defaultLimit = 50

    private struct File: Codable {
        var version: Int
        var entries: [SearchHistoryEntry]
    }

    private let url: URL
    private let limit: Int
    private var entries: [SearchHistoryEntry]?        // nil until first used

    init(fileURL: URL? = nil, limit: Int = SearchHistoryStore.defaultLimit) {
        self.url = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("search-history.json")
        self.limit = max(1, limit)
    }

    /// The same search however it was typed: spaces trimmed and collapsed, case ignored.
    static func key(_ query: String) -> String { tidy(query).lowercased() }

    /// Spaces trimmed at the ends and collapsed to one inside.
    static func tidy(_ query: String) -> String {
        query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Newest first.
    func all() -> [SearchHistoryEntry] { loaded() }

    /// Keeps a committed search (newest first); a blank one is ignored.
    @discardableResult
    func add(_ query: String, at date: Date = Date()) -> [SearchHistoryEntry] {
        let text = Self.tidy(query)
        guard !text.isEmpty else { return loaded() }
        let key = Self.key(text)
        var list = loaded().filter { $0.id != key }
        list.insert(SearchHistoryEntry(query: text, date: date), at: 0)
        if list.count > limit { list.removeLast(list.count - limit) }
        entries = list
        save(list)
        return list
    }

    @discardableResult
    func remove(_ query: String) -> [SearchHistoryEntry] {
        let key = Self.key(query)
        let list = loaded().filter { $0.id != key }
        entries = list
        save(list)
        return list
    }

    @discardableResult
    func clear() -> [SearchHistoryEntry] {
        entries = []
        save([])
        return []
    }

    // MARK: File

    private func loaded() -> [SearchHistoryEntry] {
        if let entries { return entries }
        let list = read()
        entries = list
        return list
    }

    private func read() -> [SearchHistoryEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(File.self, from: data)
            guard file.version <= Self.schemaVersion else {
                // Written by a newer Folio: left as it is, not overwritten until something is searched.
                dlog("search/warn", "search history is format \(file.version) (this version reads \(Self.schemaVersion)); starting empty")
                return []
            }
            // Newest first, deduplicated and capped, whatever the file holds.
            var seen = Set<String>()
            let list = file.entries.sorted { $0.date > $1.date }.filter { seen.insert($0.id).inserted && !$0.id.isEmpty }
            return Array(list.prefix(limit))
        } catch {
            let aside = url.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            dlog("search/error", "search history unreadable (\(error.localizedDescription)); set aside as \(aside.lastPathComponent), starting empty")
            return []
        }
    }

    private func save(_ list: [SearchHistoryEntry]) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(File(version: Self.schemaVersion, entries: list))
            try data.write(to: url, options: .atomic)
        } catch {
            dlog("search/error", "search history not saved: \(error.localizedDescription)")
        }
    }
}
