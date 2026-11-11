import XCTest
@testable import Folio

/// 1.30.0: a show's intro found on the phone, from the sound two episodes share.
final class IntroDetect1300Tests: XCTestCase {
    static let rate = IntroFingerprint.sampleRate

    /// The same numbers on every run.
    struct Random {
        var state: UInt64
        mutating func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(state >> 40) / Float(1 << 24)
        }
    }

    /// "Music": three notes at a time, new ones every quarter second, over a little hiss.
    static func music(seconds: Double, seed: UInt64) -> [Float] {
        var r = Random(state: seed)
        let n = Int(seconds * Double(rate)), note = rate / 4
        var out = [Float](repeating: 0, count: n)
        var freqs: [Float] = [], phases: [Float] = [0, 0, 0]
        for i in 0..<n {
            if i % note == 0 { freqs = (0..<3).map { _ in 200 + r.next() * 2800 } }
            var v: Float = 0
            for k in 0..<3 {
                phases[k] += 2 * .pi * freqs[k] / Float(rate)
                if phases[k] > 2 * .pi { phases[k] -= 2 * .pi }
                v += sin(phases[k])
            }
            out[i] = v * 0.2 + (r.next() - 0.5) * 0.05
        }
        return out
    }

    static func noise(seconds: Double, seed: UInt64, level: Float = 0.3) -> [Float] {
        var r = Random(state: seed)
        return (0..<Int(seconds * Double(rate))).map { _ in (r.next() - 0.5) * 2 * level }
    }

    /// `theme` laid over `background` from `at` seconds, replacing it.
    static func episode(_ background: [Float], theme: [Float], at: Double) -> [Float] {
        var out = background
        let start = Int(at * Double(rate))
        out.replaceSubrange(start..<start + theme.count, with: theme)
        return out
    }

    func testTheSameThemeIsFoundInTwoEpisodesWithColdOpensOfDifferentLength() throws {
        let theme = Self.music(seconds: 40, seed: 1)
        let a = Self.episode(Self.noise(seconds: 300, seed: 2), theme: theme, at: 60)
        let b = Self.episode(Self.music(seconds: 300, seed: 3), theme: theme, at: 112)
        let m = try XCTUnwrap(IntroMatcher.match(IntroFingerprint.compute(samples: a), IntroFingerprint.compute(samples: b)))
        XCTAssertEqual(m.startA, 60, accuracy: 1)
        XCTAssertEqual(m.endA, 100, accuracy: 1)
        XCTAssertEqual(m.startB, 112, accuracy: 1)
        XCTAssertEqual(m.endB, 152, accuracy: 1)
        XCTAssertLessThan(m.errorRate, 0.1)
    }

    /// Two episodes never line up to the frame, a second encode is not as
    /// loud, and its sound isn't bit for bit the same.
    func testFoundWhenShiftedByPartOfAFrameQuieterAndNoisier() throws {
        let theme = Self.music(seconds: 60, seed: 4)
        let hiss = Self.noise(seconds: 60, seed: 9, level: 0.02)
        let other = zip(theme, hiss).map { $0 * 0.5 + $1 }
        let a = Self.episode(Self.music(seconds: 240, seed: 5), theme: theme, at: 0)
        let b = Self.episode(Self.music(seconds: 240, seed: 6), theme: other, at: 31.06)
        let m = try XCTUnwrap(IntroMatcher.match(IntroFingerprint.compute(samples: a), IntroFingerprint.compute(samples: b)))
        XCTAssertEqual(m.startA, 0, "an intro that opens the file starts at 0")
        XCTAssertEqual(m.endA, 60, accuracy: 1)
        XCTAssertEqual(m.startB, 31.06, accuracy: 1)
        XCTAssertEqual(m.endB, 91.06, accuracy: 1)
    }

    func testUnrelatedSoundHasNoIntro() {
        let a = IntroFingerprint.compute(samples: Self.music(seconds: 300, seed: 7))
        let b = IntroFingerprint.compute(samples: Self.music(seconds: 300, seed: 8))
        XCTAssertNil(IntroMatcher.match(a, b))
        let c = IntroFingerprint.compute(samples: Self.noise(seconds: 300, seed: 10))
        let d = IntroFingerprint.compute(samples: Self.noise(seconds: 300, seed: 11))
        XCTAssertNil(IntroMatcher.match(c, d))
        XCTAssertNil(IntroMatcher.match(a, c))
    }

    /// A studio logo both episodes share is not an intro; nor is all of the
    /// file (two copies of one episode); nor is silence.
    func testTooShortTooLongAndSilenceAreNotIntros() {
        let sting = Self.music(seconds: 8, seed: 12)
        let a = IntroFingerprint.compute(samples: Self.episode(Self.noise(seconds: 200, seed: 13), theme: sting, at: 5))
        let b = IntroFingerprint.compute(samples: Self.episode(Self.noise(seconds: 200, seed: 14), theme: sting, at: 5))
        XCTAssertNil(IntroMatcher.match(a, b), "8 s")
        let whole = IntroFingerprint.compute(samples: Self.music(seconds: 200, seed: 15))
        XCTAssertNil(IntroMatcher.match(whole, whole), "200 s")
        let silent = IntroFingerprint.compute(samples: [Float](repeating: 0, count: 200 * Self.rate))
        XCTAssertTrue(silent.allSatisfy { $0 == 0 })
        XCTAssertNil(IntroMatcher.match(silent, silent), "silence")
    }

    /// The intro lies between two silences both episodes have: only the intro counts.
    func testSilenceAroundTheIntroIsNotPartOfIt() throws {
        let theme = [Float](repeating: 0, count: 10 * Self.rate) + Self.music(seconds: 30, seed: 16) + [Float](repeating: 0, count: 10 * Self.rate)
        let a = Self.episode(Self.noise(seconds: 200, seed: 17), theme: theme, at: 20)
        let b = Self.episode(Self.noise(seconds: 200, seed: 18), theme: theme, at: 20)
        let m = try XCTUnwrap(IntroMatcher.match(IntroFingerprint.compute(samples: a), IntroFingerprint.compute(samples: b)))
        XCTAssertEqual(m.startA, 30, accuracy: 1)
        XCTAssertEqual(m.endA, 60, accuracy: 1)
    }

    func testTenMinutesAreAFewKilobytesAndCompareQuickly() {
        let a = IntroFingerprint.compute(samples: Self.noise(seconds: 600, seed: 19))
        XCTAssertEqual(a.count, 4796)
        XCTAssertLessThan(IntroFinder.data(a).count, 10_000)
        XCTAssertEqual(IntroFinder.values(IntroFinder.data(a)), a)
        let b = IntroFingerprint.compute(samples: Self.noise(seconds: 600, seed: 20))
        let t = Date()
        XCTAssertNil(IntroMatcher.match(a, b))
        XCTAssertLessThan(Date().timeIntervalSince(t), 5, "an unoptimised build on a Mac; the phone runs an optimised one")
    }

    func testTheNeighbourIsTheNextEpisodeThenTheOneBefore() {
        let files = ["Lab.Show.S01E01.1080p.mkv", "Lab.Show.S01E02.1080p.mkv", "Lab.Show.S01E03.1080p.mkv", "Lab.Show.S01E05.1080p.mkv",
                     "Lab.Show.S02E03.1080p.mkv", "Other.Show.S01E03.mkv", "Lab.Show.S01E03.srt", "notes.txt"]
        XCTAssertEqual(IntroNeighbours.of("Lab.Show.S01E02.1080p.mkv", among: files), ["Lab.Show.S01E03.1080p.mkv", "Lab.Show.S01E01.1080p.mkv"])
        XCTAssertEqual(IntroNeighbours.of("Lab.Show.S01E03.1080p.mkv", among: files), ["Lab.Show.S01E05.1080p.mkv", "Lab.Show.S01E02.1080p.mkv"])
        XCTAssertEqual(IntroNeighbours.of("Lab.Show.S01E05.1080p.mkv", among: files), ["Lab.Show.S01E03.1080p.mkv"])
        XCTAssertEqual(IntroNeighbours.of("Lab.Show.S02E03.1080p.mkv", among: files), [], "another season has another intro")
        XCTAssertEqual(IntroNeighbours.of("Lab.Film.2019.1080p.mkv", among: files + ["Lab.Film.2019.1080p.mkv"]), [], "a film")
    }

    func testOnlyEpisodesInTheAppsOwnFoldersAreLookedAt() {
        let docs = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/X/Documents")
        XCTAssertTrue(IntroFinder.eligible(docs.appendingPathComponent("Media/Lab Show/Lab.Show.S01E02.mkv"), documents: docs))
        XCTAssertFalse(IntroFinder.eligible(docs.appendingPathComponent("Media/Lab.Film.2019.mkv"), documents: docs), "a film")
        XCTAssertFalse(IntroFinder.eligible(URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/Lab.Show.S01E02.mkv"), documents: docs), "outside the app")
        XCTAssertFalse(IntroFinder.eligible(URL(string: "https://example.com/Lab.Show.S01E02.mkv")!, documents: docs), "a stream")
    }

    func testTheSettingIsOnByDefault() {
        SettingsKey.registerDefaults()
        XCTAssertNotNil(UserDefaults.standard.object(forKey: SettingsKey.skipFindOnDevice))
    }

    // MARK: The real decode

    /// A 16-bit mono WAV at the analysis rate.
    static func wav(_ samples: [Float]) -> Data {
        var d = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(Data("RIFF".utf8)); u32(36 + samples.count * 2); d.append(Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(samples.count * 2)
        let pcm = samples.map { Int16(max(-1, min(1, $0)) * 32767).littleEndian }
        pcm.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }

    func testAWAVIsReadBack() throws {
        let s = Self.music(seconds: 2, seed: 21)
        let back = try XCTUnwrap(IntroAudio.samples(fromWAV: Self.wav(s)))
        XCTAssertEqual(back.count, s.count)
        XCTAssertEqual(Float(back[1234]) / 32767, s[1234], accuracy: 0.001)
        XCTAssertNil(IntroAudio.samples(fromWAV: Data(repeating: 0, count: 100)))
    }

    /// The engine really writes sound to a file (`ao=pcm`): the bundled lab
    /// clip (40 s, 5.1 AC-3 at 48 kHz) comes out as mono 8 kHz, cut at `end`.
    func testTheEngineDecodesAFilesSoundToPCM() throws {
        let clip = try XCTUnwrap(Bundle.main.url(forResource: "lab-av", withExtension: "mkv", subdirectory: "lab")
                                 ?? Bundle.main.url(forResource: "lab-av", withExtension: "mkv"))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("intro-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertTrue(IntroAudio.decode(clip.path, to: out.path, seconds: 600, cancelled: { false }))
        let pcm = try XCTUnwrap(IntroAudio.samples(fromWAV: try Data(contentsOf: out)))
        XCTAssertEqual(Double(pcm.count) / Double(Self.rate), 40, accuracy: 1, "all 40 s, at 8 kHz mono")
        let loud = pcm.filter { abs(Int($0)) > 300 }.count
        print("lab clip: \(pcm.count) samples, \(loud) above -40 dB, peak \(pcm.map { abs(Int($0)) }.max() ?? 0)")

        let short = try XCTUnwrap(IntroAudio.fingerprintNow(of: clip, seconds: 10, cancelled: { false }))
        XCTAssertEqual(short.seconds, 10, accuracy: 0.5, "cut at `end`")
        XCTAssertEqual(short.fingerprint.count, Int((short.seconds * 8000 - 4096) / 1000) + 1)

        XCTAssertNil(IntroAudio.fingerprintNow(of: clip, seconds: 600, cancelled: { true }), "cancelled")
        let left = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("intro-") && $0.hasSuffix(".wav") && $0 != out.lastPathComponent }
        XCTAssertEqual(left, [], "the decoded sound is deleted")
    }

    /// The whole way: two episode files in a folder, decoded by the engine,
    /// compared, remembered; the neighbour then has its intro with no work.
    func testTwoEpisodeFilesGiveBothTheirIntro() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("intro-lab-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let theme = Self.music(seconds: 35, seed: 22)
        let e1 = dir.appendingPathComponent("Lab.Show.S01E01.wav"), e2 = dir.appendingPathComponent("Lab.Show.S01E02.wav")
        try Self.wav(Self.episode(Self.music(seconds: 150, seed: 23), theme: theme, at: 20)).write(to: e1)
        try Self.wav(Self.episode(Self.music(seconds: 150, seed: 24), theme: theme, at: 48)).write(to: e2)
        // Finished files: nothing has been written to them for a while.
        for u in [e1, e2] { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: u.path) }
        let cache = dir.appendingPathComponent("cache/intros.json")
        let finder = IntroFinder(file: cache)
        let none = await finder.known(for: e1)
        XCTAssertNil(none)
        let worth = await finder.worthTrying(e1)
        XCTAssertTrue(worth)
        let found = await finder.find(for: e1)
        let intro = try XCTUnwrap(found)
        XCTAssertEqual(intro.start, 20, accuracy: 1)
        XCTAssertEqual(intro.end, 55, accuracy: 1)
        // A new finder reads what the first one saved.
        let later = IntroFinder(file: cache)
        let other = await later.known(for: e2)
        XCTAssertEqual(try XCTUnwrap(other).start, 48, accuracy: 1)
        let again = await later.worthTrying(e2)
        XCTAssertFalse(again, "nothing left to analyse")
    }
}
