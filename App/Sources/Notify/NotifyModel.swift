import Foundation

/// Folio's notifications (1.25.0): one engine for every notification the
/// app sends on its own. Reminders about what you're watching (1.24.0), new
/// episodes, finished downloads, and since 1.25.0 your library, what's
/// trending, picks for you, a weekly briefing, and a few that are only jokes.
///
/// Everything is planned on the phone: nothing about what you watch leaves
/// it. The facts come from Folio's own history, watch log and library, from
/// IMDb's public charts, and (only if you set a city) Open-Meteo's forecast
/// and Nager.Date's public holidays.
///
/// Settings → Notifications has a switch per group, a switch per kind inside
/// each group, a personality, quiet hours, a daily maximum, a sound per
/// group, and Test.

/// The groups on the Notifications page, in its order.
enum NotifyGroup: String, CaseIterable, Identifiable, Codable {
    case watching, newReleases, trending, recommendations, library, briefing, fun, downloads
    var id: String { rawValue }

    var title: String {
        switch self {
        case .watching: return "Continue watching"
        case .newReleases: return "New episodes"
        case .trending: return "Trending now"
        case .recommendations: return "Picks for you"
        case .library: return "Your library"
        case .briefing: return "Weekly briefing"
        case .fun: return "Just for fun"
        case .downloads: return "Downloads"
        }
    }

    var subtitle: String {
        switch self {
        case .watching: return "Unfinished films and episodes"
        case .newReleases: return "Tracked shows' new episodes and seasons"
        case .trending: return "What's popular on IMDb this week"
        case .recommendations: return "From what you've watched"
        case .library: return "Forgotten films, milestones, mystery files"
        case .briefing: return "The week's top titles, and a monthly recap"
        case .fun: return "Jokes about your habits, the weather and holidays"
        case .downloads: return "When a download finishes"
        }
    }

    var symbol: String {
        switch self {
        case .watching: return "play.circle"
        case .newReleases: return "sparkles.tv"
        case .trending: return "chart.line.uptrend.xyaxis"
        case .recommendations: return "hand.thumbsup"
        case .library: return "books.vertical"
        case .briefing: return "newspaper"
        case .fun: return "theatermasks"
        case .downloads: return "arrow.down.circle"
        }
    }

    /// New episodes and downloads are news you asked for: they don't count
    /// towards the daily maximum and come whatever the personality.
    var essential: Bool { self == .newReleases || self == .downloads }

    /// At most this many a week (besides the daily maximum), so one group
    /// can't fill every day. Nil: no weekly limit. This is the limit at one
    /// or two a day; `weeklyMax(perDay:)` is the one the planner is given.
    var weeklyMax: Int? {
        switch self {
        case .trending: return 3
        case .recommendations, .library, .fun: return 2
        default: return nil
        }
    }

    /// (0.90.0) The weekly limit grows with "Up to … a Day", so there's
    /// enough to say on a day that has it: as it was at one or two a day,
    /// then half the daily number times it, rounded up (trending 3, 5, 6,
    /// 8 at 2, 3, 4, 5 a day; the others 2, 3, 4, 5).
    func weeklyMax(perDay: Int) -> Int? {
        weeklyMax.map { ($0 * max(2, perDay) + 1) / 2 }
    }

    var kinds: [NotifyKind] { NotifyKind.allCases.filter { $0.group == self } }
}

/// Every notification Folio can send. The raw value is stable: it names the
/// kind in settings, in the sent list and in the rotation of wordings.
enum NotifyKind: String, CaseIterable, Identifiable, Codable {
    // Continue watching (the 1.24.0 moments)
    case paused, cliffhanger, filmNearlyDone, showNearlyDone, friday, lateNight, binge, weekAway, houseplants
    // New episodes (the tracker's)
    case newEpisode, newSeason
    // Trending now (IMDb's Most Popular charts)
    case trendingMovie, trendingSeries, risingFast, viral, topRated, highlyRatedSeries, lowRatedPopular, comeback, ratingMilestone, popularGenre
    // Picks for you
    case forYouPick, hiddenGem, genreStreak
    // Your library
    case forgotten, bigCollection, unwatchedClassic, mysteryFile, milestone, rediscovery
    // Weekly briefing
    case weeklyBriefing, freshTitles, monthlyRecap
    // Just for fun
    case openedNoWatch, longChoosing, streak, unfinishedPile, crimeDoc, movieNight, weekendForecast, lateNightThriller, rainy, cold, hot, holiday
    // Downloads
    case downloadFinished

