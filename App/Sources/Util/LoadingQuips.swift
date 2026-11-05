import SwiftUI

/// A title page still loading (1.22.5): a bouncing popcorn and a line that
/// changes every 2 s, instead of a spinner. Nothing for the first 0.6 s:
/// most pages come from the cache sooner, and a line that only flashes
/// looks like a glitch. The lines come in a shuffled order, each once
/// before any comes again. Reduce Motion: they only fade.
struct LoadingQuips: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var order: [Int] = []
    @State private var step = 0

    static let lines = [
        "Bribing the projectionist…",
        "Rewinding the tape…",
        "Finding the remote in the couch…",
        "Skipping the “previously on”…",
        "Shushing row C…",
        "Microwaving the popcorn…",
        "Untangling the film reel…",
        "Fast-forwarding through the trailers…",
        "Adjusting the tracking…",
        "Blowing on the cartridge…",
        "Arguing about who picks…",
        "Dimming the lights…",
        "Finding a seat that isn't sticky…",
        "Waking up the extras…",
        "Checking the plot for holes…",
        "Hunting for the subtitles…",
        "Pausing for dramatic effect…",
        "Sneaking snacks past the usher…",
        "Counting the post-credit scenes…",
        "Calling the stunt double…",
        "Asking IMDb nicely…",
        "Turning it off and on again…",
        "Loading the plot twist…",
        "Buttering everything…",
        "Polishing the trophy…",
        "Feeding the projector hamster…",
        "Reading the director's notes…",
    ]

    /// The line for a step: the shuffled order, round and round.
    static func line(_ step: Int, order: [Int]) -> String {
        guard !order.isEmpty else { return lines[0] }
        return lines[order[step % order.count]]
    }

    /// Every line once, in a random order that doesn't start with `notFirst`
    /// (the last one shown), so a new round never repeats a line at once.
    static func shuffled(notFirst: Int? = nil) -> [Int] {
        var o = Array(lines.indices).shuffled()
        if let n = notFirst, o.first == n, o.count > 1 { o.swapAt(0, 1) }
        return o
    }

    var body: some View {
        VStack(spacing: 12) {
            if shown {
                Image(systemName: "popcorn.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.bounce, value: step)
                    .transition(.opacity)
                Text(Self.line(step, order: order))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .id(step)
                    .transition(reduceMotion ? .opacity : .push(from: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 92)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
        .accessibilityIdentifier("loadingQuips")
        .task {
            order = Self.shuffled()
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { shown = true }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                let next = step + 1
                if next % order.count == 0 { order = Self.shuffled(notFirst: order.last) }
                withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.45, dampingFraction: 0.85)) { step = next }
            }
        }
    }
}
