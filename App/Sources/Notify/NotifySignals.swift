import Foundation

/// What Folio knows that's worth a notification (1.25.0): the facts behind
/// each kind, as candidates for NotifyPlanner. Nothing is guessed: a kind
/// whose facts aren't known isn't a candidate (Test then uses a sample).
///
/// The pure parts take plain values so they can be tested; `gather` reads
/// Folio's stores and calls them.
enum NotifySignals {
    // MARK: Inputs

    struct LibraryFilm: Equatable {
        var title: String
        var path: String
        var added: Date
        var played: Bool
        var watched: Bool
        var imdbID: String?
        var rating: Double?
        var poster: String?
    }

    struct Watched: Equatable {
        var at: Date
        var genres: [String]
        var imdbID: String?
    }

    struct Inputs {
        var now: Date
        var calendar: Calendar = .autoupdatingCurrent
        var films: [LibraryFilm] = []
        var seriesCount = 0
        /// Library files Folio found no title for (only once every title was looked up).
        var mystery: [String] = []
        /// The most films the library had when last planned (nil: never).
        var filmsBefore: Int?
        var watched: [Watched] = []
        var continueCount = 0
        var continueSeries = 0
        var trend: TrendFeed.Snapshot?
        var top250: Set<String> = []
        var forYou: [MetaItem] = []
        var habits: [HabitLog.Day] = []
        var watchDays: [WatchDay] = []
        var forecast: [WeatherFeed.Day] = []
        var holidays: [HolidayFeed.Holiday] = []
        var quiet: QuietHours = .standard
    }

    static let milestones = [25, 50, 100, 200, 300, 500, 1000]

    // MARK: Candidates

    static func candidates(_ x: Inputs) -> [NotifyCandidate] {
        trending(x) + picks(x) + library(x) + briefing(x) + fun(x)
    }

    private static func days(_ x: Inputs, _ n: Double) -> ClosedRange<Date> { x.now...x.now.addingTimeInterval(n * 86400) }

    private static func week(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
        return "\(c.yearForWeekOfYear ?? 0)w\(c.weekOfYear ?? 0)"
    }

    static func votesLabel(_ n: Int) -> String { n >= 1_000_000 ? "\(n / 1_000_000)M" : "\(n / 1000)K" }

