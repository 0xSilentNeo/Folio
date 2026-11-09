import AVFoundation

/// Where the sound goes, and what Media Info says about it (1.27.0). A 5.1
/// TrueHD track showed "Output stereo" with no reason (9 Nov report): it
/// played on the iPhone's speaker, which takes 2 channels, so mpv mixed it
/// down, as it should. The panel now names the route and says why.
struct AudioRoute: Equatable {
    /// "iPhone speaker", "AirPods Pro", "HDMI".
    var name: String
    /// The most channels the route takes (iOS's maximumOutputNumberOfChannels).
    var maxChannels: Int
    /// Spatial Audio on for the route (AirPods, Beats).
    var spatial: Bool

    static func current() -> AudioRoute {
        let s = AVAudioSession.sharedInstance()
        let out = s.currentRoute.outputs.first
        return AudioRoute(name: out.map(name(of:)) ?? "No output",
                          maxChannels: s.maximumOutputNumberOfChannels,
                          spatial: out?.isSpatialAudioEnabled ?? false)
    }

    private static func name(of port: AVAudioSessionPortDescription) -> String {
        switch port.portType {
        case .builtInSpeaker: "iPhone speaker"
        case .builtInReceiver: "iPhone earpiece"
        case .headphones: "Headphones"
        case .HDMI: "HDMI"
        default: port.portName
        }
    }

    /// For the log: "iPhone speaker, 2 ch max, spatial off".
    var describe: String { "\(name), \(maxChannels) ch max, spatial \(spatial ? "on" : "off")" }

    /// Channels in an mpv layout name: "mono" 1, "stereo" 2, "5.1(side)" 6,
    /// "7.1" 8; nil for one it doesn't know.
    static func channels(in layout: String) -> Int? {
        let l = layout.lowercased()
        if l.hasPrefix("mono") { return 1 }
        if l.hasPrefix("stereo") { return 2 }
        let numbers = l.prefix { $0.isNumber || $0 == "." }.split(separator: ".").compactMap { Int($0) }
        return numbers.isEmpty ? nil : numbers.reduce(0, +)
    }

    /// "Stereo · iPhone speaker".
    func output(layout: String) -> String {
        let shown = AudioFormat.channelLayout(channels: layout, count: Self.channels(in: layout)) ?? layout
        return "\(shown) · \(name)"
    }

    /// Why the track plays with fewer channels than it has, or nil when it
    /// doesn't: "5.1 mixed down to stereo: the iPhone speaker takes 2
    /// channels. AirPlay or HDMI to a surround system gets all 6."
    func mixdown(track: Int?, output layout: String, surroundOn: Bool) -> String? {
        guard let track, let out = Self.channels(in: layout), track > out else { return nil }
        let from = AudioFormat.channelLayout(channels: nil, count: track) ?? "\(track) ch"
        // Mid-sentence: "stereo", "mono"; "5.1" as it is.
        let to = (AudioFormat.channelLayout(channels: layout, count: out) ?? layout).lowercased()
        if !surroundOn { return "\(from) mixed down to \(to): Spatial Audio is off in Audio & Subtitles." }
        let takes = maxChannels == 1 ? "1 channel" : "\(maxChannels) channels"
        return "\(from) mixed down to \(to): the \(name) takes \(takes). AirPlay or HDMI to a surround system gets all \(track)."
    }
}
