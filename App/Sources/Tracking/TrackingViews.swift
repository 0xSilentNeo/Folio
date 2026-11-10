import SwiftUI
import UIKit
import UserNotifications

// MARK: - Track button

/// The title pages' Track button (Discover's and the library's, series
/// only): a bell and "Track", which becomes a filled bell and "Tracking" in
/// the accent colour. The first Track asks to allow notifications. 1.22.1:
/// always with its words (until then a tight row showed the bell alone,
/// and a tracked show looked much like an untracked one); where the row
/// has no room for them it goes on a line of its own (TitleButtonRow). It
/// keeps one width either way, so tapping it never moves the page.
struct TrackButton: View {
    let show: TrackedShow
    @ObservedObject private var store = TrackingStore.shared
    /// The show has ended (1.22.2: IMDb gives its last year, MetaItem.hasEnded;
    /// 1.22.6: or TVmaze calls it Ended, which IMDb hadn't caught up with
    /// for Thousand-Year Blood War). Nothing is left to air, so there's no
    /// Track button; a show tracked before it ended stops being tracked
    /// once its last episode's week is over (TrackingStore.seriesEnded).
    /// Nil while that's being found out: the button keeps its place but
    /// isn't shown, so it doesn't appear and then vanish.
    @State private var ended: Bool?

    var body: some View {
        let on = store.tracked(like: show) != nil
        Group {
            if ended == true && (!on || store.tracked(like: show)?.isOver(at: Date()) == true) {
                EmptyView()
            } else {
                button(on)
                    .opacity(ended == nil && !on ? 0 : 1)
                    .allowsHitTesting(ended != nil || on)
                    .animation(.easeOut(duration: 0.2), value: ended)
            }
        }
        .task(id: show.imdb) {
            ended = nil
            guard let id = show.imdb else { ended = false; return }
            // The title page's own details, kept 7 days: usually no request of its own.
            let meta = await IMDbSource.details(id: id, type: "series")
            var over = meta?.hasEnded == true
            if over {
                dlog("tracking", "\(show.name) has ended (IMDb \(meta?.releaseInfo ?? "?")–\(meta?.endYear.map(String.init) ?? "")): no Track button")
            } else if let tv = await AiringService.shared.pageSchedule(imdb: id, episodes: false), tv.status == .ended {
                over = true
                dlog("tracking", "\(show.name) has ended (TVmaze; IMDb has \(meta?.releaseInfo ?? "?")–): no Track button")
            }
            guard !Task.isCancelled else { return }
            ended = over
            if over { store.seriesEnded(like: show) }
        }
    }

    private func button(_ on: Bool) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { store.toggle(show) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: on ? "bell.fill" : "bell").contentTransition(.symbolEffect(.replace))
                // As wide as "Tracking" in both states.
                ZStack {
                    Text("Tracking").hidden()
                    Text(on ? "Tracking" : "Track")
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(on ? Theme.onAccent : .primary)
            .padding(.horizontal, 16).frame(height: 44)
            .background { if on { Capsule().fill(Theme.accent) } }
            .glass(cornerRadius: 22, interactive: true)
            .fixedSize()
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(on ? "Tracking" : "Track")
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityHint(on ? "Stops telling you about new episodes." : "Tells you when new episodes air.")
        .accessibilityIdentifier("trackButton")
    }
}

/// Under a tracked show's buttons (1.22.1): that it's tracked, and when
/// the next episode airs in your time zone.
struct TrackStatusLine: View {
    let show: TrackedShow
    @ObservedObject private var store = TrackingStore.shared