    var id: String { rawValue }

    var group: NotifyGroup {
        switch self {
        case .paused, .cliffhanger, .filmNearlyDone, .showNearlyDone, .friday, .lateNight, .binge, .weekAway, .houseplants: return .watching
        case .newEpisode, .newSeason: return .newReleases
        case .trendingMovie, .trendingSeries, .risingFast, .viral, .topRated, .highlyRatedSeries, .lowRatedPopular, .comeback, .ratingMilestone, .popularGenre: return .trending
        case .forYouPick, .hiddenGem, .genreStreak: return .recommendations
        case .forgotten, .bigCollection, .unwatchedClassic, .mysteryFile, .milestone, .rediscovery: return .library
        case .weeklyBriefing, .freshTitles, .monthlyRecap: return .briefing
        case .openedNoWatch, .longChoosing, .streak, .unfinishedPile, .crimeDoc, .movieNight, .weekendForecast, .lateNightThriller, .rainy, .cold, .hot, .holiday: return .fun
        case .downloadFinished: return .downloads
        }
    }

    /// Doesn't hang on what you do in Folio (1.28.5): IMDb's charts, the
    /// Friday briefing and new titles, the weather, holidays and Friday's
    /// film night. These stay pending while Folio is open, and show over
    /// it when their moment comes; the rest (what you're watching, your
    /// library, picks from it, your habits) are taken back, since watching
    /// can make them wrong. Every one is planned again when Folio leaves.
    var keptWhileOpen: Bool {
        switch self {
        case .trendingMovie, .trendingSeries, .risingFast, .viral, .topRated, .highlyRatedSeries, .lowRatedPopular,
             .comeback, .ratingMilestone, .popularGenre,
             .weeklyBriefing, .freshTitles,
             .movieNight, .weekendForecast, .rainy, .cold, .hot, .holiday:
            return true
        default:
            return false
        }
    }

    /// (0.90.0) Still true enough to send a day after it was planned, when
    /// the data it came from has moved on: something that happened (a
    /// climb, a rating passed, titles that were new on the charts, the
    /// month's recap) or a pick. Not the ones that say "the most popular"
    /// (new charts name another, which gets its own), the weather (the
    /// forecast changed), or anything about what you're watching, your
    /// library or your habits (it went because you did something).
    var outlivesRefresh: Bool {
        switch self {
        case .risingFast, .viral, .topRated, .highlyRatedSeries, .lowRatedPopular, .comeback, .ratingMilestone, .popularGenre,
             .freshTitles, .monthlyRecap, .forYouPick, .hiddenGem:
            return true
        default:
            return false
        }
    }

    /// (0.90.0) For the ones with a moment of their own: how long after it
    /// they're still worth sending, when the moment came while Folio was in
    /// front and they had been taken back. Nil: no use later ("a week
    /// away" to someone who was just in Folio, a thriller before bed the
    /// morning after).
    var holdsFor: TimeInterval? {
        switch self {
        case .paused, .cliffhanger, .filmNearlyDone, .showNearlyDone, .monthlyRecap: return 24 * 3600
        // About today: later the same day or evening, not tomorrow.
        case .weekendForecast, .holiday: return 8 * 3600
        case .weeklyBriefing: return 5 * 3600
        // Not .friday: past its hour its candidate is next week's, under
        // another key, so there is nothing of today's to move on.
        case .lateNight, .binge: return 4 * 3600
        case .movieNight: return 3 * 3600
        default: return nil
        }
    }