    static func trending(_ x: Inputs) -> [NotifyCandidate] {
        guard let t = x.trend, x.now.timeIntervalSince(t.fetched) < TrendFeed.usableFor else { return [] }
        let seen = Set(x.watched.compactMap(\.imdbID))
        let until = min(x.now.addingTimeInterval(4 * 86400), t.fetched.addingTimeInterval(TrendFeed.usableFor))
        guard until > x.now else { return [] }
        let w = x.now...until
        let wk = week(t.fetched, x.calendar)
        func c(_ k: NotifyKind, _ e: TrendEntry, _ key: String, _ facts: [String: String], _ why: String) -> NotifyCandidate {
            var f = facts
            f["title"] = e.title
            return NotifyCandidate(kind: k, key: key, window: w, facts: f, link: TitleLink.url(e), image: e.poster.map { .url($0) }, reason: why)
        }
        let fresh = t.all.filter { !seen.contains($0.id) }
        var out: [NotifyCandidate] = []
        if let m = t.movies.first, !seen.contains(m.id) {
            out.append(c(.trendingMovie, m, "trendMovie.\(m.id)", [:], "#1 on IMDb's Most Popular Movies"))
        }
        if let s = t.series.first, !seen.contains(s.id) {
            out.append(c(.trendingSeries, s, "trendSeries.\(s.id)", [:], "#1 on IMDb's Most Popular TV"))
        }
        if let e = fresh.filter({ $0.rank > 1 && $0.rank <= 50 && $0.change >= 30 }).max(by: { $0.change < $1.change }) {
            out.append(c(.risingFast, e, "rising.\(e.id).\(wk)", ["places": e.change.formatted(), "rank": "\(e.rank)"], "Up \(e.change) places to #\(e.rank)"))
        }
        if let e = fresh.first(where: { $0.rank <= 10 && $0.change >= 100 }) {
            out.append(c(.viral, e, "viral.\(e.id)", ["rank": "\(e.rank)"], "Into the top 10 from \(e.rank + e.change)"))
        }
        let year = x.calendar.component(.year, from: x.now)
        if let e = t.movies.filter({ !seen.contains($0.id) && ($0.rating ?? 0) >= 8.5 && ($0.votes ?? 0) >= 5000 && ($0.year ?? 0) >= year - 1 })
            .max(by: { ($0.rating ?? 0) < ($1.rating ?? 0) }) {
            out.append(c(.topRated, e, "toprated.\(e.id)", ["rating": String(format: "%.1f", e.rating ?? 0)], "Rated \(e.rating ?? 0), \(e.votes ?? 0) ratings"))
        }
        if let e = t.series.filter({ !seen.contains($0.id) && ($0.rating ?? 0) >= 9.0 && ($0.votes ?? 0) >= 5000 && $0.rank <= 50 }).first {
            out.append(c(.highlyRatedSeries, e, "hrs.\(e.id)", ["rating": String(format: "%.1f", e.rating ?? 0)], "Rated \(e.rating ?? 0), #\(e.rank)"))
        }
        if let e = t.all.filter({ $0.rank <= 20 && ($0.rating ?? 10) < 6.0 && ($0.votes ?? 0) >= 1000 }).min(by: { $0.rank < $1.rank }) {
            out.append(c(.lowRatedPopular, e, "lowrated.\(e.id)", ["rating": String(format: "%.1f", e.rating ?? 0), "rank": "\(e.rank)"], "#\(e.rank), rated \(e.rating ?? 0)"))
        }
        if let e = t.all.filter({ ($0.year ?? year) <= year - 10 && $0.change >= 20 && $0.rank <= 50 }).max(by: { $0.change < $1.change }) {
            out.append(c(.comeback, e, "comeback.\(e.id).\(wk)", ["year": "\(e.year ?? 0)", "places": e.change.formatted()], "From \(e.year ?? 0), up \(e.change) places"))
        }
        for e in t.all {
            guard let now = e.votes, let before = t.previousVotes[e.id],
                  let m = [100_000, 250_000, 500_000, 1_000_000].first(where: { before < $0 && now >= $0 }) else { continue }
            out.append(c(.ratingMilestone, e, "votes.\(e.id).\(m)", ["votes": votesLabel(m)], "\(before) → \(now) ratings"))
            break
        }
        // Your most watched genre, when it fills the charts' top 10s.
        if let g = topGenre(x, days: 60) {
            let top = Array(t.movies.prefix(10)) + Array(t.series.prefix(10))
            let n = top.filter { $0.genres.contains(g) }.count
            if n >= 5, let first = top.first(where: { $0.genres.contains(g) }) {
                out.append(c(.popularGenre, first, "genre.\(g).\(wk)", ["genre": g, "n": "\(n)"], "\(n) of the top 20 are \(g); you watch it most"))
            }
        }
        return out
    }

