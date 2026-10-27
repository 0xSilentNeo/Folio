import XCTest

/// 27 Oct report: "I think the page is still on screen but hidden after
/// backing for a few moments. That's what's causing the sudden play."
///
/// Touches here go through XCTest's event synthesizer with exact timing
/// (LabSynth.m): a tap can land 50 ms after a swipe back, which XCUITest's
/// own taps can't do. The app runs with `-lingerLab`, which logs every frame
/// whether a page that went back is still in the window, drawn, touchable,
/// and which page every touch went to.
///
/// Self-contained, so it runs on older builds too.
final class LingerUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

    private typealias Steps = [[Any]]

    /// One finger: steps in order, each at its own time (LabSynth.m).
    private func synth(_ steps: Steps) -> String {
        guard let cls = NSClassFromString("LabSynth") as? NSObject.Type else { return "synth: LabSynth missing" }
        let r = cls.perform(NSSelectorFromString("perform:"), with: [steps] as NSArray)
        return (r?.takeUnretainedValue() as? String) ?? "synth: no result"
    }

    private func tap(_ p: CGPoint, at t: Double) -> Steps {
        [["down", Double(p.x), Double(p.y), t], ["up", t + 0.05]]
    }

    private func swipe(_ a: CGPoint, _ b: CGPoint, at t: Double, over d: Double = 0.16) -> Steps {
        var s: Steps = [["down", Double(a.x), Double(a.y), t]]
        for k in 1...6 {
            let f = Double(k) / 6
            s.append(["move", Double(a.x + (b.x - a.x) * f), Double(a.y + (b.y - a.y) * f), t + d * f])
        }
        s.append(["up", t + d + 0.01])
        return s
    }

    func test51LingerLab() throws {
        Quiescence.skipWaiting()
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestLibrary", "-uiTestTwoTitles", "-heroView", "details", "-lingerLab"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let showLabel = app.staticTexts["Lab Show"].firstMatch, otherLabel = app.staticTexts["Lab Other"].firstMatch
        XCTAssertTrue(showLabel.waitForExistence(timeout: 25) && otherLabel.waitForExistence(timeout: 5), "library tiles not found")
        sleep(2)
        let W = app.frame.width, H = app.frame.height
        let tileA = CGPoint(x: showLabel.frame.midX, y: showLabel.frame.midY)
        let tileB = CGPoint(x: otherLabel.frame.midX, y: otherLabel.frame.midY)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        func xcTap(_ p: CGPoint) { origin.withOffset(CGVector(dx: p.x, dy: p.y)).tap() }

        // Where the page's controls sit once it's open.
        xcTap(tileA)
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 6), "title page did not open")
        sleep(2)
        let backF = app.buttons["Back"].frame
        let epF = app.buttons["ep:Lab Show S01E01.mp4"].frame
        let back = CGPoint(x: backF.midX, y: backF.midY)
        let row = CGPoint(x: epF.midX, y: epF.midY)
        print("LINGER layout: screen \(Int(W))×\(Int(H)), tile A \(tileA), tile B \(tileB), Back \(backF.integral), episode row \(epF.integral)")
        app.buttons["Back"].tap(); sleep(2)

        var played: [String] = [], dropped: [String] = []

                func reset() {
            if app.buttons["Close player"].exists { app.buttons["Close player"].tap(); sleep(3) }
            for _ in 0..<3 where app.buttons["Back"].exists { app.buttons["Back"].tap(); sleep(2) }
            sleep(1)
        }
        /// One scenario: one finger path per segment, each sent as its own
        /// record (a path can't put a finger down twice, and paths in one
        /// record lose their start times), with a wait after each. The app's
        /// [linger] lines have the times the touches actually arrived.
        func run(_ name: String, expect: String, _ segments: [(Steps, Double)]) {
            print("LINGER \(name): sent \(fmt.string(from: Date()))")
            var results: [String] = []
            for (steps, wait) in segments {
                results.append(synth(steps))
                if wait > 0 { usleep(UInt32(wait * 1_000_000)) }
            }
            sleep(3)
            let player = app.buttons["Close player"].exists
            // Lab Other has one episode: its page has no episode list.
            let page = app.buttons["Back"].exists, a = app.buttons["ep:Lab Show S01E01.mp4"].exists
            let now = player ? "PLAYER OPEN" : (!page ? "Home" : (a ? "Lab Show open" : "Lab Other open"))
            print("LINGER \(name): \(Set(results).joined(separator: ", ")) → \(now) (expected \(expect))")
            if player { played.append(name) } else if now != expect && expect != "any" { dropped.append(name) }
            reset()
        }
        func openA() -> Bool {
            xcTap(tileA)
            guard app.buttons["Back"].waitForExistence(timeout: 6) else { XCTFail("title page did not open"); return false }
            sleep(2); return true
        }

        let edgeFrom = CGPoint(x: 4, y: H * 0.55), edgeTo = CGPoint(x: W * 0.85, y: H * 0.55)
        let midFrom = CGPoint(x: W * 0.3, y: H * 0.55), midTo = CGPoint(x: W * 0.95, y: H * 0.55)
        let downFrom = CGPoint(x: W * 0.5, y: H * 0.3), downTo = CGPoint(x: W * 0.5, y: H * 0.85)
        let backs: [(String, (Double) -> Steps)] = [
            ("Back button", { t in self.tap(back, at: t) }),
            ("edge swipe", { t in self.swipe(edgeFrom, edgeTo, at: t) }),
            ("swipe right mid-page", { t in self.swipe(midFrom, midTo, at: t) }),
            ("swipe down", { t in self.swipe(downFrom, downTo, at: t) }),
        ]

        // A. Page fully open → back → tap the other title Δ s after the back gesture is sent.
        for (how, gesture) in backs {
            for d in [0.0, 0.1, 0.25, 0.5, 0.8] {
                guard openA() else { return }
                run("A \(how), Lab Other tapped +\(d) s", expect: "Lab Other open", [(gesture(0), d), (tap(tileB, at: 0), 0)])
            }
        }
        // B. Back → tap Home where the page's episode row was.
        for (how, gesture) in backs.prefix(2) {
            for d in [0.05, 0.3, 0.6, 0.9] {
                guard openA() else { return }
                run("B \(how), Home tapped where the episode row was +\(d) s", expect: "any", [(gesture(0), d), (tap(row, at: 0), 0)])
            }
        }
        // C. A swipe back that starts on the episode row.
        for i in 0..<3 {
            guard openA() else { return }
            run("C swipe back from the episode row #\(i)", expect: "any", [(swipe(CGPoint(x: epF.minX + 30, y: row.y), CGPoint(x: epF.minX + 300, y: row.y), at: 0), 0)])
        }
        // D. Open the title, a second tap where its episode row will be, Δ s later.
        for d in [0.1, 0.25, 0.4, 0.6, 0.9] {
            run("D Lab Show tapped, then the episode row's spot +\(d) s", expect: "any", [(tap(tileA, at: 0), d), (tap(row, at: 0), 0)])
        }
        // E. Switching fast: open, back Δ s later, other title 0.12 s after that.
        for (how, gesture) in backs.prefix(2) {
            for d in [0.25, 0.5, 0.8, 1.2] {
                run("E open, \(how) +\(d) s, Lab Other +0.12 s", expect: "Lab Other open", [(tap(tileA, at: 0), d), (gesture(0), 0.12), (tap(tileB, at: 0), 0)])
            }
        }
        print("LINGER played: \(played.count) \(played)")
        print("LINGER taps that didn't do what they should: \(dropped.count) \(dropped)")
        XCTAssertEqual(played.count, 0, "something played: \(played)")
    }
}
