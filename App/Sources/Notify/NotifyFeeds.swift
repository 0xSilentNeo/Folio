import Foundation

/// A title on IMDb's Most Popular chart with what moved (1.25.0). The chart
/// page's data has, for each title, its rank, how many places it moved since
/// the chart before, its rating and number of ratings, its genres and year
/// (checked on the live page, 7 Nov).
struct TrendEntry: Codable, Equatable {
    var id: String
    var title: String
    /// "movie" or "series".
    var type: String
    var rank: Int
    /// Places moved: up is positive.
    var change: Int
    var rating: Double?
    var votes: Int?
    var genres: [String]
    var year: Int?
    var poster: String?
}

/// IMDb's Most Popular movies and TV, kept for the notifications: fetched
/// when Folio comes to the front (at most every 12 hours) and in iOS's
/// background refresh, only while a group that needs them is on.
@MainActor
enum TrendFeed {
    struct Snapshot: Codable {
        var fetched: Date
        var movies: [TrendEntry]
        var series: [TrendEntry]
        /// The chart before this one: ratings counts and ids, for "passed
        /// 100K ratings" and "new on the chart".
        var previousVotes: [String: Int] = [:]
        var previousIDs: [String] = []

        var all: [TrendEntry] { movies + series }
    }

    static let freshFor: TimeInterval = 12 * 3600
    /// Trending notifications are planned within this long of the fetch.
    static let usableFor: TimeInterval = 4 * 86400

    private static var file: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("notify-trend.json")
    }

    private(set) static var snapshot: Snapshot? = {
        guard let d = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: d)
    }()

    static var wanted: Bool { NotifyKind.allCases.contains { $0.needsCharts && NotifyPrefs.allowed($0) } }

    static func refresh(force: Bool = false) async {
        guard wanted || force else { return }
        if !force, let s = snapshot, Date().timeIntervalSince(s.fetched) < freshFor { return }
        async let m = IMDbSource.trendEntries("/chart/moviemeter/", type: "movie")
        async let t = IMDbSource.trendEntries("/chart/tvmeter/", type: "series")
        let (movies, series) = await (m, t)
        guard let movies, let series, !movies.isEmpty || !series.isEmpty else {
            dlog("notify", "charts not fetched")
            return
        }
        var s = Snapshot(fetched: Date(), movies: movies, series: series)
        if let old = snapshot {
            s.previousVotes = Dictionary(old.all.compactMap { e in e.votes.map { (e.id, $0) } }, uniquingKeysWith: { a, _ in a })
            s.previousIDs = old.all.map(\.id)
        }
        snapshot = s
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: file, options: .atomic) }
        dlog("notify", "charts: \(movies.count) films, \(series.count) shows")
    }

    /// Lab and tests.
    static func set(_ s: Snapshot?) { snapshot = s }
}

/// The weather where you said you are (1.25.0, Just for fun). Open-Meteo:
/// free for non-commercial use without a key, under 10,000 calls a day,
/// CC BY 4.0 (their terms, read 7 Nov). Off until a city is set: only then
/// does anything about where you are leave the phone (the city's position,
/// to two decimals).
@MainActor
enum WeatherFeed {
    struct Place: Codable, Equatable, Identifiable {
        var name: String
        var region: String?
        var country: String?
        /// ISO 3166-1, for the public holidays.
        var countryCode: String?
        var latitude: Double
        var longitude: Double
        var id: String { "\(name)|\(latitude)|\(longitude)" }
        var label: String { [name, region, country].compactMap { $0 }.joined(separator: ", ") }
    }

    struct Day: Codable, Equatable {
        /// "2026-11-08", the place's own day.
        var day: String
        var maxC: Double
        var minC: Double
        /// Chance of rain that day, 0…100.
        var rain: Int
    }

    struct Forecast: Codable {
        var fetched: Date
        var place: Place
        var days: [Day]
    }

    static let freshFor: TimeInterval = 3 * 3600

    static var place: Place? {
        get {
            guard let d = UserDefaults.standard.data(forKey: SettingsKey.notifyPlace) else { return nil }
            return try? JSONDecoder().decode(Place.self, from: d)
        }
        set {
            UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: SettingsKey.notifyPlace)
            forecast = nil
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static var file: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("notify-weather.json")
    }

