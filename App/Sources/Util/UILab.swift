import UIKit
import QuartzCore

/// Scripted run for the CI simulator recording (launch argument `-uiLab`):
/// plays the bundled clip and drives the player chrome on a timer so the
/// resulting video shows every panel opening, switching and closing.
@MainActor
enum UILab {
    static var enabled: Bool { CommandLine.arguments.contains("-uiLab") || uiTest }
    /// XCUITest run: just open the player with the bundled clip; the test taps.
    static var uiTest: Bool { CommandLine.arguments.contains("-uiTest") }
    /// XCUITest of the library: two episodes in Media, no autoplay.
    static var uiTestLibrary: Bool { CommandLine.arguments.contains("-uiTestLibrary") }
    static var keepControls: Bool { uiTest || uiTestLibrary }

    static func start() {
        if ShotsSeed.enabled { ShotsSeed.run(); return }
        if CommandLine.arguments.contains("-avLab") { avLab(); return }
        if CommandLine.arguments.contains("-labDiscover") { IMDbSource.seedForLab(); return }
        if CommandLine.arguments.contains("-skipProbe") { skipProbe(); return }
        if CommandLine.arguments.contains("-parseProbe") { parseProbe(); return }
        if CommandLine.arguments.contains("-nameProbe") { nameProbe(); return }
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("-imdbProbe=") }) { imdbProbe(ids: arg.dropFirst("-imdbProbe=".count).split(separator: ",").map(String.init)); return }
        if uiTestLibrary {
            UserDefaults.standard.set(false, forKey: SettingsKey.resumePlayback)
            if let src = Bundle.main.url(forResource: "lab", withExtension: "mp4", subdirectory: "lab") ?? Bundle.main.url(forResource: "lab", withExtension: "mp4") {
                let dir = MPVFiles.mediaDir
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for n in ["Lab Show S01E01.mp4", "Lab Show S01E02.mp4"] {
                    let d = dir.appendingPathComponent(n)
                    if !FileManager.default.fileExists(atPath: d.path) { try? FileManager.default.copyItem(at: src, to: d) }
                }
                LocalMediaStore.shared.refresh()
            }
            return
        }
        guard enabled else { return }
        if uiTest {
            UserDefaults.standard.set(false, forKey: SettingsKey.resumePlayback)
            guard let url = Bundle.main.url(forResource: "lab", withExtension: "mp4", subdirectory: "lab") ?? Bundle.main.url(forResource: "lab", withExtension: "mp4") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                var m = MediaItem(url: url.path, title: "Lab clip", source: .local); m.historyKey = "lab"
                PlayerPresenter.play(m)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { PlayerPresenter.current?.ui.showControls(autoHide: false) }
            if CommandLine.arguments.contains("-panelStress") { waitForSteadyLandscape(count: 0) }
            if CommandLine.arguments.contains("-toolbarProbe") { toolbarProbe() }
            if CommandLine.arguments.contains("-relayLab") { relayLab() }
            if CommandLine.arguments.contains("-pickLab") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 9) { dlog("lab", "pick lab: open Now Playing"); ui?.toggle(.nowPlaying) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { PlayerPresenter.current?.model.labShowPicker() }
            }
            return
        }
        dlog("lab", "UI lab run")
        UserDefaults.standard.set(false, forKey: SettingsKey.resumePlayback)
        UserDefaults.standard.set(true, forKey: SettingsKey.landscapeOnOpen)
        if CommandLine.arguments.contains("-labGL") { UserDefaults.standard.set("gl", forKey: SettingsKey.renderer) }
        guard let url = Bundle.main.url(forResource: "lab", withExtension: "mp4", subdirectory: "lab") ?? Bundle.main.url(forResource: "lab", withExtension: "mp4") else { dlog("lab/error", "lab.mp4 missing"); return }
        let steps: [(Double, String, () -> Void)] = [
            // Ground truth: can anything animate in this process at all?
            (0.5, "flags", {
                dlog("lab", "animationsEnabled=\(UIView.areAnimationsEnabled) reduceMotion=\(UIAccessibility.isReduceMotionEnabled) crossFade=\(UIAccessibility.prefersCrossFadeTransitions) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)")
                alphaTest()
            }),
            // Control experiment: a plain UIKit popover in the main window, before any video.
            (1.5, "test popover (main window)", { presentTestPopover() }),
            (3.0, "dismiss test popover", { testPopover?.dismiss(animated: true); testPopover = nil }),
            (4.0, "play", { var m = MediaItem(url: url.path, title: "Lab clip", source: .local); m.historyKey = "lab"; PlayerPresenter.play(m) }),
            (8.0, "controls", { ui?.showControls(autoHide: false) }),
            (9.0, "open tracks", { ui?.toggle(.tracks) }),
            (11.0, "close", { ui?.closePanel() }),
            (12.5, "open settings", { ui?.toggle(.settings) }),
            (14.5, "switch to now playing", { ui?.toggle(.nowPlaying) }),
            (16.5, "close", { ui?.closePanel() }),
            (17.5, "media info", { ui?.showInfo = true }),
            (19.0, "stats", { ui?.showInfo = false; ui?.showStats = true }),
            (20.5, "stats off", { ui?.showStats = false }),
            (21.0, "open now playing", { ui?.toggle(.nowPlaying) }),
            (23.0, "close", { ui?.closePanel() }),
            (24.0, "done", { dlog("lab", "done") }),
        ]
        for (t, name, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                dlog("lab", "t=\(t) \(name)")
                action()
            }
        }
    }

    private static var ui: PlayerUIState? { PlayerPresenter.current?.ui }

    /// `-toolbarProbe` (with `-uiTest`): in the player's own landscape layout,
    /// how wide the panel toolbar must be before iOS moves a button into its
    /// "⋯" overflow, and where the glass capsule sits inside the toolbar.
    /// Waits (polling each second, up to a minute) until the toolbar has been
    /// on screen in landscape for 3 s, then measures.
    static func toolbarProbe(attempt: Int = 0, settled: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let ready: Bool = {
                guard let w = ui?.panelBar?.window else { return false }
                return w.bounds.width > w.bounds.height
            }()
            guard ready, settled >= 3, let bar = ui?.panelBar as? UIToolbar, let host = bar.superview, let window = bar.window else {
                if attempt < 60 { toolbarProbe(attempt: attempt + 1, settled: ready ? settled + 1 : 0) }
                else { dlog("lab", "toolbar probe: no toolbar on screen in landscape") }
                return
            }
            dlog("lab", "toolbar probe: iOS \(UIDevice.current.systemVersion) bar=\(bar.frame) inWindow=\(bar.convert(bar.bounds, to: window)) window=\(window.bounds.size) safe=\(window.safeAreaInsets) barSafe=\(bar.safeAreaInsets) margins=\(bar.directionalLayoutMargins)")
            dumpTree(bar, in: bar, depth: 0)
            let widths: [CGFloat] = [120, 130, 140, 146, 150, 154, 158, 162, 166, 170, 174, 178, 182, 186, 190, 196, 202, 210, 220, 236]
            var i = 0
            func step() {
                guard i < widths.count else { dlog("lab", "toolbar probe: done"); return }
                let w = widths[i]; i += 1
                let (probe, items) = PanelToolbarView.makeBar { _ in }
                probe.frame = CGRect(x: bar.frame.maxX - w, y: bar.frame.minY - 70, width: w, height: 50)
                host.addSubview(probe)
                probe.setNeedsLayout(); probe.layoutIfNeeded()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let buttons = items.values.compactMap(\.customView)
                    let shown = buttons.filter { $0.window != nil && !$0.isHidden && $0.alpha > 0.01 }
                    let frames = shown.map { $0.convert($0.bounds, to: probe) }
                    let union = frames.dropFirst().reduce(frames.first ?? .zero) { $0.union($1) }
                    dlog("lab", "toolbar probe: width \(Int(w)) → \(shown.count)/3 buttons on screen, buttons span \(union.integral)")
                    if w == 176 || w == 236 { dumpTree(probe, in: probe, depth: 0) }
                    probe.removeFromSuperview()
                    step()
                }
            }
            step()
        }
    }

    private static func dumpTree(_ v: UIView, in root: UIView, depth: Int) {
        guard depth < 9 else { return }
        let f = v.convert(v.bounds, to: root).integral
        dlog("lab", "toolbar tree \(String(repeating: "  ", count: depth))\(type(of: v)) \(f) hidden=\(v.isHidden) alpha=\(String(format: "%.2f", v.alpha))")
        for sub in v.subviews { dumpTree(sub, in: root, depth: depth + 1) }
    }

    /// A/V sync lab (real engine): play a clip with 5.1 audio, hold 2× for 4 s,
    /// release, then switch the renderer the way PiP does and back. Logs
    /// position, audio position and A/V offset every 0.2 s.
    /// `-nameProbe`: file names from the Real-Debrid Attack on Titan folder
    /// (25 Oct report): the tag each row shows, then the metadata lookup for
    /// absolute episode numbers past season 1 (real network).
    static func nameProbe() {
        UserDefaults.standard.set(true, forKey: SettingsKey.metadataFetching)
        let names = ["[Anime Time] Attack on Titan - 01.mkv", "[Anime Time] Attack on Titan - 25.mkv", "[Anime Time] Attack on Titan - 26.mkv",
                     "[Anime Time] Attack on Titan - 38.mkv", "[Anime Time] Attack on Titan OAD - 05.mkv", "[Anime Time] Attack on Titan Junior High - 01.mkv",
                     "[Anime Time] Attack on Titan Movie 01 - Guren no Yumiya.mkv", "[Anime Time] Junior High - Creditless Ending.mkv",
                     "Classroom.of.the.Elite.S01E05.Hell.is.other.people.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR.mkv"]
        for n in names {
            let p = TitleParser.parse(n)
            dlog("lab", "name \(n) → title=\(p.title) s=\(p.season.map(String.init) ?? "-") e=\(p.episode.map(String.init) ?? "-") extra=\(p.extra ?? "-") part=\(p.part.map(String.init) ?? "-") sub=\(p.subtitle ?? "-") tag=\(TitleParser.tag(p) ?? "-") clean=\(TitleParser.clean(n))")
        }
        Task {
            // Past season 1 first (the point of the probe), then the side releases.
            for n in [names[2], names[3], names[4], names[6], names[0]] {
                let m = await MetadataService.shared.lookup(filename: n)
                let p = TitleParser.parse(n)
                dlog("lab", "meta \(n) → \(m?.name ?? "nil") [\(m?.id ?? "-")] tag=\(TitleParser.tag(p, season: m?.episodeSeason, episode: m?.episodeNumber) ?? "-") ep=\(m?.episodeTitle ?? "-")")
            }
            // Second pass once IMDb answers (its bot check slows the first requests in CI).
            await MetadataService.shared.clear()
            for n in [names[2], names[3]] {
                let m = await MetadataService.shared.lookup(filename: n)
                let p = TitleParser.parse(n)
                dlog("lab", "meta2 \(n) → tag=\(TitleParser.tag(p, season: m?.episodeSeason, episode: m?.episodeNumber) ?? "-") ep=\(m?.episodeTitle ?? "-")")
            }
        }
    }

    /// `-parseProbe`: the title-page parser on page data in IMDb's shapes —
    /// photo cast inside the main title object (next to countriesOfOrigin,
    /// where 1.13.0 stopped looking), photo-less "Stars", an episode's link back
    /// to the show carrying the episode's own original title, and the castV2
    /// shape. Then English episode titles from TVmaze (real network).
    static func parseProbe() {
        func page(_ next: String) -> String {
            #"<script type="application/ld+json">{"@type":"TVSeries","name":"Classroom of the Elite","actor":[{"name":"Star One"}]}</script>"#
            + #"<script id="__NEXT_DATA__" type="application/json">"# + next + "</script>"
        }
        let img = "https://m.media-amazon.com/images/M/MV5Babc._V1_.jpg"
        let shapeA = """
        {"props":{"pageProps":{
          "aboveTheFoldData":{"id":"tt7263328","titleText":{"text":"Classroom of the Elite"},"originalTitleText":{"text":"Yôkoso jitsuryoku shijô shugi no kyôshitsu e"},
            "titleType":{"id":"tvSeries"},"releaseYear":{"year":2017},"ratingsSummary":{"aggregateRating":7.7},"genres":{"genres":[{"text":"Animation"}]},
            "principalCredits":[{"category":{"id":"cast"},"credits":[{"name":{"id":"nm1","nameText":{"text":"Shoya Chiba"}}},{"name":{"id":"nm2","nameText":{"text":"Akari Kito"}}}]}]},
          "mainColumnData":{"id":"tt7263328","countriesOfOrigin":{"countries":[{"id":"JP"}]},
            "cast":{"edges":[
              {"node":{"name":{"id":"nm1","nameText":{"text":"Shoya Chiba"},"primaryImage":{"url":"\(img)"}},"characters":[{"name":"Kiyotaka Ayanokoji"}]}},
              {"node":{"name":{"id":"nm2","nameText":{"text":"Akari Kito"},"primaryImage":{"url":"\(img)"}},"characters":[{"name":"Suzune Horikita"}]}},
              {"node":{"name":{"id":"nm3","nameText":{"text":"Yurika Kubo"},"primaryImage":{"url":"\(img)"}},"characters":[{"name":"Kikyo Kushida"}]}}]},
            "episodes":{"episodes":{"edges":[{"node":{"id":"tt9000004","series":{"series":{"id":"tt7263328","originalTitleText":{"text":"Tanin ga Shinjitsu o Inpei Suru Koto ni Taishite"}}}}}]}}}
        }}}
        """
        let shapeB = """
        {"props":{"pageProps":{
          "aboveTheFoldData":{"id":"tt6262770","titleText":{"text":"Tenzing"},"originalTitleText":{"text":"Tenzing"},"releaseYear":{"year":2026},"ratingsSummary":{"aggregateRating":7.5}},
          "mainColumnData":{"id":"tt6262770","countriesOfOrigin":{"countries":[{"id":"AU"}]},
            "castV2":[{"grouping":{"text":"Cast"},"credits":[
              {"name":{"id":"nm10","nameText":{"text":"Tom Hiddleston"},"primaryImage":{"url":"\(img)"}},"creditedRoles":{"edges":[{"node":{"characters":{"edges":[{"node":{"name":"George Band"}}]}}}]}},
              {"name":{"id":"nm11","nameText":{"text":"Willem Dafoe"},"primaryImage":{"url":"\(img)"}},"creditedRoles":{"edges":[{"node":{"characters":{"edges":[{"node":{"name":"Eric Shipton"}}]}}}]}}]}],
            "writers":[{"credits":[{"name":{"id":"nm20","nameText":{"text":"A Writer"}}},{"name":{"id":"nm21","nameText":{"text":"B Writer"}}}]}]}
        }}}
        """
        for (label, next, id, hint) in [("shape A (cast.edges in mainColumnData)", shapeA, "tt7263328", "series"), ("shape B (castV2)", shapeB, "tt6262770", "movie")] {
            let m = IMDbSource.parseDetails(page: page(next), id: id, hint: hint)
            let cast = m?.credits ?? []
            dlog("lab", "parse \(label): name=\(m?.name ?? "nil") original=\(m?.originalName ?? "-") countries=\((m?.countries ?? []).joined(separator: ",")) cast=\(cast.count) photos=\(cast.filter { $0.photo != nil }.count) roles=\(cast.compactMap(\.character).joined(separator: " | "))")
        }
        Task {
            let t = await EpisodeTitles.titles(imdbID: "tt7263328", name: "Classroom of the Elite", year: "2017")
            dlog("lab", "tvmaze CotE: \(t.count) titles; S1E1=\(t["1:1"] ?? "nil"); S1E4=\(t["1:4"] ?? "nil")")
            let g = await EpisodeTitles.titles(imdbID: "tt0944947", name: "Game of Thrones", year: "2011")
            dlog("lab", "tvmaze GoT (by IMDb id): \(g.count) titles; S1E1=\(g["1:1"] ?? "nil")")
            dlog("lab", "parse probe done")
        }
    }

    /// `-skipProbe`: the Skip-pill naming and merging on real inputs (logged).
    static func skipProbe() {
        func show(_ label: String, _ segs: [SkipSegment], _ dur: Double, _ chs: [(String, Double)], anime: Bool) {
            let out = SkipService.tidy(segs, duration: dur, chapters: chs, anime: anime)
            dlog("lab", "skip \(label): " + out.map { "\($0.label) \(Int($0.start))-\(Int($0.end))" }.joined(separator: ", "))
        }
        let generic: [(String, Double)] = [("Chapter 1", 0), ("Chapter 2", 171.05), ("Chapter 3", 261.01), ("Chapter 4", 660.08), ("Chapter 5", 1346.05)]
        // Classroom of the Elite S1E1 and S1E4, IntroDB answers from the 24 Oct log.
        show("CotE e1", [SkipSegment(kind: .intro, start: 1345, end: 1435, source: "IntroDB"), SkipSegment(kind: .outro, start: 1345, end: 1438, source: "IntroDB")], 1440, generic, anime: true)
        show("CotE e4", [SkipSegment(kind: .intro, start: 171, end: 261, source: "IntroDB"), SkipSegment(kind: .outro, start: 1345, end: 1435, source: "IntroDB")], 1440, generic, anime: true)
        let named: [(String, Double)] = [("Prologue", 0), ("OP", 95), ("Part A", 185), ("Part B", 800), ("ED", 1330), ("Next Episode Preview", 1420)]
        let fromChapters = SkipService.segments(fromChapters: named, duration: 1440)
        show("named chapters", fromChapters, 1440, named, anime: true)
        show("live action", [SkipSegment(kind: .intro, start: 60, end: 120, source: "IntroDB"), SkipSegment(kind: .outro, start: 2500, end: 2600, source: "IntroDB")], 2640, [], anime: false)
        for t in ["Chapter 4", "Part B", "OP", "ED2", "Opening", "Ending Credits", "00:22:26.053", "Episode", "Recap"] {
            dlog("lab", "skip name \(t) → \(SkipService.meaningfulName(t) ?? "nil")")
        }
        dlog("lab", "skip probe done")
    }

    /// `-imdbProbe=tt…,tt…`: fetch each title page through the real source and
    /// log what the parser found (cast, photos, roles), to check the page shape.
    static func imdbProbe(ids: [String]) {
        Task {
            for (n, y, t) in [("Game of Thrones", "2011", "series"), ("Classroom of the Elite", "2017", "series"), ("Dune: Part Two", "2024", "movie")] {
                let w = await Wikipedia.article(name: n, year: y, type: t)
                dlog("lab", "wikipedia \(n) → \(w?.absoluteString ?? "nil") (search: \(Wikipedia.searchURL(name: n, year: y, type: t).absoluteString))")
            }
            for id in ids {
                let t0 = CACurrentMediaTime()
                let m = await IMDbSource.details(id: id, type: "series")
                let cast = m?.credits ?? []
                dlog("lab", String(format: "probe %@: %@ cast=%d photos=%d roles=%d in %.0f ms", id, m?.name ?? "nil", cast.count,
                                   cast.filter { $0.photo != nil }.count, cast.filter { $0.character != nil }.count, (CACurrentMediaTime() - t0) * 1000))
                for c in cast.prefix(4) { dlog("lab", "  \(c.name) as \(c.character ?? "-") \(c.photo ?? "no photo")") }
                if let m { dlog("lab", "  original=\(m.originalName ?? "-") rating=\(m.contentRating ?? "-") genres=\((m.genres ?? []).joined(separator: ","))") }
                let wiki = await Wikipedia.article(name: m?.name ?? id, year: m?.releaseInfo, type: "series")
                dlog("lab", "  wikipedia=\(wiki?.absoluteString ?? "nil")")
            }
            dlog("lab", "probe done")
        }
    }

    private static func avLab() {
        UserDefaults.standard.set(false, forKey: SettingsKey.resumePlayback)
        UserDefaults.standard.set(true, forKey: SettingsKey.holdToSpeed)
        guard let url = Bundle.main.url(forResource: "lab-av", withExtension: "mkv", subdirectory: "lab") ?? Bundle.main.url(forResource: "lab-av", withExtension: "mkv") else { dlog("lab/error", "lab-av.mkv missing"); return }
        let ao = CommandLine.arguments.first { $0.hasPrefix("-labAO=") } ?? "default"
        dlog("av", "A/V lab, ao \(ao)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            var m = MediaItem(url: url.path, title: "A/V lab", source: .local); m.historyKey = "avlab"
            PlayerPresenter.play(m)
        }
        let steps: [(Double, String, () -> Void)] = [
            (12, "hold 2x", { PlayerPresenter.current?.model.beginHoldSpeed() }),
            (16, "release", { PlayerPresenter.current?.model.endHoldSpeed() }),
            (22, "renderer → software (PiP path)", { PlayerPresenter.current?.model.labSwitchRenderer(software: true) }),
            (26, "renderer → main", { PlayerPresenter.current?.model.labSwitchRenderer(software: false) }),
            (29, "park video (PiP closed in background) then return", { PlayerPresenter.current?.model.labParkThenReturn() }),
            (33, "new hardware decoder (as after coming back while paused)", { PlayerPresenter.current?.model.labRenewDecoder() }),
        ]
        for (t, name, f) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t) { dlog("av", "== \(name)"); f() } }
        var t0: Date?
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard let model = PlayerPresenter.current?.model, let c = model.client else { return }
                if t0 == nil { t0 = Date() }
                if Date().timeIntervalSince(t0!) > 38 { timer.invalidate(); dlog("av", "done"); return }
                c.query({ c in (c.double("time-pos"), c.double("audio-pts"), c.double("avsync"), c.double("speed"),
                                c.int("frame-drop-count"), c.int("decoder-frame-drop-count"), c.string("current-ao"),
                                c.double("demuxer-cache-duration"), c.string("current-vo")) }) { r in
                    func f(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "-" }
                    dlog("av", "t=\(f(r.0)) a=\(f(r.1)) avsync=\(f(r.2)) speed=\(f(r.3)) drops=\(r.4 ?? -1)/\(r.5 ?? -1) ao=\(r.6 ?? "-") cache=\(f(r.7)) vo=\(r.8 ?? "-")")
                }
            }
        }
    }

    /// Replays the button taps from the 1.10.0 freeze log (23 Oct, 05:09:49–05:10:01)
    /// at their real intervals: each entry is a tap on that panel's button
    /// (tapping the open panel's own button closes it, as in the log).
    /// The replay must not overlap the launch rotation: start once the player
    /// has been in landscape for 3 s straight.
    private static func waitForSteadyLandscape(count: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let b = PlayerPresenter.current?.view.window?.bounds ?? .zero
            // The player in landscape. (Until 1.14 this also waited for the UIKit
            // panel toolbar, which iOS 26 no longer has: the replay never started.)
            let landscape = b.width > b.height && PlayerPresenter.current != nil
            if landscape && count >= 6 { dlog("lab", "landscape steady; replay starts"); scheduleStress(after: 0.5) }
            else { waitForSteadyLandscape(count: landscape ? count + 1 : 0) }
        }
    }

    /// `-relayLab` (with `-uiTest`): menus driven from inside the app, so the
    /// simulator test doesn't hold the taps back (XCUITest waits for the app to
    /// be idle before it taps, i.e. until a closing menu has finished). Opens a
    /// menu 0.3 s after a close started, and switches menus while one is open;
    /// the panel log shows when each one asked for opened.
    static func relayLab(count: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let b = PlayerPresenter.current?.view.window?.bounds ?? .zero
            let landscape = b.width > b.height && PlayerPresenter.current != nil
            guard landscape && count >= 6 else { relayLab(count: landscape ? count + 1 : 0); return }
            dlog("lab", "relay lab starts (relay \(PanelRelay.enabled ? "on" : "off"), anchor \(PanelRelay.anchorsToItem ? "item" : "rect"))")
            let steps: [(Double, String, () -> Void)] = [
                (0.0, "open tracks", { ui?.toggle(.tracks) }),
                (2.5, "close", { ui?.closePanel() }),
                (2.8, "settings 0.3 s after the close", { ui?.toggle(.settings) }),
                (5.5, "switch to now playing", { ui?.toggle(.nowPlaying) }),
                (8.0, "close", { ui?.closePanel() }),
                (8.4, "tracks 0.4 s after the close", { ui?.toggle(.tracks) }),
                (11.0, "switch to settings", { ui?.toggle(.settings) }),
                (13.5, "close", { ui?.closePanel() }),
                (13.6, "now playing 0.1 s after the close", { ui?.toggle(.nowPlaying) }),
                (16.0, "close", { ui?.closePanel() }),
                (18.0, "done", {}),
            ]
            for (t, name, action) in steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                    dlog("lab", "relay lab t=\(t) \(name)")
                    action()
                }
            }
        }
    }

    private static func scheduleStress(after start: Double) {
        let taps: [(Double, PlayerUIState.Panel)] = [
            (49.851, .settings), (50.684, .nowPlaying), (51.534, .nowPlaying), (52.617, .tracks), (53.201, .tracks),
            (53.873, .nowPlaying), (54.768, .nowPlaying), (55.384, .nowPlaying), (56.135, .settings), (56.901, .tracks),
            (57.468, .tracks), (57.985, .tracks), (58.810, .tracks), (59.426, .tracks), (59.843, .settings),
            (60.343, .nowPlaying), (61.060, .nowPlaying), (61.410, .settings),
        ]
        let t0 = taps[0].0
        for (t, kind) in taps {
            DispatchQueue.main.asyncAfter(deadline: .now() + start + (t - t0)) {
                dlog("lab", "stress tap \(kind.rawValue)")
                ui?.toggle(kind)
            }
        }
    }

    private static var testPopover: UIViewController?

    /// A plain UIView.animate alpha fade, traced: if this snaps, nothing in the process animates.
    private static func alphaTest() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.windows.first(where: { $0.isKeyWindow }) else { return }
        let v = UIView(frame: CGRect(x: 40, y: 200, width: 120, height: 120))
        v.backgroundColor = .systemTeal
        window.addSubview(v)
        UIView.animate(withDuration: 0.6) { v.alpha = 0.2; v.transform = CGAffineTransform(scaleX: 2, y: 2) } completion: { _ in v.removeFromSuperview() }
    }
    private static func presentTestPopover() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { dlog("lab/error", "no root"); return }
        let vc = UIViewController()
        vc.view.backgroundColor = UIColor.systemPink.withAlphaComponent(0.9)
        vc.preferredContentSize = CGSize(width: 240, height: 160)
        vc.modalPresentationStyle = .popover
        let anchor = UIView(frame: CGRect(x: root.view.bounds.midX - 20, y: root.view.bounds.midY + 120, width: 40, height: 40))
        anchor.backgroundColor = .systemYellow
        root.view.addSubview(anchor)
        vc.popoverPresentationController?.sourceView = anchor
        vc.popoverPresentationController?.sourceRect = anchor.bounds
        vc.popoverPresentationController?.permittedArrowDirections = [.down]
        testPopover = vc
        root.present(vc, animated: true)
        dlog("lab", "test popover presented from main window")
    }
}
