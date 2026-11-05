import Foundation

/// Air times as Folio shows them: in your time zone, in your locale's clock
/// ("Today 9:00 PM", "Tue 2:30 AM", "in 3 h").
///
/// Every time comes from a moment (TVmaze's airstamp, AniList's airingAt),
/// never from a date and time in the network's own zone (TVmaze's airdate
/// and airtime aren't read at all). 1.22.1: the calendar is the
/// autoupdating one, so a time zone changed while Folio is open (a trip,
/// Settings → General → Date & Time) shows at once.
enum AiringFormat {
    /// "Today 9:00 PM", "Tomorrow 9:00 PM", "Yesterday 9:00 PM", "Tue 2:30 AM"
    /// (this week), "Nov 20, 9:00 PM" (further off), "May 20, 2019, 11:00 AM"
    /// (another year).
    ///
    /// With `day` (the network's date when the hour isn't known, 1.22.6):
    /// the day alone, "Today", "Tomorrow", "Fri", "Nov 13".
    static func when(_ date: Date, day: String? = nil, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        if let day, let d = Self.date(ofDay: day, calendar: calendar) { return dayOnly(d, now: now, calendar: calendar, locale: locale) }
        let time = formatter("jmm", calendar, locale).string(from: date)
        let days = dayOffset(date, from: now, calendar: calendar)
        switch days {
        case 0: return "Today \(time)"
        case 1: return "Tomorrow \(time)"
        case -1: return "Yesterday \(time)"
        case 2...6: return "\(formatter("EEE", calendar, locale).string(from: date)) \(time)"
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            return "\(formatter(sameYear ? "MMMd" : "yMMMd", calendar, locale).string(from: date)), \(time)"
        }
    }

    /// "Out now" (aired in the last six hours), "Aired" (before that),
    /// "in 45 min", "in 3 h", "in 2 days". With a calendar (what the
    /// screens pass, 1.22.1) a day or more away counts the calendar days, so
    /// it agrees with the day beside it: "Tomorrow 9:00 PM" 39 hours off was
    /// "in 2 days" (simulator screenshot, 3 Nov); it's "in 1 day" now.
    ///
    /// With `day` (no hour known, 1.22.6): "Today", "in 1 day", "in 2 days",
    /// then "Aired" from the next day.
    static func countdown(to date: Date, day: String? = nil, now: Date = Date(), calendar: Calendar? = nil) -> String {
        if let day {
            let cal = calendar ?? .autoupdatingCurrent
            if let d = Self.date(ofDay: day, calendar: cal) {
                let n = dayOffset(d, from: now, calendar: cal)
                return n < 0 ? "Aired" : n == 0 ? "today" : n == 1 ? "in 1 day" : "in \(n) days"
            }
        }
        let s = date.timeIntervalSince(now)
        if s <= 0 { return -s < AiringClock.outNowWindow ? "Out now" : "Aired" }
        let minutes = Int((s / 60).rounded(.up))
        if minutes < 60 { return "in \(minutes) min" }
        let hours = Int((s / 3600).rounded())
        if hours < 24 { return "in \(hours) h" }
        let days = calendar.map { max(1, dayOffset(date, from: now, calendar: $0)) } ?? Int((s / 86400).rounded())
        return days == 1 ? "in 1 day" : "in \(days) days"
    }

    /// An episode tile's line on a title page (1.22.1): "Airs today 9:00 PM",
    /// "Airs Tue 9:00 PM", "Airs Nov 20, 9:00 PM".
    static func airs(_ date: Date, day: String? = nil, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        var w = when(date, day: day, now: now, calendar: calendar, locale: locale)
        if w.hasPrefix("Today") || w.hasPrefix("Tomorrow") || w.hasPrefix("Yesterday") { w = w.prefix(1).lowercased() + w.dropFirst() }
        return "Airs " + w
    }