    /// The name in the group's list of switches and in the sent list.
    var title: String {
        switch self {
        case .paused: return "An episode left paused"
        case .cliffhanger: return "Left on a cliffhanger"
        case .filmNearlyDone: return "A film nearly done"
        case .showNearlyDone: return "A show nearly done"
        case .friday: return "Friday"
        case .lateNight: return "After a late night"
        case .binge: return "After a binge"
        case .weekAway: return "A week away"
        case .houseplants: return "Twelve days away"
        case .newEpisode: return "A new episode is out"
        case .newSeason: return "A new season starts"
        case .trendingMovie: return "The most popular film"
        case .trendingSeries: return "The most popular show"
        case .risingFast: return "Rising fast"
        case .viral: return "Straight into the top 10"
        case .topRated: return "A new film rated 8.5 or more"
        case .highlyRatedSeries: return "A popular show rated 9 or more"
        case .lowRatedPopular: return "Popular, but rated low"
        case .comeback: return "An old favourite climbing"
        case .ratingMilestone: return "A title passing 100K ratings"
        case .popularGenre: return "Your genre having a moment"
        case .forYouPick: return "A pick from what you watch"
        case .hiddenGem: return "A hidden gem"
        case .genreStreak: return "Your genre this month"
        case .forgotten: return "A film you never started"
        case .bigCollection: return "Lots unwatched"
        case .unwatchedClassic: return "A classic you own, unwatched"
        case .mysteryFile: return "A file Folio can't name"
        case .milestone: return "Library milestones"
        case .rediscovery: return "A film you own is trending"
        case .weeklyBriefing: return "Friday: the week's top titles"
        case .freshTitles: return "New titles worth knowing"
        case .monthlyRecap: return "The month's recap"
        case .openedNoWatch: return "Opened, watched nothing"
        case .longChoosing: return "A long time choosing"
        case .streak: return "Days in a row"
        case .unfinishedPile: return "Lots left unfinished"
        case .crimeDoc: return "Crime documentaries"
        case .movieNight: return "Friday movie night"
        case .weekendForecast: return "Your weekend forecast"
        case .lateNightThriller: return "A thriller before bed"
        case .rainy: return "Rain tomorrow"
        case .cold: return "A cold day"
        case .hot: return "A hot day"
        case .holiday: return "Public holidays"
        case .downloadFinished: return "A download finished"
        }
    }

    /// Needs a city (Settings → Notifications → Just for fun → Weather).
    var needsWeather: Bool { [.rainy, .cold, .hot].contains(self) }
    var needsHolidays: Bool { self == .holiday }
    /// Needs IMDb's charts, fetched when Folio is open (and in iOS's background refresh).
    var needsCharts: Bool {
        group == .trending || [.weeklyBriefing, .freshTitles, .monthlyRecap, .rediscovery, .unwatchedClassic].contains(self)
    }
}

/// How the lines sound. Subtle is plain facts; Balanced is the 1.24.0 voice;
/// Unhinged goes further. Just for fun is off in Subtle (it has no facts to give).
enum NotifyTone: String, CaseIterable, Identifiable, Codable {
    case subtle, balanced, unhinged
    var id: String { rawValue }
    var title: String {
        switch self {
        case .subtle: return "Subtle"
        case .balanced: return "Balanced"
        case .unhinged: return "Unhinged"
        }
    }
    var subtitle: String {
        switch self {
        case .subtle: return "Mostly informative"
        case .balanced: return "Funny but useful"
        case .unhinged: return "Maximum personality"
        }
    }
}

/// When nothing non-essential comes. Minutes from midnight; start > end
/// crosses midnight. start == end: no quiet hours.
struct QuietHours: Hashable, Codable {
    var start: Int
    var end: Int

    static let standard = QuietHours(start: 22 * 60, end: 9 * 60)

    var isOff: Bool { start == end }

    func contains(_ date: Date, calendar: Calendar) -> Bool {
        guard !isOff else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return start < end ? (m >= start && m < end) : (m >= start || m < end)
    }

    /// "10 PM – 9 AM" in the phone's style.
    func label(locale: Locale = .autoupdatingCurrent) -> String {
        guard !isOff else { return "No quiet hours" }
        func t(_ m: Int) -> String {
            var c = DateComponents()
            c.hour = m / 60
            c.minute = m % 60
            let d = Calendar(identifier: .gregorian).date(from: c) ?? Date()
            let f = DateFormatter()
            f.locale = locale
            f.timeZone = Calendar(identifier: .gregorian).timeZone
            f.setLocalizedDateFormatFromTemplate(m % 60 == 0 ? "j" : "jmm")
            return f.string(from: d)
        }
        return "\(t(start)) – \(t(end))"
    }
}