    var body: some View {
        if let s = store.tracked(like: show) {
            TimelineView(.everyMinute) { ctx in
                Label(Self.text(s, now: ctx.date), systemImage: "bell.badge")
                    .font(.footnote).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .accessibilityIdentifier("trackStatus")
        }
    }

    /// "Tracking · next S2 · E8 airs Tue 9:00 PM, in 2 days", or why there's no time.
    static func text(_ s: TrackedShow, now: Date, calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        if let e = s.upcoming(after: now).first, let d = e.airDate {
            let airs = AiringFormat.airs(d, day: e.day, now: now, calendar: calendar, locale: locale)
            return "Tracking · next \(e.label) \(airs.prefix(1).lowercased() + airs.dropFirst()), \(AiringFormat.countdown(to: d, day: e.day, now: now, calendar: calendar))"
        }
        return "Tracking · " + TrackedShowRow.line(s, now: now)
    }
}

/// An episode tile's airing mark on a title page (1.22.1): "New" in the
/// accent, or "Airs Tue 9:00 PM" over "In 2 days", in your time zone.
struct AiringBadge: View {
    let mark: AiringMark
    /// One pill ("New", "Airs Tue 9:00 PM"), for a row's line of text.
    var compact = false
    /// The picture it sits on: a longer line ("Airs tomorrow 9:00 PM") is
    /// drawn a little smaller to stay on it.
    var maxWidth: CGFloat? = nil

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            switch mark {
            case .new:
                pill("New", strong: true)
            case .airs(let d, let day) where compact:
                pill(AiringFormat.airs(d, day: day, now: ctx.date), strong: false)
            case .airs(let d, let day):
                VStack(alignment: .leading, spacing: 3) {
                    pill(AiringFormat.airs(d, day: day, now: ctx.date), strong: false)
                    pill(AiringFormat.countdownTitle(to: d, day: day, now: ctx.date), strong: false)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("airingBadge")
    }

    private func pill(_ s: String, strong: Bool) -> some View {
        Text(s).font(.caption2.weight(.bold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            .foregroundStyle(strong ? Theme.onAccent : .white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(strong ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.black.opacity(0.62)), in: Capsule())
            .fixedSize(horizontal: maxWidth == nil, vertical: true)
            .frame(maxWidth: maxWidth, alignment: .leading)
    }
}

/// An episode not out yet on a title page (1.22.1), where its tile will be:
/// its number and title, when it airs in your time zone, and how long until.
struct UpcomingEpisodeCard: View {
    let episode: AiringEpisode

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill)
                    Image(systemName: "calendar.badge.clock").font(.title2).foregroundStyle(.secondary)
                }
                .frame(width: 130, height: 73)
                VStack(alignment: .leading, spacing: 5) {
                    Text([episode.label, episode.title].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline.weight(.semibold)).lineLimit(2)
                    if let d = episode.airDate {
                        Text(AiringFormat.airs(d, day: episode.day, now: ctx.date)).font(.caption.weight(.semibold))
                        Text(AiringFormat.countdownTitle(to: d, day: episode.day, now: ctx.date))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Theme.fill, in: Capsule())
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("upcomingEpisode")
    }
}

/// A title page's buttons in a row, centred on one another. The last one
/// (Track) goes on a line of its own under the others when the row has no
/// room for it (a narrow phone, Resume and Start over, large text).
struct TitleButtonRow: Layout {
    var spacing: CGFloat = 14
    var lineSpacing: CGFloat = 12

