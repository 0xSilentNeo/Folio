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
        if CommandLine.arguments.contains("-avLab") { avLab(); return }
        if CommandLine.arguments.contains("-labDiscover") { IMDbSource.seedForLab(); return }
        if CommandLine.arguments.contains("-skipProbe") { skipProbe(); return }
        if CommandLine.arguments.contains("-parseProbe") { parseProbe(); return }
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

    /// A/V sync lab (real engine): play a clip with 5.1 audio, hold 2× for 4 s,
    /// release, then switch the renderer the way PiP does and back. Logs
    /// position, audio position and A/V offset every 0.2 s.
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
        ]
        for (t, name, f) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t) { dlog("av", "== \(name)"); f() } }
        var t0: Date?
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard let model = PlayerPresenter.current?.model, let c = model.client else { return }
                if t0 == nil { t0 = Date() }
                if Date().timeIntervalSince(t0!) > 38 { timer.invalidate(); dlog("av", "done"); return }
                c.query({ c in (c.double("time-pos"), c.double("audio-pts"), c.double("avsync"), c.double("speed"),
                                c.int("frame-drop-count"), c.int("decoder-frame-drop-count"), c.string("current-ao")) }) { r in
                    func f(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "-" }
                    dlog("av", "t=\(f(r.0)) a=\(f(r.1)) avsync=\(f(r.2)) speed=\(f(r.3)) drops=\(r.4 ?? -1)/\(r.5 ?? -1) ao=\(r.6 ?? "-")")
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
            let landscape = b.width > b.height && ui?.panelBar?.window != nil
            if landscape && count >= 6 { dlog("lab", "landscape steady; replay starts"); scheduleStress(after: 0.5) }
            else { waitForSteadyLandscape(count: landscape ? count + 1 : 0) }
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
