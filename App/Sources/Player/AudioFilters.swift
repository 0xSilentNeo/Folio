import Foundation

/// Night mode and dialogue boost (1.20.3, 2 Nov): one FFmpeg filter graph in
/// mpv's `af` list, under its own label, so the filters in your mpv.conf
/// stay where they are. Every filter string the app gives mpv is here.
///
/// The filters run on the decoded audio, before mpv mixes it down to the
/// output (`audio-channels`) and before the volume (the Boost setting), so
/// both keep working on top.
///
/// The engine's FFmpeg is built with a short list of audio filters: pan,
/// equalizer, volume and a few others, but not acompressor, alimiter,
/// dynaudnorm or dialoguenhance (checked in its libavfilter, 2 Nov). Which
/// of those it has is asked of mpv when the player starts (`probe`); the
/// better graph is used whenever it has them, and otherwise a graph made of
/// pan and equalizer only:
/// - night mode with a compressor: louder quiet parts, quieter loud ones;
///   without one: less bass and LFE (most of what's loud in a film) and
///   Dolby's own range compression, which Dolby Digital (Plus) tracks carry
///   and FFmpeg's decoder applies (`ad-lavc-ac3drc`, from the next file or
///   audio track).
/// - dialogue boost: the centre channel up and the others down on 5.1 and
///   7.1 (where dialogue is mixed into the centre); on stereo, FFmpeg's
///   dialogue enhancer if there, else the voice frequencies up.
enum AudioFilters {
    /// The label of the app's entry in mpv's `af` list.
    static let label = "folio-audio"

    /// Filters used when the engine has them (asked at start, `probe`).
    static let optional = ["acompressor", "alimiter", "dynaudnorm", "dialoguenhance"]

    /// What the probe found (nil until a player has started this run).
    @MainActor static var available: Set<String>?

    /// Asks which optional filters exist. `tryAdd` adds a bare filter name to
    /// mpv's list and removes it again: mpv refuses a name FFmpeg doesn't
    /// have when it parses the list, before anything plays. Run before a
    /// file is loaded, so no audio chain is rebuilt.
    static func probe(_ tryAdd: (String) -> Bool) -> Set<String> {
        Set(optional.filter(tryAdd))
    }

    /// One graph for both, or nil when both are off.
    struct Plan: Equatable {
        /// mpv's `af` entry value: "lavfi=[…]".
        var graph: String
        /// What it does, for the log and the player's menu.
        var night: String?
        var dialogue: String?
        /// Built for the playing track's channels (it fails on others).
        var layoutSpecific: Bool

        /// The whole `af add` argument.
        var entry: String { "@\(AudioFilters.label):\(graph)" }
    }

    // Strings in one place.
    static let compressor = "acompressor=threshold=-24dB:ratio=4:attack=10:release=300:makeup=8dB"
    static let limiter = "alimiter=limit=-1dB:level=0"
    static let leveller = "dynaudnorm=f=250:g=15:p=0.9:m=8"
    /// Peaking cut around 60 Hz, two octaves wide (≈ 30–120 Hz).
    static let bassCut = "equalizer=f=60:t=o:w=2:g=-6"
    /// Voice presence up, the low end that masks it down, a little headroom.
    static let voiceBand = "volume=0.8,equalizer=f=2500:t=o:w=1.5:g=5,equalizer=f=150:t=o:w=2:g=-3"
    /// dialoguenhance makes 3.0 (FL FR as given, FC the dialogue); folded back to stereo.
    static let enhancer = "dialoguenhance,pan=stereo|FL=0.8*FL+0.5*FC|FR=0.8*FR+0.5*FC"
    /// Centre +3 dB, the rest −3 dB: dialogue 6 dB above the rest, about the same loudness.
    static let centreGain = 1.41, otherGain = 0.71
    /// Night mode without a compressor, on surround: LFE −9 dB, surrounds −3 dB.
    static let nightLFEGain = 0.35, nightSurroundGain = 0.71

    /// Dolby range compression (FFmpeg's ac3/eac3 `drc_scale`): mpv's default is none.
    static func ac3drc(night: Bool) -> String { night ? "1" : "0" }