/// The settings, read where they're needed (UserDefaults, registered in SettingsKey.registerDefaults).
enum NotifyPrefs {
    static var d: UserDefaults { .standard }

    static func groupOn(_ g: NotifyGroup) -> Bool {
        switch g {
        // These two have lived in Tracking and Downloads since 1.21.0 / 1.9.0; the switch is theirs.
        case .newReleases: return AiringAlerts.current != .off
        case .downloads: return d.bool(forKey: SettingsKey.downloadNotify)
        case .watching: return d.bool(forKey: SettingsKey.engageNotes)
        default: return !(d.stringArray(forKey: SettingsKey.notifyGroupsOff) ?? []).contains(g.rawValue)
        }
    }

    static func setGroup(_ g: NotifyGroup, on: Bool) {
        switch g {
        case .newReleases:
            if on {
                let last = d.string(forKey: "notifyAiringLast") ?? AiringAlerts.air.rawValue
                d.set(last == AiringAlerts.off.rawValue ? AiringAlerts.air.rawValue : last, forKey: SettingsKey.airingAlerts)
            } else {
                d.set(AiringAlerts.current.rawValue, forKey: "notifyAiringLast")
                d.set(AiringAlerts.off.rawValue, forKey: SettingsKey.airingAlerts)
            }
        case .downloads: d.set(on, forKey: SettingsKey.downloadNotify)
        case .watching: d.set(on, forKey: SettingsKey.engageNotes)
        default:
            var off = Set(d.stringArray(forKey: SettingsKey.notifyGroupsOff) ?? [])
            if on { off.remove(g.rawValue) } else { off.insert(g.rawValue) }
            d.set(off.sorted(), forKey: SettingsKey.notifyGroupsOff)
        }
    }

    static var kindsOff: Set<String> { Set(d.stringArray(forKey: SettingsKey.notifyKindsOff) ?? []) }

    static func kindOn(_ k: NotifyKind) -> Bool { !kindsOff.contains(k.rawValue) }

    static func setKind(_ k: NotifyKind, on: Bool) {
        var off = kindsOff
        if on { off.remove(k.rawValue) } else { off.insert(k.rawValue) }
        d.set(off.sorted(), forKey: SettingsKey.notifyKindsOff)
    }

    static var tone: NotifyTone {
        get { NotifyTone(rawValue: d.string(forKey: SettingsKey.notifyTone) ?? "") ?? .balanced }
        set { d.set(newValue.rawValue, forKey: SettingsKey.notifyTone) }
    }

    static var quiet: QuietHours {
        get { QuietHours(start: d.integer(forKey: SettingsKey.notifyQuietStart), end: d.integer(forKey: SettingsKey.notifyQuietEnd)) }
        set {
            d.set(newValue.start, forKey: SettingsKey.notifyQuietStart)
            d.set(newValue.end, forKey: SettingsKey.notifyQuietEnd)
        }
    }

    /// Non-essential notifications a day at most, 1…5 (0.90.0: "Up to … a Day").
    static var maxPerDay: Int { min(5, max(1, d.integer(forKey: SettingsKey.notifyMaxPerDay))) }

    static var test: Bool { d.bool(forKey: SettingsKey.notifyTest) }

    /// Folio's notifications as a whole (1.28.5). Off, none come: new
    /// episodes and finished downloads too. Each group keeps its own switch
    /// for when they're on again.
    static var allOn: Bool {
        get { !d.bool(forKey: SettingsKey.notifyAllOff) }
        set { d.set(!newValue, forKey: SettingsKey.notifyAllOff) }
    }

    /// Its group and itself are on, and the personality allows it (Test sends these).
    static func switchedOn(_ k: NotifyKind) -> Bool {
        allOn && groupOn(k.group) && kindOn(k) && !(k.group == .fun && tone == .subtle)
    }

    /// Switched on, and what it needs is set up (a city for the weather).
    @MainActor
    static func allowed(_ k: NotifyKind) -> Bool {
        guard switchedOn(k) else { return false }
        if k.needsWeather, WeatherFeed.place == nil { return false }
        if k.needsHolidays, WeatherFeed.place == nil, Locale.current.region == nil { return false }
        return true
    }
}
