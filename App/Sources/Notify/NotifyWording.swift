import Foundation

/// Every line Folio's notifications can say (1.25.0), by kind and tone.
/// `{name}` is filled from the notification's facts; a line whose facts
/// aren't all known isn't used. Each kind rotates through its lines, so the
/// same one never comes twice in a row.
///
/// Balanced's first line of the watching moments is the one picked on
/// 6 Nov (EngagePlanner.Text), so 1.24.0's wording stays where it was.
enum NotifyWording {
    struct Line: Equatable {
        var title: String?
        var body: String
    }

    static func L(_ body: String) -> Line { Line(title: nil, body: body) }
    static func L(_ title: String, _ body: String) -> Line { Line(title: title, body: body) }

    /// The lines of `kind` in `tone`. Subtle falls back to nothing (the
    /// caller then uses the plain wording) only for the essential kinds.
    static func lines(_ kind: NotifyKind, _ tone: NotifyTone) -> [Line] {
        table[kind]?[tone] ?? []
    }

    /// The text with its facts filled in, or nil when one is missing.
    static func fill(_ line: Line, _ facts: [String: String]) -> (title: String?, body: String)? {
        guard let body = fill(line.body, facts) else { return nil }
        if let t = line.title {
            guard let title = fill(t, facts) else { return nil }
            return (title, body)
        }
        return (nil, body)
    }