    private(set) static var forecast: Forecast? = {
        guard let d = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Forecast.self, from: d)
    }()

    static var wanted: Bool { place != nil && NotifyKind.allCases.contains { $0.needsWeather && NotifyPrefs.allowed($0) } }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        return URLSession(configuration: c)
    }()

    /// Cities by name (Open-Meteo's geocoding).
    static func search(_ name: String) async -> [Place] {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "count", value: "8"),
                        URLQueryItem(name: "language", value: Locale.current.language.languageCode?.identifier ?? "en"),
                        URLQueryItem(name: "format", value: "json")]
        guard let url = c.url, let (data, _) = try? await session.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { r in
            guard let n = r["name"] as? String, let lat = r["latitude"] as? Double, let lon = r["longitude"] as? Double else { return nil }
            return Place(name: n, region: r["admin1"] as? String, country: r["country"] as? String,
                         countryCode: r["country_code"] as? String, latitude: lat, longitude: lon)
        }
    }

    static func refresh(force: Bool = false) async {
        guard let p = place, wanted || force else { return }
        if !force, let f = forecast, f.place == p, Date().timeIntervalSince(f.fetched) < freshFor { return }
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [URLQueryItem(name: "latitude", value: String(format: "%.2f", p.latitude)),
                        URLQueryItem(name: "longitude", value: String(format: "%.2f", p.longitude)),
                        URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
                        URLQueryItem(name: "timezone", value: "auto"), URLQueryItem(name: "forecast_days", value: "4")]
        guard let url = c.url, let (data, _) = try? await session.data(from: url),
              let days = parse(data) else {
            dlog("notify", "weather not fetched")
            return
        }
        let f = Forecast(fetched: Date(), place: p, days: days)
        forecast = f
        if let d = try? JSONEncoder().encode(f) { try? d.write(to: file, options: .atomic) }
        dlog("notify", "weather: \(days.count) days")
    }

    nonisolated static func parse(_ data: Data) -> [Day]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let daily = obj["daily"] as? [String: Any], let time = daily["time"] as? [String] else { return nil }
        let maxs = daily["temperature_2m_max"] as? [Any] ?? []
        let mins = daily["temperature_2m_min"] as? [Any] ?? []
        let rain = daily["precipitation_probability_max"] as? [Any] ?? []
        return time.indices.compactMap { i in
            guard i < maxs.count, i < mins.count, let hi = (maxs[i] as? NSNumber)?.doubleValue, let lo = (mins[i] as? NSNumber)?.doubleValue else { return nil }
            let r = i < rain.count ? (rain[i] as? NSNumber)?.intValue ?? 0 : 0
            return Day(day: time[i], maxC: hi, minC: lo, rain: r)
        }
    }

    /// "4°" in the phone's unit.
    nonisolated static func degrees(_ c: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let v = locale.measurementSystem == .us ? c * 9 / 5 + 32 : c
        return "\(Int(v.rounded()))°"
    }

    /// Lab and tests.
    static func set(_ f: Forecast?) { forecast = f }
}

/// Public holidays (1.25.0, Just for fun): Nager.Date's free list (no key),
/// for the set city's country, else the phone's region.
@MainActor
enum HolidayFeed {
    struct Holiday: Codable, Equatable {
        var date: String
        var name: String
    }

    struct Saved: Codable {
        var fetched: Date
        var country: String
        var holidays: [Holiday]
    }

    private static var file: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("notify-holidays.json")
    }

    private(set) static var saved: Saved? = {
        guard let d = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: d)
    }()

    static var country: String? { WeatherFeed.place?.countryCode?.uppercased() ?? Locale.current.region?.identifier }

    static var wanted: Bool { NotifyPrefs.allowed(.holiday) && country != nil }

    static func refresh() async {
        guard wanted, let cc = country else { return }
        if let s = saved, s.country == cc, Date().timeIntervalSince(s.fetched) < 30 * 86400 { return }
        let year = Calendar.current.component(.year, from: Date())
        var all: [Holiday] = []
        for y in [year, year + 1] {
            guard let url = URL(string: "https://nagerholidays.com/api/v4/Holidays/\(cc)/\(y)"),
                  let (data, r) = try? await URLSession.shared.data(from: url), (r as? HTTPURLResponse)?.statusCode == 200,
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            all += list.compactMap { h in
                // National ones only: Folio doesn't know your state or county.
                guard h["nationalHoliday"] as? Bool == true, let d = h["date"] as? String, let n = h["name"] as? String else { return nil }
                return Holiday(date: d, name: n)
            }
        }
        guard !all.isEmpty else {
            dlog("notify", "holidays not fetched for \(cc)")
            return
        }
        let s = Saved(fetched: Date(), country: cc, holidays: all)
        saved = s
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: file, options: .atomic) }
        dlog("notify", "holidays: \(all.count) for \(cc)")
    }
}

/// How Folio is used, for a few of Just for fun's jokes (1.25.0): visits,
/// visits where something played, and the longest visit that played
/// nothing, per day. Kept two weeks, on the phone only.
@MainActor
final class HabitLog {
    static let shared = HabitLog()

    struct Day: Codable, Equatable {
        var day: String
        var opens = 0
        var opensPlayed = 0
        /// The longest visit that played nothing, in minutes.
        var idleMinutes = 0
    }

    private(set) var days: [Day]
    private var began: Date?
    private var played = false
    private let key = "notifyHabits"

    init() {
        if let d = UserDefaults.standard.data(forKey: key), let list = try? JSONDecoder().decode([Day].self, from: d) {
            days = list
        } else {
            days = []
        }
    }

    func began(at: Date = Date()) {
        began = at
        played = false
    }

    func playedSomething() { played = true }

    func ended(at: Date = Date()) {
        guard let start = began else { return }
        began = nil
        let k = WatchLog.dayKey(start)
        var d = days.last(where: { $0.day == k }) ?? Day(day: k)
        d.opens += 1
        if played {
            d.opensPlayed += 1
        } else {
            d.idleMinutes = max(d.idleMinutes, Int(at.timeIntervalSince(start) / 60))
        }
        if let i = days.lastIndex(where: { $0.day == k }) { days[i] = d } else { days.append(d) }
        days = Array(days.suffix(14))
        UserDefaults.standard.set(try? JSONEncoder().encode(days), forKey: key)
    }

    func day(_ key: String) -> Day? { days.last { $0.day == key } }
}
