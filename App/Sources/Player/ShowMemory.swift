import Foundation

/// Per-show (and per-film) memory, 1.20.3 (2 Nov): the audio and subtitle
/// tracks, subtitle and audio delay, Fill and the Anime4K mode you chose,
/// applied to the next file of the same show (Settings → Playback →
/// Remember per show). Tracks are remembered by what they are (language,
/// title, codec; forced and SDH for subtitles), never by their number:
/// two releases of one show seldom number their tracks alike.

/// What's remembered for one show.
struct ShowSettings: Codable, Equatable {
    var audio: AudioChoice?
    var subtitle: SubtitleChoice?
    var subDelay: Double?
    var audioDelay: Double?
    /// mpv's panscan: 0 fits the picture, 1 fills the screen.
    var panscan: Double?
    /// Anime4KMode raw value.
    var anime4k: String?
    /// Playback speed picked in the player's menu (1.22.0).
    var speed: Double?
    /// Segments skipped by themselves for this show, whatever Settings says
    /// ("intro", "outro", "recap", "preview"; 1.22.0).
    var autoSkip: [String]?
    /// The second subtitle, shown at the top (1.22.0).
    var secondSubtitle: SubtitleChoice?
    /// Intro pills watched through without a skip, by the pill's name
    /// (lower-cased): the episodes (item ids) since you last skipped it
    /// (1.23.2).
    var introWatched: [String: [String]]?
    /// Intro pills that no longer show for this show: watched through in
    /// two episodes in a row ("intro" where a release calls the episode's
    /// first scene the intro; 6 Nov request).
    var introHidden: [String]?

    /// Fields of `other` that this one doesn't have (two entries merged).
    func filled(from other: ShowSettings) -> ShowSettings {
        var s = self
        s.speed = s.speed ?? other.speed
        s.autoSkip = s.autoSkip ?? other.autoSkip
        s.secondSubtitle = s.secondSubtitle ?? other.secondSubtitle
        s.introWatched = s.introWatched ?? other.introWatched
        s.introHidden = s.introHidden ?? other.introHidden
        s.audio = s.audio ?? other.audio
        s.subtitle = s.subtitle ?? other.subtitle
        s.subDelay = s.subDelay ?? other.subDelay
        s.audioDelay = s.audioDelay ?? other.audioDelay
        s.panscan = s.panscan ?? other.panscan
        s.anime4k = s.anime4k ?? other.anime4k
        return s
    }
}

struct AudioChoice: Codable, Equatable {
    var lang: String?
    var title: String?
    var codec: String?
    var channels: Int?
    var commentary = false

    init(lang: String?, title: String?, codec: String?, channels: Int?, commentary: Bool = false) {
        self.lang = lang; self.title = title; self.codec = codec; self.channels = channels; self.commentary = commentary
    }

    init(_ t: MediaTrack) {
        self.init(lang: t.lang, title: t.title, codec: t.codec, channels: t.channelCount, commentary: TrackMatch.isCommentary(t))
    }
}

struct SubtitleChoice: Codable, Equatable {
    /// Subtitles turned off.
    var off = false
    var lang: String?
    var title: String?
    var forced = false
    var sdh = false
    /// An external file (an addon's, a search result, one you loaded).
    var external = false
    var codec: String?

    /// Not `none`: on an optional choice `.none` would mean nil ("nothing
    /// remembered"), not "turned off".
    static let turnedOff = SubtitleChoice(off: true)

    init(off: Bool = false, lang: String? = nil, title: String? = nil, forced: Bool = false, sdh: Bool = false, external: Bool = false, codec: String? = nil) {
        self.off = off; self.lang = lang; self.title = title; self.forced = forced; self.sdh = sdh; self.external = external; self.codec = codec
    }

    init(_ t: MediaTrack) {
        self.init(lang: t.lang, title: t.title, forced: TrackMatch.isForced(t), sdh: TrackMatch.isSDH(t), external: t.external, codec: t.codec)
    }
}

