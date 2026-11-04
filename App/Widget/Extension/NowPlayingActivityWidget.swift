import ActivityKit
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

/// The Live Activity for what's playing (1.22.0; the app's
/// NowPlayingActivity runs it). Redrawn in 1.22.1 as liquid glass (the
/// 4 Nov report found the first one a plain bar with plain buttons): a dark
/// see-through pane lit from behind by the picture's own colour, the
/// picture with a glass rim, a bar in a glass tube, and big round glass
/// buttons for 10 s back, play/pause and 10 s forward (NowPlayingIntents).
/// In the compact Dynamic Island a ring around the picture fills as the
/// video plays. Bar, ring and times move by themselves from the last
/// position (timer views): the app updates it only on a pause, a play or a seek.
struct NowPlayingActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingActivityAttributes.self) { context in
            NowPlayingLockScreen(state: context.state)
                .activityBackgroundTint(LiquidGlass.backdrop)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            let tint = LiquidGlass.tint(s.tint)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityArtwork(name: s.artwork, size: 48, tint: tint)
                        .padding(.leading, 6).padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    GlassButton(intent: NowPlayingToggleIntent(), symbol: s.paused ? "play.fill" : "pause.fill",
                                size: 48, pearl: true, tint: tint, label: s.paused ? "Play" : "Pause")
                        .padding(.trailing, 6).padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let line = s.subtitle {
                            Text(line).font(.caption).foregroundStyle(LiquidGlass.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    NowPlayingScrubRow(state: s, tint: tint, button: 36)
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                }
            } compactLeading: {
                // The picture in a ring that fills as it plays.
                PlaybackRing(state: s, tint: tint, size: 24, line: 2.4)
            } compactTrailing: {
                // Words, not a pause glyph: beside the picture's placeholder that
                // read as a play button and a pause button side by side (4 Nov).
                if s.paused {
                    Text("Paused").font(.system(.caption, design: .rounded).weight(.semibold)).foregroundStyle(tint)
                } else {
                    NowPlayingTimeLeft(state: s)
                        .font(.system(.caption, design: .rounded).weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: LiquidGlass.clockWidth(s.timerRange) + 8, alignment: .trailing)
                }
            } minimal: {
                PlaybackRing(state: s, tint: tint, size: 24, line: 2.4)
            }
            .keylineTint(tint)
        }
    }
}

/// The Lock Screen's pane.
private struct NowPlayingLockScreen: View {
    let state: NowPlayingActivityAttributes.ContentState

    var body: some View {
        let tint = LiquidGlass.tint(state.tint)
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                ActivityArtwork(name: state.artwork, size: 58, tint: tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.title).font(.headline).lineLimit(1)
                    if let line = state.subtitle {
                        Text(line).font(.caption).foregroundStyle(LiquidGlass.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                GlassButton(intent: NowPlayingToggleIntent(), symbol: state.paused ? "play.fill" : "pause.fill",
                            size: 54, pearl: true, tint: tint, label: state.paused ? "Play" : "Pause")
            }
            NowPlayingScrubRow(state: state, tint: tint, button: 40)
        }
        .padding(16)
        .background(alignment: .topLeading) { Glow(color: tint) }
        .foregroundStyle(.white)
    }
}

/// 10 s back, the bar with the time played and left, 10 s forward. The
/// buttons are LiveActivityIntents that run in the app, which tells the player.
private struct NowPlayingScrubRow: View {
    let state: NowPlayingActivityAttributes.ContentState
    let tint: Color
    let button: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            GlassButton(intent: NowPlayingBackIntent(), symbol: "gobackward.10", size: button, tint: tint, label: "Back 10 seconds")
            VStack(spacing: 5) {
                LiquidBar(range: state.timerRange, progress: state.progress(at: state.at), tint: tint)
                HStack {
                    NowPlayingElapsed(state: state)
                    Spacer(minLength: 4)
                    NowPlayingTimeLeft(state: state)
                }
                .font(.system(.caption2, design: .rounded).weight(.medium).monospacedDigit())
                .foregroundStyle(LiquidGlass.secondary)
            }
            GlassButton(intent: NowPlayingForwardIntent(), symbol: "goforward.10", size: button, tint: tint, label: "Forward 10 seconds")
        }
    }
}

/// A round glass button; `pearl`: the main one, milky white with the
/// picture's colour glowing around it.
private struct GlassButton<I: LiveActivityIntent>: View {
    let intent: I
    let symbol: String
    let size: CGFloat
    var pearl = false
    let tint: Color
    let label: String

