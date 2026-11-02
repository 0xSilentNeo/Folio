import XCTest
@testable import Folio

/// Night mode and dialogue boost graphs (1.20.3, 2 Nov). Every string was
/// also run through FFmpeg's own parser (ffmpeg -af) when written.
final class AudioFiltersTests: XCTestCase {
    /// What the engine has today: none of the optional filters.
    private let engine: Set<String> = []
    private let full: Set<String> = ["acompressor", "alimiter", "dynaudnorm", "dialoguenhance"]

    func testOffIsNoGraph() {
        XCTAssertNil(AudioFilters.plan(night: false, dialogue: false, layout: "5.1(side)", available: full))
    }

    func testDialogueOnSurroundRaisesTheCentre() {
        let p = AudioFilters.plan(night: false, dialogue: true, layout: "5.1(side)", available: engine)
        XCTAssertEqual(p?.graph, "lavfi=[pan=FL+FR+FC+LFE+SL+SR|FL=0.71*FL|FR=0.71*FR|FC=1.41*FC|LFE=0.71*LFE|SL=0.71*SL|SR=0.71*SR]")
        XCTAssertEqual(p?.layoutSpecific, true)
        XCTAssertEqual(p?.entry.hasPrefix("@folio-audio:lavfi=["), true)
        let seven = AudioFilters.plan(night: false, dialogue: true, layout: "7.1", available: engine)
        XCTAssertEqual(seven?.graph.contains("pan=FL+FR+FC+LFE+BL+BR+SL+SR|"), true)
        XCTAssertEqual(seven?.graph.contains("FC=1.41*FC"), true)
    }

    func testDialogueOnStereo() {
        let eq = AudioFilters.plan(night: false, dialogue: true, layout: "stereo", available: engine)
        XCTAssertEqual(eq?.graph, "lavfi=[" + AudioFilters.voiceBand + "]")
        XCTAssertEqual(eq?.layoutSpecific, false)
        let enh = AudioFilters.plan(night: false, dialogue: true, layout: "stereo", available: full)
        XCTAssertEqual(enh?.graph, "lavfi=[dialoguenhance,pan=stereo|FL=0.8*FL+0.5*FC|FR=0.8*FR+0.5*FC]")
        // Mono or an unknown layout: the voice band (works on any channels).
        XCTAssertEqual(AudioFilters.plan(night: false, dialogue: true, layout: "mono", available: full)?.graph, "lavfi=[" + AudioFilters.voiceBand + "]")
    }

    func testNightModeTiers() {
        XCTAssertEqual(AudioFilters.plan(night: true, dialogue: false, layout: "stereo", available: full)?.graph,
                       "lavfi=[acompressor=threshold=-24dB:ratio=4:attack=10:release=300:makeup=8dB,alimiter=limit=-1dB:level=0]")
        XCTAssertEqual(AudioFilters.plan(night: true, dialogue: false, layout: "stereo", available: ["acompressor"])?.graph,
                       "lavfi=[" + AudioFilters.compressor + "]")
        XCTAssertEqual(AudioFilters.plan(night: true, dialogue: false, layout: "stereo", available: ["dynaudnorm"])?.graph,
                       "lavfi=[dynaudnorm=f=250:g=15:p=0.9:m=8]")
        // Today's engine: the bass cut, and on surround LFE and surrounds down.
        XCTAssertEqual(AudioFilters.plan(night: true, dialogue: false, layout: "stereo", available: engine)?.graph,
                       "lavfi=[equalizer=f=60:t=o:w=2:g=-6]")
        XCTAssertEqual(AudioFilters.plan(night: true, dialogue: false, layout: "5.1(side)", available: engine)?.graph,
                       "lavfi=[pan=FL+FR+FC+LFE+SL+SR|FL=FL|FR=FR|FC=FC|LFE=0.35*LFE|SL=0.71*SL|SR=0.71*SR,equalizer=f=60:t=o:w=2:g=-6]")
    }

    func testBothOnSurroundIsOnePan() {
        let p = AudioFilters.plan(night: true, dialogue: true, layout: "5.1(side)", available: engine)
        XCTAssertEqual(p?.graph, "lavfi=[pan=FL+FR+FC+LFE+SL+SR|FL=0.71*FL|FR=0.71*FR|FC=1.41*FC|LFE=0.25*LFE|SL=0.50*SL|SR=0.50*SR,equalizer=f=60:t=o:w=2:g=-6]")
        XCTAssertEqual(p?.night, "Less bass and LFE · Dolby range control")
        XCTAssertEqual(p?.dialogue, "Centre channel louder")
        // With a compressor the channels only carry the dialogue boost.
        let c = AudioFilters.plan(night: true, dialogue: true, layout: "5.1(side)", available: full)
        XCTAssertEqual(c?.graph.hasSuffix("SR=0.71*SR," + AudioFilters.compressor + "," + AudioFilters.limiter + "]"), true)
    }

    func testChannelNames() {
        XCTAssertEqual(AudioFilters.channels("5.1(side)"), ["FL", "FR", "FC", "LFE", "SL", "SR"])
        XCTAssertEqual(AudioFilters.channels("fl-fr-fc-lfe-bl-br"), ["FL", "FR", "FC", "LFE", "BL", "BR"])
        XCTAssertEqual(AudioFilters.channels("stereo"), ["FL", "FR"])
        XCTAssertNil(AudioFilters.channels("na-na"))
        XCTAssertNil(AudioFilters.channels(nil))
        XCTAssertNil(AudioFilters.channels("weird"))
    }

    func testProbeKeepsOnlyWhatMPVTakes() {
        let found = AudioFilters.probe { $0 == "dynaudnorm" }
        XCTAssertEqual(found, ["dynaudnorm"])
        XCTAssertEqual(AudioFilters.ac3drc(night: true), "1")
        XCTAssertEqual(AudioFilters.ac3drc(night: false), "0")
    }

    func testSubtitleStylePresets() {
        let large = SubtitleStyle.large.options(scale: 1.2, position: 90, bold: true, box: false)
        let scale = large.first { $0.0 == "sub-scale" }.flatMap { Double($0.1) } ?? 0
        XCTAssertEqual(scale, 1.56, accuracy: 0.0001)
        XCTAssertEqual(large.first { $0.0 == "sub-pos" }?.1, "90")
        XCTAssertEqual(large.first { $0.0 == "sub-border-style" }?.1, "outline-and-shadow")
        // Your Background box setting adds the box to any style.
        XCTAssertEqual(SubtitleStyle.yellow.options(scale: 1, position: 100, bold: false, box: true).first { $0.0 == "sub-border-style" }?.1, "background-box")
        XCTAssertEqual(SubtitleStyle.yellow.options(scale: 1, position: 100, bold: false, box: false).first { $0.0 == "sub-color" }?.1, "#FFE600")
        XCTAssertEqual(SubtitleStyle.boxed.options(scale: 1, position: 100, bold: false, box: false).first { $0.0 == "sub-back-color" }?.1, "0.0/0.0/0.0/0.6")
    }
}