/// Finds the remembered track among a file's tracks.
enum TrackMatch {
    /// The audio track like the one remembered: same language (required),
    /// a commentary only for a commentary, then the same title, codec and
    /// channel count. Nil when the file has none in that language.
    static func audio(_ c: AudioChoice, among tracks: [MediaTrack]) -> MediaTrack? {
        let lang = language(c.lang)
        let pool = tracks.filter { $0.type == "audio" && language($0.lang) == lang && isCommentary($0) == c.commentary }
        func score(_ t: MediaTrack) -> Int {
            var s = 0
            if same(t.title, c.title) { s += 4 }
            if let a = t.codec, let b = c.codec, a.lowercased() == b.lowercased() { s += 2 }
            if let a = t.channelCount, a == c.channels { s += 1 }
            return s
        }
        // Without a language, only a track that is recognisably the same.
        if lang == nil { return best(pool.filter { score($0) > 0 }, by: score) }
        return best(pool, by: score)
    }

    /// The subtitle track like the one remembered: same language and the
    /// same forced-ness (required: a forced track only covers the foreign
    /// lines), then SDH, title, external and format.
    static func subtitle(_ c: SubtitleChoice, among tracks: [MediaTrack]) -> MediaTrack? {
        guard !c.off else { return nil }
        let lang = language(c.lang)
        let pool = tracks.filter { $0.type == "sub" && language($0.lang) == lang && isForced($0) == c.forced }
        func score(_ t: MediaTrack) -> Int {
            var s = 0
            if isSDH(t) == c.sdh { s += 4 }
            if same(t.title, c.title) { s += 3 }
            if t.external == c.external { s += 2 }
            if let a = t.codec, let b = c.codec, a.lowercased() == b.lowercased() { s += 1 }
            return s
        }
        if lang == nil { return best(pool.filter { same($0.title, c.title) }, by: score) }
        return best(pool, by: score)
    }

    /// Highest score; on a tie the first in the file's order.
    private static func best(_ pool: [MediaTrack], by score: (MediaTrack) -> Int) -> MediaTrack? {
        var top: (MediaTrack, Int)?
        for t in pool {
            let s = score(t)
            if top == nil || s > top!.1 { top = (t, s) }
        }
        return top?.0
    }