    static func fill(_ text: String, _ facts: [String: String]) -> String? {
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { return nil }
            let key = String(rest[rest.index(after: open)..<close])
            guard let v = facts[key], !v.isEmpty else { return nil }
            out += v
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    /// The usable lines (all facts known) of a kind, in order.
    static func usable(_ kind: NotifyKind, _ tone: NotifyTone, _ facts: [String: String]) -> [(title: String?, body: String)] {
        lines(kind, tone).compactMap { fill($0, facts) }
    }

    /// The `variation`th usable line (wrapping), or nil.
    static func text(_ kind: NotifyKind, _ tone: NotifyTone, _ facts: [String: String], variation: Int) -> (title: String?, body: String)? {
        let u = usable(kind, tone, facts)
        guard !u.isEmpty else { return nil }
        return u[((variation % u.count) + u.count) % u.count]
    }

    // MARK: The lines

    static let table: [NotifyKind: [NotifyTone: [Line]]] = [
        // Continue watching
        .paused: [
            .subtle: [L("{show} is paused at {time}."), L("Pick up {show} where you left it, at {time}.")],
            .balanced: [L("{show} is paused at {time}. Everyone's frozen mid-sentence. They'd like to finish it."),
                        L("{show} stopped at {time}. The characters are holding their breath. It's been a while."),
                        L("Somewhere in {show}, at {time}, someone is still mid-blink.")],
            .unhinged: [L("{show} has been frozen at {time} for two days. Nobody in there can blink until you come back."),
                        L("You paused {show} at {time}. The cast has started a union.")],
        ],
        .cliffhanger: [
            .subtle: [L("The next episode of {show} is in your library."), L("{show}: the next episode is ready.")],
            .balanced: [L("You left {show} hanging off a cliff. The cliff is getting impatient."),
                        L("{show} ended on a cliffhanger and you just… left. Bold."),
                        L("The next episode of {show} is right there. The cliff won't hold forever.")],
            .unhinged: [L("You left {show} dangling off a cliff and went to bed. Monster."),
                        L("The cliff in {show} has filed a complaint.")],
        ],
        .filmNearlyDone: [
            .subtle: [L("{film}: {minutes} minutes left."), L("Finish {film}: {minutes} minutes to go.")],
            .balanced: [L("{film} has {minutes} minutes left. The credits miss you."),
                        L("{minutes} minutes of {film} left. You're so close to knowing how it ends."),
                        L("{film} is {minutes} minutes from the end. The ending is getting cold.")],
            .unhinged: [L("You watched most of {film} and quit with {minutes} minutes left. Who raised you?"),
                        L("{film}: {minutes} minutes. Shorter than the time you've spent ignoring it.")],
        ],
        .showNearlyDone: [
            .subtle: [L("{left} episodes of {show} left in your library.")],
            .balanced: [L("{left} episodes left of {show}. Finish it, or we'll tell everyone you quit."),
                        L("{show} is down to {left} episodes. The finish line can see you."),
                        L("Only {left} episodes of {show} to go. Endings are better than you remember.")],
            .unhinged: [L("{left} episodes. {show} is right there. Finishing things is a skill. Apparently not yours."),
                        L("{left} episodes of {show} left. Quitting now would be a choice. A weird one.")],
        ],
        .friday: [
            .subtle: [L("It's Friday. {show} has {left} episodes left.")],
            .balanced: [L("It's Friday. {show} has {left} episodes left. Coincidence? No."),
                        L("Friday night, {left} episodes of {show}. The maths works out."),
                        L("It's Friday and {show} has {left} episodes waiting. Plans? Cancelled.")],
            .unhinged: [L("Friday. {left} episodes of {show}. Your social life will understand."),
                        L("It's Friday. Other people are going out. You have {left} episodes of {show}. Who's winning?")],
        ],
        .lateNight: [
            .subtle: [L("You watched {show} until {time}.")],
            .balanced: [L("Up until {time} with {show}. We're not judging. Your eyes are."),
                        L("{show} until {time}? Respect. Maybe a nap."),
                        L("{time} with {show}. Sleep called. It went to voicemail.")],
            .unhinged: [L("Up until {time} with {show}. Your future self has notes."),
                        L("{time}. {show}. Your pillow has reported you missing.")],
        ],
        .binge: [
            .subtle: [L("{n} episodes yesterday.")],
            .balanced: [L("{n} episodes yesterday. That's not a binge, that's a lifestyle."),
                        L("You said one episode. It was {n}. We don't judge."),
                        L("{n} episodes in a day. The Next Episode button has never felt so loved.")],
            .unhinged: [L("{n} episodes yesterday. At this point the show is watching you."),
                        L("You said one episode. It's been {n}. We're telling your mum.")],
        ],
        .weekAway: [
            .subtle: [L("It's been a week since you watched anything in Folio.")],
            .balanced: [L("7 days. Your Continue Watching row is gathering dust. And small spiders."),
                        L("A week away. Your shows have started rewatching themselves out of boredom."),
                        L("Seven days. Your Continue Watching row has started talking to itself.")],
            .unhinged: [L("7 days. We assumed you'd been kidnapped. Blink twice if you need a series."),
                        L("A whole week. Your Continue Watching row has stopped believing in love.")],
        ],
        .houseplants: [
            .subtle: [L("{show} is still in Continue Watching.")],
            .balanced: [L("{show} is still waiting. Unlike your houseplants, it can't die of neglect. Probably."),
                        L("Twelve days. {show} is still where you left it. Loyal, really."),
                        L("{show} hasn't moved in twelve days. Neither, it seems, have you.")],
            .unhinged: [L("{show} is still waiting. It's the only thing in your life that hasn't given up on you."),
                        L("Twelve days. {show} has started writing you letters.")],
        ],

        // New episodes: Subtle keeps the tracker's plain wording.
        .newEpisode: [
            .balanced: [L("{what} is out", "Your evening plans just changed."),
                         L("{what} is out", "We'd recommend touching grass, but there's a new episode."),
                         L("{what} is out", "Good news: something new to watch. Bad news: there goes your evening.")],
            .unhinged: [L("{what} is out", "Drop everything. Not literally. Okay, literally."),
                        L("{what} is out", "We'd recommend touching grass, but come on.")],
        ],
        .newSeason: [
            .balanced: [L("{show} S{season} is out", "Good news: something to watch. Bad news: there goes sleep."),
                        L("{show} S{season} is out", "A whole new season. Your weekend is spoken for.")],
            .unhinged: [L("{show} S{season} is out", "Sleep is cancelled until further notice."),
                        L("{show} S{season} is out", "Season {season}. Your plans were cute.")],
        ],

        // Trending now
        .trendingMovie: [
            .subtle: [L("Most popular film this week", "{title} is #1 on IMDb's Most Popular Movies.")],
            .balanced: [L("Everyone's talking about {title}. Have you seen it?"),
                        L("Apparently, everyone's watching {title}. Peer pressure, but make it cinema."),
                        L("{title} is IMDb's most popular film this week. Just saying.")],
            .unhinged: [L("{title} is #1. Resisting is futile. Mildly futile."),
                        L("The whole internet is watching {title}. Are you even online?")],
        ],
        .trendingSeries: [
            .subtle: [L("Most popular show this week", "{title} is #1 on IMDb's Most Popular TV.")],
            .balanced: [L("{title} is the most popular show on IMDb right now. Your group chat will bring it up soon."),
                        L("The internet has a new obsession: {title}."),
                        L("{title} is top of the charts. Peer pressure, but make it television.")],
            .unhinged: [L("Everyone's watching {title}. You'll be the last to know the twist."),
                        L("{title} is #1. The spoilers are coming for you.")],
        ],
        .risingFast: [
            .subtle: [L("{title} climbed {places} places to #{rank} on IMDb's popularity chart.")],
            .balanced: [L("{title} just climbed {places} places. Something's happening."),
                        L("{title} is climbing the charts faster than your unfinished list grows."),
                        L("Up {places} places in a week: {title}. Now #{rank}.")],
            .unhinged: [L("{title} jumped {places} places. Either it's brilliant or everyone's lost it. Find out."),
                        L("{places} places in a week. {title} is on something.")],
        ],
        .viral: [
            .subtle: [L("{title} went straight into IMDb's top 10, at #{rank}.")],
            .balanced: [L("Your social feeds are probably full of {title}. It just hit #{rank}."),
                        L("{title} came out of nowhere into the top 10.")],
            .unhinged: [L("{title} is in the top 10 and you haven't seen it. Embarrassing. For you.")],
        ],
        .topRated: [
            .subtle: [L("{title} is rated {rating} on IMDb.")],
            .balanced: [L("The ratings are in. {title} is sitting at {rating}."),
                        L("{title}: {rating} on IMDb. That's rare air.")],
            .unhinged: [L("{title} is rated {rating}. Barely anyone in your watch history has taste this good. Kidding. Mostly.")],
        ],
        .highlyRatedSeries: [
            .subtle: [L("{title} is rated {rating} on IMDb and climbing the charts.")],
            .balanced: [L("A new {rating}-rated obsession just entered the building: {title}."),
                        L("{title}: {rating} on IMDb. People are losing it.")],
            .unhinged: [L("{title} is rated {rating}. Cancel things.")],
        ],
        .lowRatedPopular: [
            .subtle: [L("{title} is #{rank} on IMDb's popularity chart, rated {rating}.")],
            .balanced: [L("{title}: trending everywhere, rated {rating}. We have questions."),
                        L("{title} is #{rank} and rated {rating}. Hate-watch potential: high.")],
            .unhinged: [L("{title} is rated {rating} and everyone's watching anyway. Humanity, explain.")],
        ],
        .comeback: [
            .subtle: [L("{title} ({year}) climbed {places} places on IMDb's popularity chart.")],
            .balanced: [L("An old favourite is making a comeback: {title} ({year}). Nostalgia is undefeated."),
                        L("{title} from {year} is climbing again. Some things never get old.")],
            .unhinged: [L("{title} ({year}) is trending again. The past called. It wants a rewatch.")],
        ],
        .ratingMilestone: [
            .subtle: [L("{title} passed {votes} ratings on IMDb.")],
            .balanced: [L("{title} just crossed {votes} ratings. That's a lot of opinions.")],
            .unhinged: [L("{votes} people rated {title}. Imagine the arguments.")],
        ],
        .popularGenre: [
            .subtle: [L("{genre}: {n} of IMDb's 20 most popular titles this week.")],
            .balanced: [L("{genre} is having a moment: {n} of the top 20 this week. Here's what's worth watching.")],
            .unhinged: [L("{genre} has taken over the charts. Your taste is mainstream now. Sorry.")],
        ],

        // Picks for you
        .forYouPick: [
            .subtle: [L("From what you've watched: {title}.")],
            .balanced: [L("{title} looks a lot like your kind of thing."),
                        L("From your history, {title} should be next. We're rarely wrong. Sometimes.")],
            .unhinged: [L("We studied your watch history. {title}. Trust the process.")],
        ],
        .hiddenGem: [
            .subtle: [L("{title}: rated {rating} on IMDb, from what you've watched.")],
            .balanced: [L("Not trending. Not viral. Just ridiculously good: {title}."),
                        L("{title}, {rating} on IMDb, and barely anyone's talking about it.")],
            .unhinged: [L("{title} is rated {rating} and nobody you know has seen it. Be insufferable about it.")],
        ],
        .genreStreak: [
            .subtle: [L("You've watched {n} {genre} titles this month.")],
            .balanced: [L("You've watched {n} {genre} titles this month. We think we know your type.")],
            .unhinged: [L("{n} {genre} titles this month. It's not a phase, is it?")],
        ],

        // Your library
        .forgotten: [
            .subtle: [L("{title} is in your library, not started yet.")],
            .balanced: [L("Remember {title}? It's been sitting in your library collecting digital dust."),
                        L("{title} has been in your library a while. It's starting to feel like furniture.")],
            .unhinged: [L("{title} has been in your library for ages, untouched. It's starting to take it personally.")],
        ],
        .bigCollection: [
            .subtle: [L("{n} films in your library haven't been watched yet.")],
            .balanced: [L("Your library has {n} unwatched films. Your weekend has a problem.")],
            .unhinged: [L("{n} unwatched films. That's not a library, that's a hostage situation.")],
        ],
        .unwatchedClassic: [
            .subtle: [L("{title} is in your library and in IMDb's Top 250. Not watched yet.")],
            .balanced: [L("You own {title} and still haven't watched it? Interesting.")],
            .unhinged: [L("You own {title} and haven't watched it. We're not mad. We're disappointed.")],
        ],
        .mysteryFile: [
            .subtle: [L("Folio couldn't find a title for {file}.")],
            .balanced: [L("We found a mystery file: {file}. No poster, no title, just vibes.")],
            .unhinged: [L("{file}. No poster. No title. Could be a masterpiece, could be your cousin's wedding.")],
        ],
        .milestone: [
            .subtle: [L("Your library now has {n} films.")],
            .balanced: [L("You've officially collected {n} films. Your inner librarian is thriving.")],
            .unhinged: [L("{n} films. At this point you're not a viewer, you're an archivist.")],
        ],
        .rediscovery: [
            .subtle: [L("{title}, in your library, is on IMDb's popularity chart this week.")],
            .balanced: [L("A film in your library is trending again: {title}. Convenient, isn't it?")],
            .unhinged: [L("{title} is trending and you already own it. Smug mode: on.")],
        ],

        // Weekly briefing
        .weeklyBriefing: [
            .subtle: [L("This week's most popular", "{list}")],
            .balanced: [L("Your weekend entertainment briefing", "The internet's new obsessions: {list}"),
                        L("This week's top 5 has arrived", "{list}")],
            .unhinged: [L("Weekend briefing", "Everyone's watching: {list}. Resistance is optional.")],
        ],
        .freshTitles: [
            .subtle: [L("New on the charts", "{n} new titles in IMDb's most popular: {list}")],
            .balanced: [L("Fresh off the press", "{n} new titles worth knowing: {list}")],
            .unhinged: [L("Fresh off the press", "{n} new titles everyone will be quoting by Monday: {list}")],
        ],
        .monthlyRecap: [
            .subtle: [L("{month} in review", "Most popular: {list}. You watched {hours}."),
                      L("{month} in review", "Most popular: {list}.")],
            .balanced: [L("{month}'s biggest obsessions", "The results are in: {list}. And you? {hours} of watching."),
                        L("{month}'s biggest obsessions", "The results are in: {list}.")],
            .unhinged: [L("{month}, judged", "The world watched {list}. You watched {hours}. Draw your own conclusions."),
                        L("{month}, judged", "The world watched {list}. Did you?")],
        ],

        // Just for fun (none in Subtle)
        .openedNoWatch: [
            .balanced: [L("You opened Folio {n} times yesterday and watched nothing. Impressive.")],
            .unhinged: [L("{n} visits yesterday, zero minutes watched. Window-shopping champion.")],
        ],
        .longChoosing: [
            .balanced: [L("{minutes} minutes choosing yesterday, nothing played. Today, maybe just pick one."),
                        L("We found something good. Please try not to spend {minutes} minutes choosing.")],
            .unhinged: [L("{minutes} minutes of scrolling and nothing played. The menu was the movie.")],
        ],
        .streak: [
            .balanced: [L("{n} days in a row. Another day, another episode instead of doing something productive.")],
            .unhinged: [L("{n} days straight. Productivity has left the chat.")],
        ],
        .unfinishedPile: [
            .balanced: [L("You have excellent taste. Your {n} unfinished titles say otherwise."),
                        L("{n} things in Continue Watching. Your to-do list is jealous.")],
            .unhinged: [L("{n} unfinished titles. Commitment issues? In this economy?")],
        ],
        .crimeDoc: [
            .balanced: [L("Oh look, another crime documentary. Should we be concerned?")],
            .unhinged: [L("{n} crime documentaries this week. We've locked the doors. Just in case.")],
        ],
        .movieNight: [
            .balanced: [L("🍿 Movie night conditions are looking excellent.")],
            .unhinged: [L("🍿 Friday night forecast: 100% couch. Resistance is pointless.")],
        ],
        .weekendForecast: [
            .balanced: [L("Your weekend forecast: {films} films, {series} series and zero productivity.")],
            .unhinged: [L("Weekend forecast: {films} films, {series} series, scattered snacks, no chance of outside.")],
        ],
        .lateNightThriller: [
            .balanced: [L("🌙 The perfect time for a thriller. Probably a terrible idea.")],
            .unhinged: [L("🌙 Late-night thriller time. Lock the door. Then check it again.")],
        ],
        .rainy: [
            .balanced: [L("🌧️ {chance}% chance of rain today. 100% chance of a movie.")],
            .unhinged: [L("🌧️ {chance}% chance of rain. 0% chance you were going out anyway.")],
        ],
        .cold: [
            .balanced: [L("It's {temp} outside today. Fortunately, your library is warm.")],
            .unhinged: [L("{temp} out there. Stay in. That's not advice, it's an order.")],
        ],
        .hot: [
            .balanced: [L("{temp} today. Too hot to function? We prescribe a nice long series.")],
            .unhinged: [L("{temp}. Outside is a mistake. Inside has episodes.")],
        ],
        .holiday: [
            .balanced: [L("{holiday}. Today's forecast: couch, snacks and absolutely no obligations.")],
            .unhinged: [L("It's {holiday}. Legally, you're allowed to watch everything.")],
        ],

        // Downloads: Subtle keeps the plain "Downloads finished".
        .downloadFinished: [
            .balanced: [L("{what} is downloaded", "The internet can't stop you now."),
                        L("{what} is downloaded", "New arrival! It just landed in your library."),
                        L("{what} is downloaded", "It's in your library. Even the Wi-Fi can't take it back now.")],
            .unhinged: [L("{what} is downloaded", "No buffering. No excuses.")],
        ],
    ]

    /// Facts that stand in when Test sends a kind your watching doesn't have
    /// yet, with a name from your own library or history where there is one.
    static func sample(_ kind: NotifyKind, show: String, film: String, file: String) -> [String: String] {
        let month = DateFormatter().monthSymbols[(Calendar.current.component(.month, from: Date()) + 10) % 12]
        switch kind {
        case .paused, .lateNight: return ["show": show, "time": kind == .paused ? "31:04" : "2:47 AM"]
        case .cliffhanger, .houseplants: return ["show": show]
        case .filmNearlyDone: return ["film": film, "minutes": "38"]
        case .showNearlyDone, .friday: return ["show": show, "left": "3"]
        case .binge: return ["n": "5"]
        case .weekAway, .movieNight, .lateNightThriller: return [:]
        case .newEpisode: return ["what": "\(show) S1 · E5", "show": show]
        case .newSeason: return ["show": show, "season": "2"]
        case .trendingMovie, .trendingSeries, .forYouPick, .forgotten, .unwatchedClassic, .rediscovery: return ["title": kind == .trendingSeries ? show : film]
        case .risingFast: return ["title": show, "places": "18", "rank": "12"]
        case .viral: return ["title": show, "rank": "7"]
        case .topRated, .hiddenGem: return ["title": film, "rating": "8.7"]
        case .highlyRatedSeries: return ["title": show, "rating": "9.2"]
        case .lowRatedPopular: return ["title": film, "rating": "5.4", "rank": "9"]
        case .comeback: return ["title": film, "year": "1993", "places": "37"]
        case .ratingMilestone: return ["title": show, "votes": "100K"]
        case .popularGenre: return ["genre": "Thriller", "n": "6"]
        case .genreStreak: return ["genre": "thriller", "n": "4"]
        case .bigCollection: return ["n": "82"]
        case .mysteryFile: return ["file": file]
        case .milestone: return ["n": "100"]
        case .weeklyBriefing: return ["list": "1. \(show) · 2. \(film) · 3. …"]
        case .freshTitles: return ["n": "5", "list": "\(film), \(show) and 3 more"]
        case .monthlyRecap: return ["month": month, "list": "\(show), \(film)", "hours": "14 hours"]
        case .openedNoWatch: return ["n": "6"]
        case .longChoosing: return ["minutes": "45"]
        case .streak: return ["n": "5"]
        case .unfinishedPile: return ["n": "6"]
        case .crimeDoc: return ["n": "3"]
        case .weekendForecast: return ["films": "3", "series": "1"]
        case .rainy: return ["chance": "90"]
        case .cold: return ["temp": Locale.current.measurementSystem == .us ? "34°" : "2°"]
        case .hot: return ["temp": Locale.current.measurementSystem == .us ? "95°" : "35°"]
        case .holiday: return ["holiday": "A public holiday"]
        case .downloadFinished: return ["what": "\(show) S1 · E6"]
        }
    }
}
