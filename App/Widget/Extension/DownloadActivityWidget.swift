import ActivityKit
import SwiftUI
import WidgetKit

/// The downloads Live Activity (1.22.0; the app's DownloadActivity runs it):
/// the file downloading, the run's progress, speed and time left, on the
/// Lock Screen and in the Dynamic Island. Tapping it opens Downloads.
struct DownloadActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            DownloadLockScreen(state: context.state, stale: context.isStale)
                .activityBackgroundTint(WidgetTheme.background)
                .activitySystemActionForegroundColor(WidgetTheme.text)
                .widgetURL(DownloadsLink.url)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    DownloadRing(state: s, size: 44, track: .white.opacity(0.2), fill: .white)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !s.done {
                        Text(context.isStale ? s.percentText : s.speedText)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .lineLimit(1)
                            .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(s.headline).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !s.done { ActivityBar(progress: s.progress, track: .white.opacity(0.2), fill: .white) }
                        Text(DownloadLines.detail(s, stale: context.isStale))
                            .font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: s.done ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(.white)
            } compactTrailing: {
                Text(s.done ? "Done" : s.percentText)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
            } minimal: {
                DownloadRing(state: s, size: 22, track: .white.opacity(0.25), fill: .white)
            }
            .widgetURL(DownloadsLink.url)
            .keylineTint(.white)
        }
    }
}

/// The Lock Screen's banner.
private struct DownloadLockScreen: View {
    let state: DownloadActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                DownloadRing(state: state, size: 40, track: WidgetTheme.fill, fill: WidgetTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.headline).font(.headline).lineLimit(1)
                    Text(DownloadLines.detail(state, stale: stale)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if !state.done {
                    Text(stale ? state.percentText : state.speedText)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                }
            }
            if !state.done { ActivityBar(progress: state.progress, track: WidgetTheme.fill, fill: WidgetTheme.accent) }
        }
        .padding(16)
        .foregroundStyle(WidgetTheme.text)
    }
}

private enum DownloadLines {
    /// Under the title: what's left, or (stale: Folio hasn't updated it
    /// for a while, it's in the background) that it carries on there.
    static func detail(_ s: DownloadActivityAttributes.ContentState, stale: Bool) -> String {
        if stale && !s.done {
            return s.filesLeft > 1 ? "Downloading in the background · \(s.filesLeft) files" : "Downloading in the background"
        }
        return s.detailText ?? s.percentText
    }
}

/// The run's progress around an arrow (a check once done).
private struct DownloadRing: View {
    let state: DownloadActivityAttributes.ContentState
    let size: CGFloat
    let track: Color
    let fill: Color

    var body: some View {
        let width = max(2, size / 12)
        ZStack {
            Circle().stroke(track, lineWidth: width)
            Circle().trim(from: 0, to: state.done ? 1 : max(0.02, min(1, state.progress)))
                .stroke(fill, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: state.done ? "checkmark" : "arrow.down")
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(fill)
        }
        .padding(width / 2)
        .frame(width: size, height: size)
        .accessibilityLabel(state.done ? "Downloads finished" : "Downloading, \(state.percentText)")
    }
}