    var body: some View {
        Button(intent: intent) {
            Image(systemName: symbol)
                .font(.system(size: size * (pearl ? 0.38 : 0.36), weight: .bold))
                .foregroundStyle(pearl ? Color.black.opacity(0.85) : .white)
                .frame(width: size, height: size)
                .background {
                    if pearl {
                        Circle()
                            .fill(LinearGradient(colors: [.white, .white.opacity(0.78)], startPoint: .top, endPoint: .bottom))
                            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 0.8))
                            .shadow(color: tint.opacity(0.75), radius: 10)
                    } else {
                        GlassFill(shape: Circle())
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The picture in the compact Dynamic Island, with the playback ring around it.
private struct PlaybackRing: View {
    let state: NowPlayingActivityAttributes.ContentState
    let tint: Color
    let size: CGFloat
    let line: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(LiquidGlass.track, lineWidth: line)
            if let range = state.timerRange {
                ProgressView(timerInterval: range, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    .progressViewStyle(.circular)
                    .tint(tint)
            } else {
                Circle().trim(from: 0, to: max(0.02, state.progress(at: state.at)))
                    .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            ActivityArtwork(name: state.artwork, size: size - line * 2 - 3, tint: tint, round: true)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(state.paused ? "Paused" : "Playing")
    }
}

/// "12:34" played: counts up while playing, still while paused.
private struct NowPlayingElapsed: View {
    let state: NowPlayingActivityAttributes.ContentState

    var body: some View {
        if let range = state.timerRange {
            Text(timerInterval: range, countsDown: false).lineLimit(1)
        } else {
            Text(ActivityFormat.clock(state.position(at: state.at))).lineLimit(1)
        }
    }
}

/// "−12:34": counts down while playing, still while paused.
private struct NowPlayingTimeLeft: View {
    let state: NowPlayingActivityAttributes.ContentState

    var body: some View {
        if let range = state.timerRange {
            (Text("−") + Text(timerInterval: range, countsDown: true))
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
        } else if state.duration > 0 {
            Text("−" + ActivityFormat.clock(state.timeLeft(at: state.at))).lineLimit(1)
        }
    }
}

// MARK: - Liquid glass (both activities)

/// The activities' look (1.22.1). The Dynamic Island is always black, so
/// the Lock Screen gets a dark pane too, see-through over the wallpaper:
/// one look in both places, light mode or dark.
enum LiquidGlass {
    static let backdrop = Color.black.opacity(0.42)
    static let secondary = Color.white.opacity(0.66)
    static let track = Color.white.opacity(0.16)
    /// The downloads activity's colour: water.
    static let aqua = Color(red: 0.42, green: 0.86, blue: 0.97)
    /// What's playing without a picture (or the App Group): warm light.
    static let warm = Color(red: 0.96, green: 0.84, blue: 0.66)

    /// Width for a compact timer counting `range`: an hour or more needs "1:02:03".
    static func clockWidth(_ range: ClosedRange<Date>?) -> CGFloat {
        guard let range else { return 44 }
        return range.upperBound.timeIntervalSince(range.lowerBound) >= 3600 ? 60 : 44
    }

    /// The picture's colour (NowPlayingActivity, "RRGGBB"), or warm light.
    static func tint(_ hex: String?) -> Color {
        guard let hex, hex.count == 6, let v = UInt32(hex, radix: 16) else { return warm }
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// A pane of glass: a faint white fill, lighter at the top, and a rim that
/// catches the light at the top left.
struct GlassFill<S: InsettableShape>: View {
    let shape: S

    var body: some View {
        shape
            .fill(LinearGradient(colors: [.white.opacity(0.26), .white.opacity(0.07)], startPoint: .top, endPoint: .bottom))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.06), .white.opacity(0.22)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8))
    }
}

/// A soft light behind the pane's top left, in the activity's colour.
struct Glow: View {
    let color: Color

    var body: some View {
        RadialGradient(colors: [color.opacity(0.5), color.opacity(0.16), color.opacity(0)], center: .topLeading, startRadius: 0, endRadius: 230)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Progress as liquid in a glass tube. With `range` it fills by itself
/// (ProgressView(timerInterval:)), else it shows `progress` still.
struct LiquidBar: View {
    let range: ClosedRange<Date>?
    let progress: Double
    let tint: Color

    var body: some View {
        Group {
            if let range {
                ProgressView(timerInterval: range, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    .progressViewStyle(.linear)
                    .tint(tint)
            } else {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(LiquidGlass.track)
                        Capsule().fill(tint).frame(width: max(4, g.size.width * min(1, max(0, progress))))
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 3)
        .background(GlassFill(shape: Capsule()))
        .accessibilityHidden(true)
    }
}

/// The picture the app saved for the activity (LiveActivityFiles), or a
/// dark glass tile with a play glyph; a glass rim, and the picture's colour
/// glowing under it.
struct ActivityArtwork: View {
    let name: String?
    let size: CGFloat
    var tint: Color = LiquidGlass.warm
    var round = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: round ? size / 2 : size * 0.26, style: .continuous)
        Group {
            if let url = LiveActivityFiles.url(for: name), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [tint.opacity(0.45), Color(red: 0.08, green: 0.07, blue: 0.07)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    // Not a play glyph: next to the play/pause button it read as a second control (4 Nov).
                    Image(systemName: "film").font(.system(size: size * 0.32, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                    lineWidth: round ? 0.5 : 1))
        .shadow(color: round ? .clear : tint.opacity(0.45), radius: 9, y: 2)
        .accessibilityHidden(true)
    }
}
