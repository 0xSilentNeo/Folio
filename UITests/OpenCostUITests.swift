import XCTest

/// 28 Oct: "you introduced those delays and glitches … They were not there
/// when the video auto played during switching between titles fast" (1.16.1).
///
/// Your phone's log: from a tap on MobLand to its page starting to move,
/// 470–665 ms on 1.17.3/1.17.4; the page took ~96 ms to build on 1.16.1 and
/// ~280 ms since 1.17.0. This test does what your recordings do, in a library
/// laid out like yours (seeded by the perf-lab workflow: MobLand's 10
/// episodes, Classroom of the Elite's 12, Dragon Ball Super Beerus), so the
/// same steps can be profiled and recorded on 1.16.1, 1.17.4 and a fix.
///
/// Self-contained (XCTest's event synthesizer through LabSynth.m), so it
/// builds and runs against older app versions too. Every step prints an
/// `OPENCOST` line with the wall-clock time it was sent.
final class OpenCostUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
    private func mark(_ s: String) { print("OPENCOST \(fmt.string(from: Date())) \(s)") }

    private typealias Steps = [[Any]]

    private func synth(_ steps: Steps) {
        guard let cls = NSClassFromString("LabSynth") as? NSObject.Type else { print("OPENCOST synth missing"); return }
        _ = cls.perform(NSSelectorFromString("perform:"), with: [steps] as NSArray)
    }
    private func tap(_ p: CGPoint) -> Steps { [["down", Double(p.x), Double(p.y), 0.0], ["up", 0.06]] }
    private func swipe(_ a: CGPoint, _ b: CGPoint, over d: Double = 0.25) -> Steps {
        var s: Steps = [["down", Double(a.x), Double(a.y), 0.0]]
        for k in 1...8 {
            let f = Double(k) / 8
            s.append(["move", Double(a.x + (b.x - a.x) * f), Double(a.y + (b.y - a.y) * f), d * f])
        }
        s.append(["up", d + 0.01])
        return s
    }

    func test60OpenClose() throws {
        Quiescence.skipWaiting()
        let app = XCUIApplication()
        let style = ProcessInfo.processInfo.environment["LAB_TITLE_STYLE"] ?? "full"
        app.launchArguments = ["-uiTestLibrary", "-libraryView", "details", "-heroView", "details", "-tileArtwork", "poster",
                               "-librarySort", "size", "-librarySortAsc", "NO", "-metadataFetching", "YES",
                               "-titlePageStyle", style, "-appearance", "dark"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let mob = app.staticTexts["MobLand"].firstMatch
        let cls = app.staticTexts["Classroom of the Elite"].firstMatch
        let dbs = app.staticTexts["Dragon Ball Super Beerus"].firstMatch
        XCTAssertTrue(mob.waitForExistence(timeout: 30), "MobLand not on Home (library not seeded?)")
        sleep(3)
        let W = app.frame.width, H = app.frame.height
        func center(_ e: XCUIElement) -> CGPoint {
            // The row, not just its label: a point left of the label's middle,
            // on the row's picture side, like a thumb would land.
            CGPoint(x: e.frame.midX, y: e.frame.midY)
        }
        let pMob = center(mob), pCls = cls.exists ? center(cls) : pMob, pDbs = dbs.exists ? center(dbs) : pMob
        mark("layout screen \(Int(W))x\(Int(H)) MobLand \(pMob) Classroom \(pCls) Dragon Ball \(pDbs)")
        let edgeA = CGPoint(x: 4, y: H * 0.55), edgeB = CGPoint(x: W * 0.85, y: H * 0.55)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        func xcTap(_ p: CGPoint) { origin.withOffset(CGVector(dx: p.x, dy: p.y)).tap() }
        // Home's gear is covered whenever a page is open (the page's own
        // title would match "MobLand" too).
        let gear = app.buttons["Settings"].firstMatch
        func backToHome() {
            for _ in 0..<3 where !gear.isHittable {
                mark("not on Home yet: swipe back again")
                synth(swipe(edgeA, edgeB)); sleep(2)
            }
        }

        // Warm-up: metadata and pictures load once (your phone has them cached).
        for p in [pMob, pCls, pDbs, pMob] {
            xcTap(p); sleep(5)
            synth(swipe(edgeA, edgeB)); sleep(3)
            backToHome()
        }
        sleep(3)

        // 1. Open MobLand, let it open fully, swipe back.
        for i in 0..<4 {
            mark("A\(i) open MobLand")
            synth(tap(pMob)); sleep(2); usleep(500_000)
            mark("A\(i) swipe back (page open)")
            synth(swipe(edgeA, edgeB)); sleep(3)
            backToHome()
        }
        // 2. Open MobLand, swipe back 0.6 s in, while it's still opening.
        for i in 0..<4 {
            mark("B\(i) open MobLand")
            synth(tap(pMob)); usleep(600_000)
            mark("B\(i) swipe back (0.6 s in)")
            synth(swipe(edgeA, edgeB)); sleep(3)
            backToHome()
        }
        // 3. Switching titles fast, as in your 19:23 recording: open, back
        // ~0.9 s in, the next title ~0.35 s after letting go.
        for i in 0..<2 {
            for (name, p) in [("MobLand", pMob), ("Classroom", pCls), ("Dragon Ball", pDbs), ("MobLand", pMob)] {
                mark("C\(i) open \(name)")
                synth(tap(p)); usleep(900_000)
                mark("C\(i) swipe back \(name)")
                synth(swipe(edgeA, edgeB)); usleep(350_000)
            }
            sleep(3)
            backToHome()
        }
        // 4. Settings from the gear, and back.
        if gear.exists {
            let pg = CGPoint(x: gear.frame.midX, y: gear.frame.midY)
            for i in 0..<3 {
                mark("D\(i) open Settings")
                synth(tap(pg)); sleep(2)
                mark("D\(i) swipe back from Settings")
                synth(swipe(edgeA, edgeB)); sleep(3)
                backToHome()
            }
        }
        mark("done")
    }
}