    private func measure(_ subviews: Subviews, width: CGFloat) -> (sizes: [CGSize], wrap: Bool) {
        guard let last = subviews.last else { return ([], false) }
        var sizes = subviews.dropLast().map { $0.sizeThatFits(.unspecified) }
        let room = width - sizes.map(\.width).reduce(0, +) - spacing * CGFloat(sizes.count)
        let inline = last.sizeThatFits(ProposedViewSize(width: max(0, room), height: nil))
        if sizes.isEmpty || inline.width <= room + 0.5 {
            sizes.append(inline)
            return (sizes, false)
        }
        sizes.append(last.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil)))
        return (sizes, true)
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        let (sizes, wrap) = measure(subviews, width: width)
        guard !sizes.isEmpty else { return ([], .zero) }
        let line = wrap ? Array(sizes.dropLast()) : sizes
        let lineH = line.map(\.height).max() ?? 0
        var frames: [CGRect] = [], x: CGFloat = 0
        for s in line {
            frames.append(CGRect(x: x, y: (lineH - s.height) / 2, width: s.width, height: s.height))
            x += s.width + spacing
        }
        var size = CGSize(width: max(0, x - spacing), height: lineH)
        if wrap, let last = sizes.last {
            frames.append(CGRect(x: 0, y: lineH + lineSpacing, width: last.width, height: last.height))
            size = CGSize(width: max(size.width, last.width), height: lineH + lineSpacing + last.height)
        }
        return (frames, size)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        let s = arrange(subviews, width: maxW).size
        return CGSize(width: min(s.width, maxW), height: s.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(subviews, width: proposal.width ?? bounds.width).frames
        for (v, f) in zip(subviews, frames) {
            v.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size))
        }
    }
}

// MARK: - Tracking screen

/// Settings → Tracking (and Home's Airing row, and the widget's links): the
/// shows you track, by when they air next. Swipe one to stop tracking it;
/// pull to fetch every schedule again.
struct TrackingView: View {
    @ObservedObject private var store = TrackingStore.shared
    @State private var open: String?

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            list(now: ctx.date)
        }
        .brandListBackground()
        .navigationTitle("Tracked Shows")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $open) { TrackingDetailView(id: $0) }
    }

    private func list(now: Date) -> some View {
        List {
            TrackingAlertsSection()
            if store.shows.isEmpty {
                Section {
                    ContentUnavailableView("Nothing Tracked Yet", systemImage: "bell",
                                           description: Text("Tap Track on a show's page in Discover or your library to see when its next episodes air."))
                }
                .listRowBackground(Color.clear)
            }
            let groups = AiringGroup.grouped(store.shows, now: now)
            ForEach(groups) { g in
                Section {
                    ForEach(g.shows) { s in
                        TrackedShowRow(show: s, now: now) { open = s.id }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { store.untrack(s.id) } label: { Label("Stop Tracking", systemImage: "bell.slash") }
                            }
                            .contextMenu {
                                if let link = s.pageLink {
                                    Link(destination: link.url) { Label("Open on \(link.title)", systemImage: "arrow.up.right.square") }
                                }
                                Button(role: .destructive) { store.untrack(s.id) } label: { Label("Stop Tracking", systemImage: "bell.slash") }
                            }
                    }
                } header: {
                    Text(g.group.title)
                } footer: {
                    // Under the last group (1.26.1; it had an empty section of its own).
                    if g.id == groups.last?.id {
                        Text("Times are in your time zone (\(TimeZone.autoupdatingCurrent.localizedName(for: .generic, locale: .current) ?? TimeZone.autoupdatingCurrent.identifier)). Schedules from TVmaze (tvmaze.com, CC BY-SA) and AniList.")
                    }
                }
            }
        }
        .refreshable { await store.refresh(force: true, reason: "pull to refresh") }
    }
}

