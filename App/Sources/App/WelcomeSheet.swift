import SwiftUI

/// The first launch's welcome. 1.29.0: three short pages you swipe through
/// (what Folio is, where your videos come from, what the player's gestures
/// do), with Skip always there. From 1.27.0 it was one long scrolling
/// sheet, and the setup cards sat below the fold on a small phone.
struct WelcomeSheet: View {
    /// A card was chosen: the sheet closes, then the app goes there.
    let onPick: (FirstRunRouter.Step) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var leaf: CGFloat = 76
    @State private var page = 0
    private static let pages = 3

    var body: some View {
        TabView(selection: $page) {
            intro.tag(0)
            sources.tag(1)
            gestures.tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .safeAreaInset(edge: .top) {
            HStack {
                Spacer()
                Button("Skip") { dismiss() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .opacity(page == Self.pages - 1 ? 0 : 1)
                    .accessibilityHidden(page == Self.pages - 1)
                    .accessibilityIdentifier("welcomeSkip")
            }
            .padding(.horizontal, 20)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 14) {
                dots
                Button {
                    if page < Self.pages - 1 {
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) { page += 1 }
                    } else {
                        dismiss()
                    }
                } label: {
                    Text(page < Self.pages - 1 ? "Continue" : "Get Started")
                        .font(.headline)
                        .frame(maxWidth: 512)
                        .frame(minHeight: 50)
                        .contentTransition(.opacity)
                        // Dark on the light clay of dark mode, white on the
                        // deep clay of light mode: white on both was 2:1 in dark.
                        .foregroundStyle(Color(light: 0xFFFFFF, dark: 0x1B1A18))
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(Theme.action)
                .accessibilityIdentifier(page < Self.pages - 1 ? "welcomeContinue" : "welcomeStart")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .background(HomeBackdrop().ignoresSafeArea())
        .interactiveDismissDisabled(false)
    }

    /// Which page of three: the current one a longer pill.
    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(0..<Self.pages, id: \.self) { i in
                Capsule()
                    .fill(i == page ? Theme.accent : Theme.accent.opacity(0.22))
                    .frame(width: i == page ? 22 : 7, height: 7)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: page)
        .accessibilityElement()
        .accessibilityLabel("Page \(page + 1) of \(Self.pages)")
    }

    // MARK: Pages

    private var intro: some View {
        WelcomePage {
            VStack(alignment: .leading, spacing: 14) {
                FolioLeaf()
                    .frame(width: leaf, height: leaf)
                    .padding(.leading, -8)
                    .accessibilityHidden(true)
                Text("Welcome to Folio")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text("Everything you watch, in one player.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 20) {
                Highlight(symbol: "play.rectangle.fill", tint: SettingsPalette.brick,
                          title: "Plays what you have",
                          detail: "MKV, HDR and Dolby Vision, every audio and subtitle track, with the engine's full controls.")
                Highlight(symbol: "externaldrive.connected.to.line.below", tint: SettingsPalette.slate,
                          title: "From wherever it is",
                          detail: "Files on this iPhone, a NAS, Jellyfin, Plex, Real-Debrid, or stream addons.")
                Highlight(symbol: "bookmark.fill", tint: SettingsPalette.sage,
                          title: "Keeps your place",
                          detail: "Continue Watching, the next episode ready, new episodes of shows you track.")
            }
        }
    }

    private var sources: some View {
        WelcomePage {
            PageTitle(title: "Where your videos come from", detail: "Start with any of these. You can add the others later.")
            VStack(alignment: .leading, spacing: 10) {
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
        }
    }

    private var gestures: some View {
        WelcomePage {
            PageTitle(title: "In the player", detail: "The controls stay out of the way. These do most of the work.")
            VStack(alignment: .leading, spacing: 16) {
                GestureLine(symbol: "hand.tap", text: "Double-tap the left or right side to skip; the middle pauses.")
                GestureLine(symbol: "arrow.left.and.right", text: "Swipe sideways to seek.")
                GestureLine(symbol: "sun.max", text: "Swipe up or down at the left edge for brightness, at the right edge for volume.")
                GestureLine(symbol: "forward.fill", text: "Press and hold to play faster.")
                GestureLine(symbol: "arrow.up.left.and.arrow.down.right", text: "Pinch to fill the screen.")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: .rect(cornerRadius: 22, style: .continuous))
        }
    }

    private func pick(_ step: FirstRunRouter.Step) {
        onPick(step)
        dismiss()
    }
}

/// One page: its content from the top, scrolling only when it doesn't fit
/// (large text, a small phone).
private struct WelcomePage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) { content }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

private struct PageTitle: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(.title, design: .rounded, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Text(detail).font(.body).foregroundStyle(.secondary)
        }
        .padding(.top, 12)
    }
}

/// What Folio does, on the first page: a tile and two lines.
private struct Highlight: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = 44

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: tile * 0.45, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: tile, height: tile)
                .background(tint.gradient, in: .rect(cornerRadius: tile * 0.27, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
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
