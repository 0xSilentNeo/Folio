import SwiftUI

/// The first launch's welcome (1.27.0): where videos come from, as cards that
/// take you there, and what the player's gestures do.
struct WelcomeSheet: View {
    /// A card was chosen: the sheet closes, then the app goes there.
    let onPick: (FirstRunRouter.Step) -> Void
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .largeTitle) private var leaf: CGFloat = 56

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    FolioLeaf()
                        .frame(width: leaf, height: leaf)
                        .accessibilityHidden(true)
                    Text("Welcome to Folio")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Your videos, from your phone, your servers and addons, in one player.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 36)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Start With").font(.headline).accessibilityAddTraits(.isHeader)
                    SetupCard(step: .addFiles, symbol: "folder.badge.plus", tint: SettingsPalette.clay,
                              title: "Add Your Videos",
                              detail: "Pick files or a folder in Files. Folio finds posters, episodes and seasons.") { pick(.addFiles) }
                    SetupCard(step: .addServer, symbol: "externaldrive.connected.to.line.below", tint: SettingsPalette.slate,
                              title: "Connect a Server",
                              detail: "SMB or WebDAV on a NAS or computer, Jellyfin or Plex.") { pick(.addServer) }
                    SetupCard(step: .addons, symbol: "puzzlepiece.extension.fill", tint: SettingsPalette.plum,
                              title: "Add Addons",
                              detail: "Streams, subtitles and catalogs on Discover.") { pick(.addons) }
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text("In the Player").font(.headline).accessibilityAddTraits(.isHeader)
                    GestureLine(symbol: "hand.tap", text: "Double-tap the left or right side to skip; the middle pauses.")
                    GestureLine(symbol: "arrow.left.and.right", text: "Swipe sideways to seek.")
                    GestureLine(symbol: "sun.max", text: "Swipe up or down at the left edge for brightness, at the right edge for volume.")
                    GestureLine(symbol: "forward.fill", text: "Press and hold to play faster.")
                    GestureLine(symbol: "arrow.up.left.and.arrow.down.right", text: "Pinch to fill the screen.")
                }
                .padding(18)
                .background(Theme.card, in: .rect(cornerRadius: 22, style: .continuous))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            Button { dismiss() } label: {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: 512)
                    .frame(minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(Theme.action)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .accessibilityIdentifier("welcomeStart")
            // The text scrolling under the button fades out first.
            .background {
                LinearGradient(stops: [.init(color: Theme.background.opacity(0), location: 0), .init(color: Theme.background, location: 0.4)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .presentationDragIndicator(.visible)
    }

    private func pick(_ step: FirstRunRouter.Step) {
        onPick(step)
        dismiss()
    }
}

/// A card that takes you to a setup step.
private struct SetupCard: View {
    let step: FirstRunRouter.Step
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = 40

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: tile * 0.45, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: tile, height: tile)
                    .background(tint.gradient, in: .rect(cornerRadius: tile * 0.25, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .multilineTextAlignment(.leading)
            .padding(14)
            .background(Theme.card, in: .rect(cornerRadius: 20, style: .continuous))
            .contentShape(.rect(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("welcome-\(step.rawValue)")
    }
}

private struct GestureLine: View {
    let symbol: String
    let text: String
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 28

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.action)
                .frame(width: width)
                .accessibilityHidden(true)
            Text(text).font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
