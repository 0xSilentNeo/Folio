import ActivityKit
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

/// The Live Activity for what's playing (1.22.0; the app's
/// NowPlayingActivity runs it): title, episode line, progress and time
/// left, with play/pause and 10 s back and forward (NowPlayingIntents) on
/// the Lock Screen and in the expanded Dynamic Island. The bar and the time
/// move by themselves from the last position (timer views): the app updates
/// it only on a pause, a play or a seek.
struct NowPlayingActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingActivityAttributes.self) { context in
            NowPlayingLockScreen(state: context.state)
                .activityBackgroundTint(WidgetTheme.background)
                .activitySystemActionForegroundColor(WidgetTheme.text)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityArtwork(name: s.artwork, size: 52).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    NowPlayingTimeLeft(state: s)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 64, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let line = s.subtitle {
                            Text(line).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        PlaybackBar(state: s, track: .white.opacity(0.2), fill: .white)
                        NowPlayingControls(paused: s.paused, spacing: 44)
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                ActivityArtwork(name: s.artwork, size: 24)
            } compactTrailing: {
                if s.paused {
                    Image(systemName: "pause.fill").foregroundStyle(.white)
                } else {
                    NowPlayingTimeLeft(state: s)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(maxWidth: 52)
                }
            } minimal: {
                Image(systemName: s.paused ? "pause.fill" : "play.fill").foregroundStyle(.white)
            }
            .keylineTint(.white)
        }
    }
}

/// The Lock Screen's banner.
private struct NowPlayingLockScreen: View {
    let state: NowPlayingActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ActivityArtwork(name: state.artwork, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title).font(.headline).lineLimit(1)
                    if let line = state.subtitle {
                        Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                NowPlayingControls(paused: state.paused, spacing: 16)
            }
            HStack(spacing: 10) {
                PlaybackBar(state: state, track: WidgetTheme.fill, fill: WidgetTheme.accent)
                NowPlayingTimeLeft(state: state)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
        }
        .padding(16)
        .foregroundStyle(WidgetTheme.text)
    }
}

/// Back 10 s, play/pause, forward 10 s: LiveActivityIntents that run in the
/// app, which tells the player.
private struct NowPlayingControls: View {
    let paused: Bool
    let spacing: CGFloat

    var body: some View {
        HStack(spacing: spacing) {
            Button(intent: NowPlayingBackIntent()) {
                Image(systemName: "gobackward.10").font(.title3)
            }
            .accessibilityLabel("Back 10 seconds")
            Button(intent: NowPlayingToggleIntent()) {
                Image(systemName: paused ? "play.fill" : "pause.fill").font(.title2)
                    .frame(width: 30)
            }
            .accessibilityLabel(paused ? "Play" : "Pause")
            Button(intent: NowPlayingForwardIntent()) {
                Image(systemName: "goforward.10").font(.title3)
            }
            .accessibilityLabel("Forward 10 seconds")
        }
        .buttonStyle(.plain)
    }
}

/// Fills by itself while playing (a timer from the last position); still while paused.
private struct PlaybackBar: View {
    let state: NowPlayingActivityAttributes.ContentState
    let track: Color
    let fill: Color

    var body: some View {
        if let range = state.timerRange {
            ProgressView(timerInterval: range, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                .progressViewStyle(.linear)
                .tint(fill)
        } else {
            ActivityBar(progress: state.progress(at: state.at), track: track, fill: fill)
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

// MARK: - Shared by both activities

/// A thin bar, as the widgets draw it.
struct ActivityBar: View {
    let progress: Double
    let track: Color
    let fill: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(fill).frame(width: max(4, g.size.width * min(1, max(0, progress))))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// The picture the app saved for the activity (LiveActivityFiles), or the
/// brand's graphite with a play glyph.
struct ActivityArtwork: View {
    let name: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let url = LiveActivityFiles.url(for: name), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [Color(red: 0.23, green: 0.22, blue: 0.20), Color(red: 0.08, green: 0.07, blue: 0.07)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "play.fill").font(.system(size: size * 0.36, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}
