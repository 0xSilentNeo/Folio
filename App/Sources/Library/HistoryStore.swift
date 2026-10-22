import Foundation
import Combine

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id: String { item.id }
    var item: MediaItem
    var position: Double
    var duration: Double
    var updated: Date

    var progress: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }
    var isFinished: Bool { duration > 0 && (position / duration > 0.92 || duration - position < 90) }
    var canResume: Bool { position > 15 && !isFinished }
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []
    private let fileURL: URL
    private var saveWork: DispatchWorkItem?

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = decoded
        }
    }

    var continueWatching: [HistoryEntry] {
        entries.filter { $0.canResume }.sorted { $0.updated > $1.updated }
    }

    var recent: [HistoryEntry] { entries.sorted { $0.updated > $1.updated } }

    func entry(for key: String) -> HistoryEntry? {
        entries.first { $0.id == key }
    }

    func entry(forURL url: String) -> HistoryEntry? {
        if let e = entries.first(where: { $0.item.url == url || $0.id == url }) { return e }
        // Library files keep their progress across a reinstall (new container path).
        guard url.contains("/Documents/Media/") else { return nil }
        let name = (url as NSString).lastPathComponent
        return entries.first { $0.item.url.contains("/Documents/Media/") && ($0.item.url as NSString).lastPathComponent == name }
    }

    func record(_ item: MediaItem, position: Double, duration: Double) {
        guard position.isFinite, duration.isFinite else { return }
        var stored = item
        if case .webdav = item.source {
            // Credentials live in the Keychain; re-added at play time.
            stored.headers.removeValue(forKey: "Authorization")
        }
        let entry = HistoryEntry(item: stored, position: position, duration: duration, updated: Date())
        if let i = entries.firstIndex(where: { $0.id == item.id }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
        if entries.count > 500 {
            entries = Array(entries.sorted { $0.updated > $1.updated }.prefix(500))
        }
        scheduleSave()
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        scheduleSave()
    }

    func markWatched(_ entry: HistoryEntry) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[i].position = entries[i].duration
        scheduleSave()
    }

    func clear() {
        entries = []
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = entries
        let url = fileURL
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func flush() {
        saveWork?.perform()
        saveWork = nil
    }
}