    /// Your most watched genre over the last `days` (at least three titles).
    static func topGenre(_ x: Inputs, days: Double) -> String? {
        let since = x.now.addingTimeInterval(-days * 86400)
        var count: [String: Int] = [:]
        for w in x.watched where w.at >= since { for g in Set(w.genres) where g != "Drama" { count[g, default: 0] += 1 } }
        guard let best = count.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }), best.value >= 3 else { return nil }
        return best.key
    }

    static func picks(_ x: Inputs) -> [NotifyCandidate] {
        var out: [NotifyCandidate] = []
        let seen = Set(x.watched.compactMap(\.imdbID))
        let picks = x.forYou.filter { !seen.contains($0.id) }
        if let m = picks.first {
            out.append(NotifyCandidate(kind: .forYouPick, key: "foryou.\(m.id)", window: days(x, 5), facts: ["title": m.name],
                                       link: TitleLink.url(m), image: m.poster.map { .url($0) }, reason: "First in Discover's For you"))
        }
        if let m = picks.dropFirst().first(where: { (Double($0.imdbRating ?? "") ?? 0) >= 8.0 }) {
            out.append(NotifyCandidate(kind: .hiddenGem, key: "gem.\(m.id)", window: days(x, 5), facts: ["title": m.name, "rating": m.imdbRating ?? ""],
                                       link: TitleLink.url(m), image: m.poster.map { .url($0) }, reason: "For you, rated \(m.imdbRating ?? "")"))
        }
        if let g = topGenre(x, days: 30) {
            let since = x.now.addingTimeInterval(-30 * 86400)
            let n = x.watched.filter { $0.at >= since && $0.genres.contains(g) }.count
            if n >= 4 {
                let month = x.calendar.dateComponents([.year, .month], from: x.now)
                out.append(NotifyCandidate(kind: .genreStreak, key: "gstreak.\(g).\(month.year ?? 0)-\(month.month ?? 0)", window: days(x, 3),
                                           facts: ["genre": g.lowercased(), "n": "\(n)"], reason: "\(n) \(g) titles in 30 days"))
            }
        }
        return out
    }

    static func library(_ x: Inputs) -> [NotifyCandidate] {
        var out: [NotifyCandidate] = []
        let w = days(x, 7)
        let unwatched = x.films.filter { !$0.watched }
        if let f = x.films.filter({ !$0.played && x.now.timeIntervalSince($0.added) > 45 * 86400 }).min(by: { $0.added < $1.added }) {
            out.append(NotifyCandidate(kind: .forgotten, key: "forgotten.\(EngagePlanner.key(f.path))", window: w, facts: ["title": f.title],
                                       link: LibraryLink.url(f.path), image: .file(f.path), reason: "Added \(Int(x.now.timeIntervalSince(f.added) / 86400)) days ago, never played"))
        }
        if unwatched.count >= 20 {
            let bucket = unwatched.count / 10 * 10
            out.append(NotifyCandidate(kind: .bigCollection, key: "big.\(bucket)", window: w, facts: ["n": "\(unwatched.count)"],
                                       reason: "\(unwatched.count) films not watched"))
        }
        if let f = unwatched.first(where: { ($0.imdbID.map(x.top250.contains) ?? false) || ($0.rating ?? 0) >= 8.3 }) {
            out.append(NotifyCandidate(kind: .unwatchedClassic, key: "classic.\(f.imdbID ?? EngagePlanner.key(f.path))", window: w, facts: ["title": f.title],
                                       link: LibraryLink.url(f.path), image: .file(f.path),
                                       reason: (f.imdbID.map(x.top250.contains) ?? false) ? "In IMDb's Top 250" : "Rated \(f.rating ?? 0)"))
        }
        if let m = x.mystery.first {
            out.append(NotifyCandidate(kind: .mysteryFile, key: "mystery.\(EngagePlanner.key(m))", window: w, facts: ["file": m],
                                       link: "folio://home", reason: "No title found for this file"))
        }
        if let before = x.filmsBefore, let m = milestones.last(where: { before < $0 && x.films.count >= $0 }) {
            out.append(NotifyCandidate(kind: .milestone, key: "milestone.\(m)", window: w, facts: ["n": "\(m)"], reason: "\(before) → \(x.films.count) films"))
        }
        if let t = x.trend, x.now.timeIntervalSince(t.fetched) < TrendFeed.usableFor {
            let ids = Set(t.all.map(\.id))
            if let f = x.films.first(where: { $0.imdbID.map(ids.contains) ?? false }) {
                out.append(NotifyCandidate(kind: .rediscovery, key: "rediscover.\(f.imdbID ?? "").\(week(t.fetched, x.calendar))", window: w,
                                           facts: ["title": f.title], link: LibraryLink.url(f.path), image: .file(f.path), reason: "In your library and on IMDb's chart"))
            }
        }
        return out
    }

    static func briefing(_ x: Inputs) -> [NotifyCandidate] {
        guard let t = x.trend, x.now.timeIntervalSince(t.fetched) < TrendFeed.usableFor else { return [] }
        let cal = x.calendar
        var out: [NotifyCandidate] = []
        func list(_ e: [TrendEntry]) -> String { e.enumerated().map { "\($0 + 1). \($1.title)" }.joined(separator: " · ") }
        let top = Array(t.series.prefix(3)) + Array(t.movies.prefix(2))
        if !top.isEmpty, let friday = EngagePlanner.nextWeekday(6, hour: 17, after: x.now, cal),
           let fire = cal.date(byAdding: .minute, value: 30, to: friday), fire.timeIntervalSince(t.fetched) < TrendFeed.usableFor + 86400 {
            out.append(NotifyCandidate(kind: .weeklyBriefing, key: "briefing.\(WatchLog.dayKey(fire, calendar: cal))", fire: fire,
                                       facts: ["list": list(top)], link: TitleLink.url(top[0]), image: top[0].poster.map { .url($0) },
                                       reason: "Friday's top titles"))
        }
        let year = cal.component(.year, from: x.now)
        let new = t.all.filter { !t.previousIDs.isEmpty && !t.previousIDs.contains($0.id) && ($0.year ?? 0) >= year - 1 && $0.rank <= 30 }
        if new.count >= 3 {
            let names = new.prefix(3).map(\.title)
            let more = new.count > 3 ? " and \(new.count - 3) more" : ""
            out.append(NotifyCandidate(kind: .freshTitles, key: "fresh.\(week(t.fetched, cal))", window: days(x, 3),
                                       facts: ["n": "\(new.count)", "list": names.joined(separator: ", ") + more],
                                       link: TitleLink.url(new[0]), image: new[0].poster.map { .url($0) }, reason: "New on the charts this week"))
        }
        // The month's recap on the 1st at 18:00, about the month ending.
        if let next = cal.date(byAdding: .month, value: 1, to: x.now),
           let first = cal.date(from: cal.dateComponents([.year, .month], from: next)),
           let fire = cal.date(bySettingHour: 18, minute: 0, second: 0, of: first) {
            let month = DateFormatter().monthSymbols[cal.component(.month, from: x.now) - 1]
            let prefix = String(WatchLog.dayKey(x.now, calendar: cal).prefix(7))
            let seconds = x.watchDays.filter { $0.day.hasPrefix(prefix) }.reduce(0) { $0 + $1.seconds }
            var facts = ["month": month, "list": (Array(t.series.prefix(2)) + Array(t.movies.prefix(1))).map(\.title).joined(separator: ", ")]
            if seconds >= 3600 { facts["hours"] = "\(Int(seconds / 3600)) hour\(Int(seconds / 3600) == 1 ? "" : "s")" }
            out.append(NotifyCandidate(kind: .monthlyRecap, key: "recap.\(prefix)", fire: fire, facts: facts, reason: "\(month)'s recap"))
        }
        return out
    }

    static func fun(_ x: Inputs) -> [NotifyCandidate] {
        let cal = x.calendar
        var out: [NotifyCandidate] = []
        let today = WatchLog.dayKey(x.now, calendar: cal)
        let yesterday = cal.date(byAdding: .day, value: -1, to: x.now).map { WatchLog.dayKey($0, calendar: cal) } ?? ""
        let tomorrow = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: x.now) ?? x.now)
        let nextDay = tomorrow...tomorrow.addingTimeInterval(86400 - 1)
        // The habit jokes come the next day, about yesterday or today.
        for k in [today, yesterday] {
            guard let d = x.habits.first(where: { $0.day == k }) else { continue }
            let window = k == today ? nextDay : x.now...x.now.addingTimeInterval(86400)
            if d.opens >= 5, d.opensPlayed == 0 {
                out.append(NotifyCandidate(kind: .openedNoWatch, key: "opened.\(k)", window: window, facts: ["n": "\(d.opens)"],
                                           reason: "\(d.opens) visits on \(k), nothing played"))
            }
            if d.idleMinutes >= 20 {
                out.append(NotifyCandidate(kind: .longChoosing, key: "choosing.\(k)", window: window, facts: ["minutes": "\(d.idleMinutes)"],
                                           reason: "A \(d.idleMinutes)-minute visit on \(k), nothing played"))
            }
        }
        // Days in a row with 10 minutes or more watched, up to today or yesterday.
        var streak = 0
        var day = cal.startOfDay(for: x.now)
        if (x.watchDays.first { $0.day == today }?.seconds ?? 0) < 600 { day = cal.date(byAdding: .day, value: -1, to: day) ?? day }
        while let d = x.watchDays.first(where: { $0.day == WatchLog.dayKey(day, calendar: cal) }), d.seconds >= 600 {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        if streak >= 5 {
            out.append(NotifyCandidate(kind: .streak, key: "streak.\(streak).\(today)", window: nextDay, facts: ["n": "\(streak)"],
                                       reason: "\(streak) days in a row"))
        }
        if x.continueCount >= 5 {
            out.append(NotifyCandidate(kind: .unfinishedPile, key: "pile.\(week(x.now, cal))", window: days(x, 4), facts: ["n": "\(x.continueCount)"],
                                       reason: "\(x.continueCount) in Continue Watching"))
        }
        let weekAgo = x.now.addingTimeInterval(-7 * 86400)
        let docs = x.watched.filter { $0.at >= weekAgo && $0.genres.contains("Crime") && $0.genres.contains("Documentary") }.count
        if docs >= 2 {
            out.append(NotifyCandidate(kind: .crimeDoc, key: "crimedoc.\(week(x.now, cal))", window: days(x, 2), facts: ["n": "\(docs)"],
                                       reason: "\(docs) crime documentaries this week"))
        }
        if let friday = EngagePlanner.nextWeekday(6, hour: 18, after: x.now, cal), let fire = cal.date(byAdding: .minute, value: 30, to: friday) {
            out.append(NotifyCandidate(kind: .movieNight, key: "movienight.\(WatchLog.dayKey(fire, calendar: cal))", fire: fire, reason: "Friday evening"))
        }
        let films = min(3, x.films.filter { !$0.watched }.count), series = min(2, x.continueSeries)
        if films + series > 0, let sat = EngagePlanner.nextWeekday(7, hour: 10, after: x.now, cal), let fire = cal.date(byAdding: .minute, value: 30, to: sat) {
            out.append(NotifyCandidate(kind: .weekendForecast, key: "weekend.\(WatchLog.dayKey(fire, calendar: cal))", fire: fire,
                                       facts: ["films": "\(films)", "series": "\(series)"], reason: "\(films) unwatched films, \(series) shows in progress"))
        }
        // A thriller before bed, for someone up late twice in two weeks: Friday or Saturday, half an hour before quiet hours.
        let late = x.watchDays.suffix(14).filter { $0.lateSeconds > 0 }.count
        if late >= 2 {
            let minute = x.quiet.isOff ? 22 * 60 + 30 : (x.quiet.start - 30 + 24 * 60) % (24 * 60)
            for wd in [6, 7] {
                guard let d = EngagePlanner.nextWeekday(wd, hour: 23, after: x.now, cal),
                      let fire = cal.date(byAdding: .minute, value: minute, to: cal.startOfDay(for: d)), fire > x.now else { continue }
                out.append(NotifyCandidate(kind: .lateNightThriller, key: "thriller.\(WatchLog.dayKey(fire, calendar: cal))", fire: fire,
                                           reason: "Up late \(late) times in two weeks"))
            }
        }
        // The forecast: rain, cold or heat on a day, at your usual time that day.
        for d in x.forecast {
            // A day already over is left out before its range is made: a
            // range whose start (now) is after its end traps (review, 9 Nov:
            // a forecast cached before midnight, or a city west of the phone).
            guard let start = EngagePlanner.date(of: d.day, cal) else { continue }
            let end = start.addingTimeInterval(86400 - 1)
            guard end > x.now else { continue }
            let window = max(start, x.now)...end
            if d.rain >= 70 {
                out.append(NotifyCandidate(kind: .rainy, key: "rain.\(d.day)", window: window, facts: ["chance": "\(d.rain)"], reason: "\(d.rain)% chance of rain on \(d.day)"))
            } else if d.maxC <= 8 {
                out.append(NotifyCandidate(kind: .cold, key: "cold.\(d.day)", window: window, facts: ["temp": WeatherFeed.degrees(d.maxC)], reason: "High of \(d.maxC)°C on \(d.day)"))
            } else if d.maxC >= 32 {
                out.append(NotifyCandidate(kind: .hot, key: "hot.\(d.day)", window: window, facts: ["temp": WeatherFeed.degrees(d.maxC)], reason: "High of \(d.maxC)°C on \(d.day)"))
            }
        }
        for h in x.holidays {
            guard let day = EngagePlanner.date(of: h.date, cal), let fire = cal.date(bySettingHour: 11, minute: 0, second: 0, of: day),
                  fire > x.now, fire.timeIntervalSince(x.now) < 14 * 86400 else { continue }
            out.append(NotifyCandidate(kind: .holiday, key: "holiday.\(h.date)", fire: fire, facts: ["holiday": h.name], reason: h.name))
        }
        return out
    }
}