    /// The countdown standing on its own, as a tile shows it: "In 2 days", "In 3 h".
    static func countdownTitle(to date: Date, day: String? = nil, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> String {
        let s = countdown(to: date, day: day, now: now, calendar: calendar)
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    /// What Siri says (NextEpisodeIntent): "MobLand season 1, episode 5,
    /// “The Fall”, airs today at 9:00 PM, in 3 hours."
    static func spoken(_ show: TrackedShow, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        if let e = show.upcoming(after: now).first, let day = e.day, let d = date(ofDay: day, calendar: calendar) {
            // Day only (1.23.0): no made-up hour, no "in 3 hours".
            var lead = episodeWords(e).map { "\(show.name) \($0)" } ?? "The next episode of \(show.name)"
            if let t = e.title { lead += ", “\(t)”," }
            let when: String
            switch dayOffset(d, from: now, calendar: calendar) {
            case ...0: when = "today"
            case 1: when = "tomorrow"
            case 2...6: when = "on " + formatter("EEEE", calendar, locale).string(from: d)
            default: when = "on " + formatter("MMMMd", calendar, locale).string(from: d)
            }
            return "\(lead) comes out \(when)."
        }
        if let e = show.upcoming(after: now).first, let d = e.airDate {
            let rel = RelativeDateTimeFormatter()
            rel.locale = locale
            rel.unitsStyle = .full
            var lead = episodeWords(e).map { "\(show.name) \($0)" } ?? "The next episode of \(show.name)"
            if let t = e.title { lead += ", “\(t)”," }
            return "\(lead) airs \(spokenDay(d, now: now, calendar: calendar, locale: locale)), \(rel.localizedString(for: d, relativeTo: now))."
        }
        if let e = show.headline(at: now), let d = e.airDate {
            let what = episodeWords(e).map { " \($0)" } ?? ""
            return "\(show.name)\(what) came out \(spokenDay(d, now: now, calendar: calendar, locale: locale)). There's no date for the next one yet."
        }
        if show.status == .ended { return "\(show.name) has ended." }
        return "There's no date for the next episode of \(show.name) yet."
    }

    /// "season 1, episode 5", "episode 12".
    private static func episodeWords(_ e: AiringEpisode) -> String? {
        switch (e.season, e.number) {
        case let (s?, n?): return "season \(s), episode \(n)"
        case let (nil, n?): return "episode \(n)"
        default: return nil
        }
    }

    /// "today at 9:00 PM", "tomorrow at…", "on Tuesday at…", "on November 20 at…".
    private static func spokenDay(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let time = formatter("jmm", calendar, locale).string(from: date)
        switch dayOffset(date, from: now, calendar: calendar) {
        case 0: return "today at \(time)"
        case 1: return "tomorrow at \(time)"
        case -1: return "yesterday at \(time)"
        case 2...6: return "on \(formatter("EEEE", calendar, locale).string(from: date)) at \(time)"
        default: return "on \(formatter("MMMMd", calendar, locale).string(from: date)) at \(time)"
        }
    }

    /// "2026-11-13" as that day in `calendar` (its start): the network's
    /// date stays that date wherever you are.
    static func date(ofDay day: String, calendar: Calendar) -> Date? {
        let p = day.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    /// "Today", "Tomorrow", "Yesterday", "Fri", "Nov 13", "Nov 13, 2027".
    private static func dayOnly(_ d: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        switch dayOffset(d, from: now, calendar: calendar) {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...6: return formatter("EEE", calendar, locale).string(from: d)
        default:
            let sameYear = calendar.component(.year, from: d) == calendar.component(.year, from: now)
            return formatter(sameYear ? "MMMd" : "yMMMd", calendar, locale).string(from: d)
        }
    }

    /// Calendar days from `now`'s to `date`'s, in the calendar's time zone.
    static func dayOffset(_ date: Date, from now: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }

    // DateFormatter is slow to make: one per template, locale and zone.
    private static var formatters: [String: DateFormatter] = [:]
    private static let lock = NSLock()

    private static func formatter(_ template: String, _ calendar: Calendar, _ locale: Locale) -> DateFormatter {
        let key = "\(template)|\(locale.identifier)|\(calendar.timeZone.identifier)|\(calendar.identifier)"
        lock.lock(); defer { lock.unlock() }
        if let f = formatters[key] { return f }
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate(template)
        formatters[key] = f
        return f
    }
}

/// Which date an episode row shows when IMDb and TVmaze disagree (1.22.6).
enum EpisodeDateCheck {
    /// How far back a date still gets checked: an episode out in the last
    /// month. Older dates are history; IMDb's stay.
    static let window: TimeInterval = 30 * 86400

    /// TVmaze's date ("2026-11-13") for an episode out lately or still to
    /// come by either date, or one IMDb has no date for; else IMDb's. Nil
    /// when neither has one.
    static func pick(imdb: String?, tvmaze: String?, now: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String? {
        let i = imdb.map { String($0.prefix(10)) }.flatMap { $0.count == 10 ? $0 : nil }
        guard let t = tvmaze, t.count == 10, AiringFormat.date(ofDay: t, calendar: calendar) != nil else { return imdb }
        guard let i else { return t }
        if i == t { return imdb }
        let recent: (String) -> Bool = { d in
            guard let day = AiringFormat.date(ofDay: d, calendar: calendar) else { return false }
            return now.timeIntervalSince(day) < window
        }
        return recent(i) || recent(t) ? t : imdb
    }
}
