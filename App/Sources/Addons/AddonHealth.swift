import Foundation

/// How each addon last answered (1.27.0), for the line under its name in
/// Addons: a slow or failing addon was invisible until a stream list came
/// back short. Kept between launches, by the addon's address.
@MainActor
final class AddonHealth: ObservableObject {
    static let shared = AddonHealth()

    struct Answer: Codable, Equatable {
        var ms: Int
        var ok: Bool
        var at: Date
        /// What was asked: "streams", "catalog", "details", "subtitles".
        var what: String
    }

    @Published private(set) var last: [String: Answer] = [:]

    private static let key = "addonAnswers"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([String: Answer].self, from: data) {
            last = saved
        }
    }

    func note(_ id: String, ms: Int, ok: Bool, what: String) {
        last[id] = Answer(ms: ms, ok: ok, at: Date(), what: what)
        UserDefaults.standard.set(try? JSONEncoder().encode(last), forKey: Self.key)
    }

    func forget(_ id: String) {
        guard last.removeValue(forKey: id) != nil else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(last), forKey: Self.key)
    }

    /// "Streams in 420 ms" / "Streams in 2.4 s" / "Streams failed after 20 s".
    static func describe(_ a: Answer) -> String {
        let time = a.ms < 1000 ? "\(a.ms) ms" : String(format: "%.1f s", Double(a.ms) / 1000)
        let what = a.what.prefix(1).uppercased() + a.what.dropFirst()
        return a.ok ? "\(what) in \(time)" : "\(what) failed after \(time)"
    }
}