/// One tracked show: poster, name, the episode, its time and how long until
/// it airs; a button to the show's TVmaze or MyAnimeList page.
struct TrackedShowRow: View {
    let show: TrackedShow
    let now: Date
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 12) {
                    TrackPoster(url: show.poster, width: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(show.name).font(.body.weight(.semibold)).lineLimit(2)
                        Text(Self.line(show, now: now)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        if let e = show.headline(at: now), let d = e.airDate {
                            HStack(spacing: 6) {
                                Text(AiringFormat.when(d, day: e.day, now: now)).font(.footnote.weight(.medium)).lineLimit(1)
                                CountdownPill(date: d, day: e.day, now: now)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let link = show.pageLink {
                Link(destination: link.url) {
                    Image(systemName: "arrow.up.right.square").font(.title3).foregroundStyle(.secondary)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Open on \(link.title)")
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// "S1 · E5 · The Fall", or why there's no time.
    static func line(_ s: TrackedShow, now: Date) -> String {
        if let e = s.headline(at: now) { return [e.label, e.title].compactMap { $0 }.joined(separator: " · ") }
        if s.updated == nil { return "Looking for its schedule…" }
        if s.notFound == true, s.status == nil || s.status == .unknown { return s.anime == true ? "Not found on AniList or TVmaze" : "Not found on TVmaze" }
        switch s.status ?? .unknown {
        case .ended: return "Ended" + (s.lastAired.map { " · last episode \($0.label)" } ?? "")
        case .airing, .upcoming: return "Next episode not announced yet"
        case .unknown: return "No schedule yet"
        }
    }
}

/// "in 3 h", or "Out now" in the accent.
struct CountdownPill: View {
    let date: Date
    /// The network's date when the hour isn't known (AiringEpisode.day).
    var day: String? = nil
    let now: Date

    var body: some View {
        let out = date <= now
        Text(AiringFormat.countdown(to: date, day: day, now: now, calendar: .autoupdatingCurrent))
            .font(.caption.weight(.semibold).monospacedDigit()).lineLimit(1).fixedSize()
            .foregroundStyle(out ? Theme.onAccent : .primary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(out ? Theme.accent : Theme.fill, in: Capsule())
    }
}

struct TrackPoster: View {
    let url: String?
    var width: CGFloat

    var body: some View {
        Group {
            if let url, let u = URL(string: IMDbSource.sized(url, width: 300) ?? url) {
                CachedImage(url: u, maxPixel: 300) { $0.resizable().scaledToFill() } placeholder: { placeholder }
            } else {
                placeholder
            }
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var placeholder: some View {
        ZStack {
            Theme.cardHighlight
            Image(systemName: "tv").foregroundStyle(.secondary)
        }
    }
}

// MARK: - A show's page

/// One tracked show: its next episode in your time, what comes after, the
/// last one, its TVmaze or MyAnimeList page. Also what folio://track?id=
/// opens (a notification, the widget).
struct TrackingDetailView: View {
    let id: String
    @ObservedObject private var store = TrackingStore.shared
    /// The show as it was, so Track brings it back after Stop Tracking.
    @State private var last: TrackedShow?

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            if let s = store.show(id: id) ?? last {
                content(s, tracked: store.show(id: id) != nil, now: ctx.date)
            } else {
                ContentUnavailableView("Not tracked", systemImage: "bell.slash", description: Text("You're no longer tracking this show."))
            }
        }
        .brandListBackground()
        .navigationTitle(store.show(id: id)?.name ?? last?.name ?? "Tracking")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if last == nil { last = store.show(id: id) } }
        .onChange(of: store.show(id: id)) { _, s in if let s { last = s } }
    }

    private func content(_ s: TrackedShow, tracked: Bool, now: Date) -> some View {
        let headline = s.headline(at: now)
        let rest = s.upcoming(after: now).filter { $0 != headline }
        return List {
            Section {
                header(s, tracked: tracked)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }
            if let e = headline, let d = e.airDate {
                Section(d <= now ? "Out now" : "Next episode") { episode(e, now: now) }
            } else if s.status != .ended {
                // An ended show's chip says so, and its last episode is below.
                Section { Text(TrackedShowRow.line(s, now: now)).foregroundStyle(.secondary) }
            }
            if !rest.isEmpty {
                Section("Coming up") { ForEach(rest, id: \.self) { episode($0, now: now) } }
            }
            if let l = s.lastAired, l != headline {
                Section("Last aired") { episode(l, now: now) }
            }
            Section {
                if let link = s.pageLink {
                    Link(destination: link.url) { Label("Open on \(link.title)", systemImage: "arrow.up.right.square") }
                }
                if tracked {
                    Button(role: .destructive) { store.untrack(s.id) } label: { Label("Stop Tracking", systemImage: "bell.slash") }
                } else {
                    Button { store.track(s) } label: { Label("Track", systemImage: "bell") }
                }
            } footer: {
                Text(footer(s, now: now))
            }
        }
        .refreshable { await store.refresh(only: [s.id], reason: "pull to refresh") }
    }

    private func header(_ s: TrackedShow, tracked: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 14) {
            TrackPoster(url: s.poster, width: 96)
            VStack(alignment: .leading, spacing: 8) {
                Text(s.name).font(.system(.title2, design: .rounded, weight: .bold)).lineLimit(3)
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    chip(tracked ? (s.status ?? .unknown).title : "Not tracked", strong: tracked && s.status == .airing)
                    if let n = s.network { chip(n) }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func episode(_ e: AiringEpisode, now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.label).font(.body.weight(.semibold))
                if let t = e.title { Text(t).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 8)
            if let d = e.airDate {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(AiringFormat.when(d, day: e.day, now: now)).font(.subheadline.weight(.medium)).lineLimit(1)
                    if d > now || now.timeIntervalSince(d) < AiringClock.outNowWindow { CountdownPill(date: d, day: e.day, now: now) }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func chip(_ s: String, strong: Bool = false) -> some View {
        Text(s).font(.caption.weight(.semibold)).lineLimit(1).fixedSize()
            .foregroundStyle(strong ? Theme.onAccent : .primary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(strong ? Theme.accent : Theme.fill, in: Capsule())
    }

    private func footer(_ s: TrackedShow, now: Date) -> String {
        var parts: [String] = []
        if let u = s.updated {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .full
            parts.append("Schedule from \((s.source ?? .unknown).title), updated \(f.localizedString(for: u, relativeTo: now)).")
        }
        parts.append("Times are in your time zone.")
        return parts.joined(separator: " ")
    }
}

// MARK: - Home's row

/// An episode in Home's Airing row.
struct AiringSlot: Identifiable, Hashable {
    let show: TrackedShow
    let episode: AiringEpisode
    var id: String { "\(show.id)|\(episode.label)|\(episode.airDate?.timeIntervalSince1970 ?? 0)" }
}

/// Home's "Airing soon" row: the tracked shows' episodes out now or airing
/// in the next seven days, soonest first. Nothing at all (not even its
/// padding) when there are none.
///
/// `open` gets a show's id for a card, nil for "All". Without it, the page
/// opens as a sheet (TrackingPresenter): Home is a List, where a
/// NavigationLink would turn the whole row into one link.
struct AiringRow: View {
    var margin: CGFloat = 20
    var topPadding: CGFloat = 30
    var open: ((String?) -> Void)? = nil
    @ObservedObject private var store = TrackingStore.shared
    /// Moves every minute while the row is shown, so the countdowns do.
    @State private var tick = 0

    var body: some View {
        let _ = tick            // read, so the minute ticker redraws the row
        let now = Date()
        let slots = Self.slots(store.shows, now: now)
        if !slots.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Airing soon").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button { go(nil) } label: {
                        HStack(spacing: 2) { Text("All"); Image(systemName: "chevron.right").font(.caption.weight(.bold)) }
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("All tracked shows")
                }
                .padding(.horizontal, margin)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(slots) { slot in
                            Button { go(slot.show.id) } label: { AiringCard(slot: slot, now: now) }
                                .buttonStyle(PressStyle(scale: 0.97))
                        }
                    }
                    .padding(.horizontal, margin)
                }
                .scrollClipDisabled()
            }
            .padding(.top, topPadding)
            .task {
                while !Task.isCancelled {
                    // To the start of the next minute.
                    let s = 60 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
                    try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
                    tick &+= 1
                }
            }
        }
    }

    private func go(_ id: String?) {
        if let open { open(id) } else { TrackingPresenter.open(id) }
    }

    /// Each show's episode out now or next, and any more after it, within `days`.
    static func slots(_ shows: [TrackedShow], now: Date, days: Int = 7) -> [AiringSlot] {
        let end = now.addingTimeInterval(TimeInterval(days) * 86400)
        var out: [AiringSlot] = []
        for s in shows {
            guard let h = s.headline(at: now), let hd = h.airDate, hd < end else { continue }
            out.append(AiringSlot(show: s, episode: h))
            for e in s.upcoming(after: hd) where e.airDate! < end { out.append(AiringSlot(show: s, episode: e)) }
        }
        return Array(out.sorted { $0.episode.airDate! < $1.episode.airDate! }.prefix(20))
    }
}

private struct AiringCard: View {
    let slot: AiringSlot
    let now: Date

    var body: some View {
        HStack(spacing: 12) {
            TrackPoster(url: slot.show.poster, width: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(slot.show.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text([slot.episode.label, slot.episode.title].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 2)
                if let d = slot.episode.airDate {
                    Text(AiringFormat.when(d, day: slot.episode.day, now: now)).font(.caption.weight(.medium)).lineLimit(1)
                    CountdownPill(date: d, day: slot.episode.day, now: now)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 250, height: 101, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Settings

/// Settings' Tracking section: the tracked shows, and when the notifications come.
/// Tracked Shows' "Notify me" (1.26.1; on Settings' root until then, the
/// only row there that didn't open a page).
struct TrackingAlertsSection: View {
    @ObservedObject private var store = TrackingStore.shared
    @AppStorage(SettingsKey.airingAlerts) private var alerts = AiringAlerts.air.rawValue
    @State private var denied = false

    var body: some View {
        Section {
            Picker("Notify me", selection: $alerts) {
                ForEach(AiringAlerts.allCases) { Text($0.title).tag($0.rawValue) }
            }
            if denied, alerts != AiringAlerts.off.rawValue {
                Button("Allow Notifications in Settings") {
                    if let u = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(u) }
                }
            }
        } footer: {
            Text("When a tracked show's new episode comes out, in your time zone.")
        }
        .onChange(of: alerts) { _, v in
            if v != AiringAlerts.off.rawValue { AiringNotifications.askPermissionIfNeeded() }
            AiringNotifications.reschedule(store.shows)
            // Settings → Notifications' New episodes group is this picker (1.28.5: it showed the old one).
            NotifyPrefsModel.shared.changed()
        }
        .task {
            denied = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
        }
    }
}

// MARK: - Opening from a link

/// folio://track?id= (a notification, the widget) and Home's row without a
/// route of its own: the tracking page as a sheet over whatever is on screen.
@MainActor
enum TrackingPresenter {
    private static weak var shown: UIViewController?

    /// A show's page; nil: the Tracking list.
    static func open(_ id: String?) {
        Task { @MainActor in
            // Opened from a notification while Folio was closed: its window comes a moment later.
            var waited = 0
            while waited < 30, activeScene == nil {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            let scene = activeScene ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            guard let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first,
                  var top = window.rootViewController else {
                dlog("tracking", "no window to open the tracking page in")
                return
            }
            while let p = top.presentedViewController { top = p }
            dlog("tracking", "opening the tracking page\(id.map { " of \($0)" } ?? "")")
            if let shown, shown === top, let under = shown.presentingViewController {
                shown.dismiss(animated: false) { present(id, over: under) }
            } else {
                present(id, over: top)
            }
        }
    }

    private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
    }

    private static func present(_ id: String?, over vc: UIViewController) {
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.rootView = AnyView(TrackingSheet(id: id) { [weak host] in host?.dismiss(animated: true) }.tint(Theme.accent))
        vc.present(host, animated: true)
        shown = host
    }
}

private struct TrackingSheet: View {
    let id: String?
    let close: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if let id { TrackingDetailView(id: id) } else { TrackingView() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done", action: close).fontWeight(.semibold) }
            }
        }
        .toggleStyle(BrandSwitchStyle())
    }
}
