import ActivityKit
import SwiftUI
import WidgetKit

/// The downloads Live Activity (1.22.0; the app's DownloadActivity runs it).
/// Redrawn in 1.22.1 as liquid glass: a ring of water around a glass disc
/// with the download arrow, the file's name, speed and time left, and the
/// run's progress as water in a glass tube, on a dark see-through pane lit
/// from behind. The ring, the tube and the time left move by themselves
/// from the app's last estimate (timer views): in the background Folio is
/// suspended and can't update it (4 Nov report: it showed no progress).
/// Tapping it opens Downloads.
struct DownloadActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            DownloadLockScreen(state: context.state, stale: context.isStale)
                .activityBackgroundTint(LiquidGlass.backdrop)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(DownloadsLink.url)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    DownloadRing(state: s, size: 54, line: 4.5)
                        .padding(.leading, 6).padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    DownloadTimeLeft(state: s, stale: context.isStale, compact: false)
                        .padding(.trailing, 6).padding(.top, 6)
                }
                // Centred under the camera (1.24.1): until then the two lines
                // sat left in the middle region, nearer neither the ring nor
                // the time (7 Nov: "the text is not centered"), and the
                // second line ran out ("… · 1.3 MB/s…") repeating the title's
                // file count.
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .center, spacing: 3) {
                        Text(s.headline).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(DownloadLines.meta(s, stale: context.isStale, island: true))
                            .font(.caption.monospacedDigit()).foregroundStyle(LiquidGlass.secondary).lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !s.done {
                        LiquidBar(range: s.timerRange, progress: s.progress, tint: LiquidGlass.aqua)
                            .padding(.horizontal, 8).padding(.top, 10)
                    }
                }
            } compactLeading: {
                DownloadRing(state: s, size: 24, line: 2.6)
            } compactTrailing: {
                DownloadTimeLeft(state: s, stale: context.isStale, compact: true)
            } minimal: {
                DownloadRing(state: s, size: 24, line: 2.6)
            }
            .widgetURL(DownloadsLink.url)
            .keylineTint(LiquidGlass.aqua)
        }
    }
}

/// The Lock Screen's pane.
private struct DownloadLockScreen: View {
    let state: DownloadActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                DownloadRing(state: state, size: 58, line: 5)
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.headline).font(.headline).lineLimit(1)
                    Text(DownloadLines.meta(state, stale: stale))
                        .font(.caption.monospacedDigit()).foregroundStyle(LiquidGlass.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                DownloadTimeLeft(state: state, stale: stale, compact: false)
            }
            if !state.done {
                LiquidBar(range: state.timerRange, progress: state.progress, tint: LiquidGlass.aqua)
            }
        }
        .padding(16)
        .background(alignment: .topLeading) { Glow(color: LiquidGlass.aqua) }
        .foregroundStyle(.white)
    }
}

private enum DownloadLines {
    /// Under the name: the size and the speed next to it ("1.21 GB of 3.04
    /// GB · 25.2 MB/s", 1.24.1), and files; what's left once done; or (stale:
    /// Folio hasn't been heard from past the estimate) that it carries on.
    /// `island`: the Dynamic Island's narrower line, without the file count
    /// (its title already says "2 files" when there are several).
    static func meta(_ s: DownloadActivityAttributes.ContentState, stale: Bool, island: Bool = false) -> String {
        if s.done { return s.detailText ?? "" }
        if stale { return s.filesLeft > 1 && !island ? "Downloading in the background · \(s.filesLeft) files" : "Downloading in the background" }
        if s.waiting { return s.filesText ?? "Waiting" }
        var parts: [String] = []
        if let bytes = s.bytesText { parts.append(bytes) }
        if s.speed > 0 { parts.append(s.speedText) }
        if !island, let files = s.filesText { parts.append(files) }
        // The time left only: detailText repeats the file count (review,
        // 5 Nov: "3 files · 3 files").
        if s.timerRange == nil, !s.waiting, let left = s.secondsLeft { parts.append(ActivityFormat.minutesLeft(left)) }
        return parts.isEmpty ? s.percentText : parts.joined(separator: " · ")
    }
}

/// The time left, counting down by itself ("12:34", "left" under it);
/// the percentage with no estimate; Done at the end.
private struct DownloadTimeLeft: View {
    let state: DownloadActivityAttributes.ContentState
    let stale: Bool
    let compact: Bool

    var body: some View {
        if compact {
            Group {
                if state.done {
                    Image(systemName: "checkmark").font(.caption.weight(.bold))
                } else if let range = state.timeLeftRange, !stale {
                    Text(timerInterval: range, countsDown: true).multilineTextAlignment(.trailing)
                } else {
                    Text(state.percentText)
                }
            }
            .font(.system(.caption, design: .rounded).weight(.semibold).monospacedDigit())
            .foregroundStyle(LiquidGlass.aqua)
            .lineLimit(1)
            // A timer takes the width it may ever need: "1:02:03" needs more than "12:34".
            .frame(width: LiquidGlass.clockWidth(state.timeLeftRange), alignment: .trailing)
        } else if !state.done {
            VStack(alignment: .trailing, spacing: 0) {
                Group {
                    if let range = state.timeLeftRange, !stale {
                        Text(timerInterval: range, countsDown: true).multilineTextAlignment(.trailing)
                    } else {
                        Text(state.percentText)
                    }
                }
                .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
                .lineLimit(1)
                Text(state.timeLeftRange != nil && !stale ? "left" : "done")
                    .font(.caption2).foregroundStyle(LiquidGlass.secondary)
            }
            .frame(width: 78, alignment: .trailing)
        }
    }
}

/// The run's progress as a ring of water around a glass disc with the
/// arrow (a check once done). Fills by itself with an estimate.
private struct DownloadRing: View {
    let state: DownloadActivityAttributes.ContentState
    let size: CGFloat
    let line: CGFloat

    var body: some View {
        ZStack {
            Circle().inset(by: line / 2).stroke(LiquidGlass.track, lineWidth: line)
            if state.done {
                Circle().inset(by: line / 2).stroke(LiquidGlass.aqua, lineWidth: line)
            } else if let range = state.timerRange {
                ProgressView(timerInterval: range, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    .progressViewStyle(.circular)
                    .tint(LiquidGlass.aqua)
            } else {
                Circle().inset(by: line / 2).trim(from: 0, to: max(0.02, min(1, state.progress)))
                    .stroke(LiquidGlass.aqua, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            GlassFill(shape: Circle())
                .padding(line + max(1.5, size * 0.06))
            Image(systemName: state.done ? "checkmark" : state.waiting ? "clock" : "arrow.down")
                .font(.system(size: size * 0.3, weight: .bold))
                .foregroundStyle(state.done ? LiquidGlass.aqua : .white)
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(state.done ? "Downloads finished" : "Downloading, \(state.percentText)")
    }
}