    private static func same(_ a: String?, _ b: String?) -> Bool {
        let x = (a ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let y = (b ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return !x.isEmpty && x == y
    }

    static func isForced(_ t: MediaTrack) -> Bool {
        t.forced || (t.title ?? "").range(of: #"\bforced\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func isSDH(_ t: MediaTrack) -> Bool {
        t.hearingImpaired || (t.title ?? "").range(of: #"\b(SDH|CC)\b|hearing.impaired"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func isCommentary(_ t: MediaTrack) -> Bool {
        (t.title ?? "").range(of: "commentary", options: .caseInsensitive) != nil
    }

    /// One spelling per language, so "eng", "en" and "en-US" are one:
    /// two-letter codes, a region kept only where it's a different
    /// subtitle language ("pt-BR", "pob" → "pt-br"; "zh-TW" → "zh-tw").
    /// Nil for no language or "und".
    static func language(_ code: String?) -> String? {
        guard var c = code?.trimmingCharacters(in: .whitespaces).lowercased(), !c.isEmpty, c != "und", c != "unknown" else { return nil }
        c = c.replacingOccurrences(of: "_", with: "-")
        if let special = regional[c] { return special }
        let parts = c.split(separator: "-", maxSplits: 1).map(String.init)
        // "-", "--" or "_" split into nothing (an addon's "lang":"-"): no
        // language, not a crash (review, 5 Nov).
        guard var base = parts.first else { return nil }
        if base.count == 3 {
            base = alpha2[base] ?? Locale.LanguageCode(base).identifier(.alpha2) ?? base
        }
        if base == "nb" || base == "nn" { base = "no" }
        if parts.count > 1, keepsRegion.contains(base), ["br", "tw", "hk", "hant"].contains(parts[1]) {
            return base + "-" + (parts[1] == "hant" || parts[1] == "hk" ? "tw" : parts[1])
        }
        return base
    }

    private static let keepsRegion: Set<String> = ["pt", "zh"]
    private static let regional: [String: String] = ["pob": "pt-br", "pb": "pt-br", "zht": "zh-tw", "zhs": "zh", "chs": "zh", "cht": "zh-tw"]
    /// ISO 639-2 codes (both the B and the T forms) → ISO 639-1.
    private static let alpha2: [String: String] = [
        "eng": "en", "jpn": "ja", "spa": "es", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de", "ita": "it",
        "por": "pt", "rus": "ru", "chi": "zh", "zho": "zh", "kor": "ko", "ara": "ar", "hin": "hi", "dut": "nl",
        "nld": "nl", "swe": "sv", "nor": "no", "nob": "no", "nno": "no", "dan": "da", "fin": "fi", "pol": "pl",
        "cze": "cs", "ces": "cs", "slo": "sk", "slk": "sk", "hun": "hu", "gre": "el", "ell": "el", "tur": "tr",
        "heb": "he", "tha": "th", "vie": "vi", "ind": "id", "may": "ms", "msa": "ms", "rum": "ro", "ron": "ro",
        "bul": "bg", "ukr": "uk", "hrv": "hr", "scr": "hr", "srp": "sr", "scc": "sr", "slv": "sl", "est": "et",
        "lav": "lv", "lit": "lt", "per": "fa", "fas": "fa", "ice": "is", "isl": "is", "tam": "ta", "tel": "te",
        "ben": "bn", "cat": "ca", "baq": "eu", "eus": "eu", "glg": "gl", "wel": "cy", "cym": "cy", "alb": "sq",
        "sqi": "sq", "arm": "hy", "hye": "hy", "geo": "ka", "kat": "ka", "mac": "mk", "mkd": "mk", "bos": "bs",
        "mal": "ml", "mar": "mr", "kan": "kn", "urd": "ur", "fil": "tl", "tgl": "tl",
    ]
}

/// Who a file belongs to: keys from the most to the least certain (an IMDb
/// id, an addon's own id, then the show's or film's name), and the name
/// shown in Settings. TitleIdentity gives the IMDb id where one is known
/// without the network (an addon's id, a release with a confident match);
/// the name from TitleParser covers the rest, so two files of a show find
/// each other even with no match saved.
struct ShowKey: Equatable {
    var keys: [String]
    var name: String

    /// `imdb`: the title's IMDb id ("tt…", without season and episode).
    static func make(item: MediaItem, imdb: String?) -> ShowKey? {
        var keys: [String] = []
        if let imdb, imdb.hasPrefix("tt") { keys.append("imdb:" + imdb) }
        if case .addon = item.source {
            // "series|kitsu:46474|kitsu:46474:5": the addon's own id for the show.
            let parts = (item.addonRef ?? "").split(separator: "|", omittingEmptySubsequences: false)
            if parts.count >= 2, !parts[1].isEmpty, !parts[1].hasPrefix("tt") { keys.append("addon:" + parts[1]) }
            let name = item.title.isEmpty ? item.displayTitle : item.title
            return keys.isEmpty ? nil : ShowKey(keys: keys, name: name)
        }
        let file = item.fileName
        let parsed = TitleParser.parse(TitleParser.isMedia(file) || item.title.isEmpty ? file : item.title)
        let title = norm(parsed.title)
        guard !title.isEmpty else { return keys.isEmpty ? nil : ShowKey(keys: keys, name: item.displayTitle) }
        if parsed.episode != nil && parsed.extra != "Movie" {
            // An episode's file may name the year or not: both lead to the show.
            if let y = parsed.year { keys.append("show:\(title)|\(y)") }
            keys.append("show:" + title)
        } else {
            keys.append("film:" + title + (parsed.year.map { "|\($0)" } ?? ""))
        }
        return ShowKey(keys: keys, name: parsed.title.isEmpty ? item.displayTitle : parsed.title)
    }

    /// Lower case, letters and digits, single spaces.
    static func norm(_ s: String) -> String {
        String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
}

/// The remembered shows, in Application Support/show-memory.json: at most
/// `limit` shows (the ones not touched for longest go first) and, per show,
/// the subtitle delay of its last `fileLimit` files.
@MainActor
final class ShowMemoryStore: ObservableObject {
    static let shared = ShowMemoryStore(
        url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("show-memory.json"))

    struct FileDelay: Codable, Equatable {
        var file: String
        var subDelay: Double
    }

    struct Entry: Codable, Equatable, Identifiable {
        var keys: [String]
        var name: String
        var updated: Date
        var settings = ShowSettings()
        /// Subtitle delays by file (item id), most recent last.
        var files: [FileDelay] = []
        var id: String { keys.first ?? name }

        func subDelay(file: String) -> Double? { files.last { $0.file == file }?.subDelay }
    }

    @Published private(set) var entries: [Entry] = []
    let limit: Int
    let fileLimit: Int
    private let url: URL?
    private let writer = DispatchQueue(label: "folio.show-memory", qos: .utility)
    private var saveWork: DispatchWorkItem?
    /// Which scheduled save `saveWork` is (1.30.2).
    private var saveCount = 0

    /// `url` nil: in memory only (tests).
    init(url: URL?, limit: Int = 500, fileLimit: Int = 200) {
        self.url = url
        self.limit = limit
        self.fileLimit = fileLimit
        if let url, let d = try? Data(contentsOf: url) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            entries = dec.decodeLossy(Entry.self, from: d) ?? []
        }
    }

    /// The entry for these keys, trying the most certain key first.
    func entry(for keys: [String]) -> Entry? {
        for k in keys { if let e = entries.first(where: { $0.keys.contains(k) }) { return e } }
        return nil
    }

    /// Changes what's remembered for a show (made if new; its keys are
    /// merged, and two entries the keys both point to become one).
    func update(_ key: ShowKey, _ change: (inout Entry) -> Void) {
        var hits = entries.indices.filter { i in entries[i].keys.contains { key.keys.contains($0) } }
        // The one found by the most certain key first.
        hits.sort { a, b in rank(entries[a], key) < rank(entries[b], key) }
        var e: Entry
        if let first = hits.first {
            e = entries[first]
            for other in hits.dropFirst() {
                e.settings = e.settings.filled(from: entries[other].settings)
                e.files = entries[other].files.filter { f in !e.files.contains { $0.file == f.file } } + e.files
                e.keys += entries[other].keys
            }
            for i in hits.sorted(by: >) { entries.remove(at: i) }
        } else {
            e = Entry(keys: [], name: key.name, updated: Date())
        }
        // The most certain key first; the rest kept (older spellings still find it).
        var keys = key.keys
        for k in e.keys where !keys.contains(k) { keys.append(k) }
        e.keys = keys
        if key.keys.first?.hasPrefix("imdb:") == true || e.name.isEmpty { e.name = key.name }
        e.updated = Date()
        change(&e)
        if e.files.count > fileLimit { e.files.removeFirst(e.files.count - fileLimit) }
        entries.append(e)
        if entries.count > limit {
            // Oldest first out (the list is kept in the order of change, so
            // on an equal time the earlier one).
            let drop = entries.count - limit
            let oldest = entries.indices.sorted { (entries[$0].updated, $0) < (entries[$1].updated, $1) }.prefix(drop)
            for i in oldest.sorted(by: >) { entries.remove(at: i) }
        }
        scheduleSave()
    }

    func setSubDelay(_ delay: Double, file: String, for key: ShowKey) {
        update(key) { e in
            e.settings.subDelay = delay
            e.files.removeAll { $0.file == file }
            e.files.append(FileDelay(file: file, subDelay: delay))
        }
    }

    func forget(_ id: Entry.ID) {
        entries.removeAll { $0.id == id }
        scheduleSave()
    }

    /// Shows with intro pills hidden (Settings → Skip Intro & Credits).
    var hiddenIntroShows: [Entry] {
        entries.filter { !($0.settings.introHidden ?? []).isEmpty }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Brings a show's hidden intro pills back and starts counting again.
    func showIntrosAgain(_ id: Entry.ID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].settings.introHidden = nil
        entries[i].settings.introWatched = nil
        scheduleSave()
    }

    func forgetAll() {
        entries = []
        scheduleSave()
    }

    private func rank(_ e: Entry, _ key: ShowKey) -> Int {
        key.keys.firstIndex { e.keys.contains($0) } ?? Int.max
    }

    /// Written half a second after the last change (a delay stepper sends
    /// one change per tap), off the main thread.
    private func scheduleSave() {
        guard let url else { return }
        saveWork?.cancel()
        let snapshot = entries
        saveCount += 1
        let count = saveCount
        let w = DispatchWorkItem {
            Self.write(snapshot, to: url)
            // Written: nothing is pending any more (1.30.2). It stayed set,
            // and every later flush encoded and wrote on the main thread
            // with nothing changed.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.saveCount == count else { return }
                self.saveWork = nil
            }
        }
        saveWork = w
        writer.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    /// Writes now (the player closing).
    func flush() {
        guard let url, let w = saveWork, !w.isCancelled else { return }
        w.cancel()
        saveWork = nil
        let snapshot = entries
        writer.sync { Self.write(snapshot, to: url) }
    }

    nonisolated private static func write(_ entries: [Entry], to url: URL) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }
}