/// folio://title?id=tt…&type=…&name=… opens a title's page (1.25.0, the
/// trending and picks notifications).
enum TitleLink {
    static func url(_ e: TrendEntry) -> String { make(id: e.id, type: e.type, name: e.title, poster: e.poster) }
    static func url(_ m: MetaItem) -> String { make(id: m.id, type: m.type, name: m.name, poster: m.poster) }

    static func make(id: String, type: String, name: String, poster: String?) -> String {
        var c = URLComponents()
        c.scheme = "folio"
        c.host = "title"
        c.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "type", value: type), URLQueryItem(name: "name", value: name)]
            + (poster.map { [URLQueryItem(name: "poster", value: $0)] } ?? [])
        return c.url?.absoluteString ?? "folio://home"
    }

    static func meta(from url: URL) -> MetaItem? {
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func v(_ n: String) -> String? { q.first { $0.name == n }?.value }
        guard let id = v("id"), id.hasPrefix("tt") else { return nil }
        // A poster on the image hosts Folio's titles come from only (1.30.4):
        // any link could make Folio fetch any address.
        return MetaItem(id: id, type: v("type") ?? "movie", name: v("name") ?? "", poster: v("poster").flatMap(posterAllowed), description: nil, releaseInfo: nil, imdbRating: nil, genres: nil)
    }

    /// https on IMDb's (Amazon's) or TMDB's image hosts; nil otherwise.
    static func posterAllowed(_ s: String) -> String? {
        guard let u = URL(string: s), u.scheme?.lowercased() == "https", let host = u.host?.lowercased() else { return nil }
        let ok = host == "image.tmdb.org" || host == "m.media-amazon.com" || host.hasSuffix(".media-amazon.com") || host.hasSuffix(".media-imdb.com")
        return ok ? s : nil
    }
}

/// folio://libtitle?path=… opens a library title's page (1.25.0).
enum LibraryLink {
    static func url(_ path: String) -> String {
        var c = URLComponents()
        c.scheme = "folio"
        c.host = "libtitle"
        c.queryItems = [URLQueryItem(name: "path", value: path)]
        return c.url?.absoluteString ?? "folio://home"
    }

    static func path(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value
    }

    /// `path` when it's a file in Media (or one of `library`'s files), as
    /// the notifications make them (1.30.4); nil for anything else in the
    /// app's container, which any link could name.
    static func allowed(_ path: String, media: String, library: Set<String> = []) -> String? {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        // /private/var and /var are one place on iOS: compared without it.
        func plain(_ p: String) -> String { p.hasPrefix("/private/var/") ? String(p.dropFirst("/private".count)) : p }
        let clean = URL(fileURLWithPath: path).standardizedFileURL.path
        let root = plain(URL(fileURLWithPath: media).standardizedFileURL.path)
        if plain(clean).hasPrefix(root + "/") || library.contains(clean) || library.map(plain).contains(plain(clean)) { return clean }
        return nil
    }
}