    static func plan(night: Bool, dialogue: Bool, layout: String?, available: Set<String>) -> Plan? {
        guard night || dialogue else { return nil }
        let ch = channels(layout)
        let surround = (ch?.count ?? 0) >= 3 && ch!.contains("FC") && ch!.contains("FL") && ch!.contains("FR")
        let hasCompressor = available.contains("acompressor")
        let hasLeveller = available.contains("dynaudnorm")
        var filters: [String] = []
        var nightText: String?, dialogueText: String?
        var specific = false

        // Channel gains first, on the track's own channels.
        let nightByChannels = night && !hasCompressor && !hasLeveller && surround && ch!.contains("LFE")
        if let ch, surround, dialogue || nightByChannels {
            filters.append(pan(ch, dialogue: dialogue, night: nightByChannels))
            specific = true
            if dialogue { dialogueText = "Centre channel louder" }
        } else if dialogue {
            if ch?.count == 2, available.contains("dialoguenhance") {
                filters.append(enhancer)
                specific = true
                dialogueText = "Dialogue enhancer"
            } else {
                filters.append(voiceBand)
                dialogueText = "Voice frequencies louder"
            }
        }

        if night {
            if hasCompressor {
                filters.append(available.contains("alimiter") ? compressor + "," + limiter : compressor)
                nightText = "Compressor"
            } else if hasLeveller {
                filters.append(leveller)
                nightText = "Leveller"
            } else {
                filters.append(bassCut)
                nightText = nightByChannels ? "Less bass and LFE · Dolby range control" : "Less bass · Dolby range control"
            }
        }
        return Plan(graph: "lavfi=[" + filters.joined(separator: ",") + "]", night: nightText, dialogue: dialogueText, layoutSpecific: specific)
    }

    /// pan keeping the layout: "pan=FL+FR+FC+LFE+SL+SR|FL=0.71*FL|…".
    static func pan(_ ch: [String], dialogue: Bool, night: Bool) -> String {
        let defs = ch.map { c -> String in
            var g = 1.0
            if dialogue { g *= c == "FC" ? centreGain : otherGain }
            if night {
                if c == "LFE" { g *= nightLFEGain }
                if ["BL", "BR", "SL", "SR", "BC"].contains(c) { g *= nightSurroundGain }
            }
            return abs(g - 1) < 0.005 ? "\(c)=\(c)" : String(format: "%@=%.2f*%@", c, g, c)
        }
        return "pan=" + ch.joined(separator: "+") + "|" + defs.joined(separator: "|")
    }

    /// FFmpeg channel names of mpv's layout ("5.1(side)", or the explicit
    /// "fl-fr-fc-lfe-sl-sr"); nil when unknown.
    static func channels(_ mpv: String?) -> [String]? {
        guard let s = mpv?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return nil }
        if let known = named[s] { return known }
        let parts = s.split(separator: "-").map { $0.uppercased() }
        guard parts.count >= 1, parts.allSatisfy(knownChannels.contains), Set(parts).count == parts.count else { return nil }
        return parts
    }

    private static let knownChannels: Set<String> = ["FL", "FR", "FC", "LFE", "BL", "BR", "FLC", "FRC", "BC", "SL", "SR",
                                                    "TC", "TFL", "TFC", "TFR", "TBL", "TBC", "TBR"]
    /// mpv's names (audio/chmap.c) of the layouts FFmpeg's decoders give.
    private static let named: [String: [String]] = [
        "mono": ["FC"], "1.0": ["FC"],
        "stereo": ["FL", "FR"], "2.0": ["FL", "FR"],
        "2.1": ["FL", "FR", "LFE"],
        "3.0": ["FL", "FR", "FC"],
        "3.1": ["FL", "FR", "FC", "LFE"],
        "4.0": ["FL", "FR", "FC", "BC"],
        "quad": ["FL", "FR", "BL", "BR"], "quad(side)": ["FL", "FR", "SL", "SR"],
        "4.1": ["FL", "FR", "FC", "LFE", "BC"],
        "5.0": ["FL", "FR", "FC", "BL", "BR"], "5.0(side)": ["FL", "FR", "FC", "SL", "SR"],
        "5.1": ["FL", "FR", "FC", "LFE", "BL", "BR"], "5.1(side)": ["FL", "FR", "FC", "LFE", "SL", "SR"],
        "6.0": ["FL", "FR", "FC", "BC", "SL", "SR"],
        "6.1": ["FL", "FR", "FC", "LFE", "BC", "SL", "SR"], "6.1(back)": ["FL", "FR", "FC", "LFE", "BL", "BR", "BC"],
        "7.0": ["FL", "FR", "FC", "BL", "BR", "SL", "SR"],
        "7.1": ["FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR"],
        "7.1(wide)": ["FL", "FR", "FC", "LFE", "BL", "BR", "FLC", "FRC"],
        "7.1(wide-side)": ["FL", "FR", "FC", "LFE", "FLC", "FRC", "SL", "SR"],
    ]
}
