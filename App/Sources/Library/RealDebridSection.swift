import SwiftUI

/// Home's Real-Debrid section (1.20.0): its own section below Library, so
/// your local files and Real-Debrid stay apart. A row of the newest
/// releases, one per title, with their posters and clean titles; the header
/// has the item count, the total size and See all (the full library).
///
/// - Shown when a Real-Debrid server is added with a user name and the last
///   check of its library worked. Drawn from a saved summary
///   (IndexSummaries, UserDefaults), so it's there on Home's first frame
///   with nothing added to launch; the library is checked again in the
///   background (LibraryIndexStore.refreshIfNeeded).
/// - A refused login, or the server removed: it leaves, animated. Offline:
///   it stays, marked offline; a release or See all opens the library page,
///   which says it can't be reached.
enum RealDebrid {
    static func isRealDebrid(_ s: WebDAVServer) -> Bool {
        (s.base?.host?.lowercased().hasSuffix("real-debrid.com") ?? false) && !s.username.isEmpty
    }

    /// The row's length: your library had 213 releases on 30 Oct; 20 is
    /// about six screens of swiping on a phone, the rest is a tap away in
    /// See all, and only the posters you scroll to are looked up.
    static let rowLimit = 20

    static func subtitle(_ s: LibraryIndexStore.Summary) -> String {
        "\(s.files) item\(s.files == 1 ? "" : "s") · \(s.bytes.byteString)"
    }
}

struct RealDebridSection: View {
    let summary: LibraryIndexStore.Summary
    let margin: CGFloat
    let seeAllAction: () -> Void
    let open: (LibraryIndexStore.Summary.Release) -> Void

    private struct Item: Identifiable {
        let release: LibraryIndexStore.Summary.Release
        let name: ReleaseName
        var id: String { release.id }
    }

    private var items: [Item] {
        (summary.releases ?? []).compactMap { r in ReleaseName.folder(r.name).map { Item(release: r, name: $0) } }
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header.padding(.horizontal, margin)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        Button { open(item.release) } label: { ReleaseTile(release: item.name) }
                            .buttonStyle(PressStyle(scale: 0.97))
                            .accessibilityLabel(ReleaseTile.spoken(item.name))
                            .accessibilityIdentifier("rd:" + item.name.title)
                    }
                }
                .padding(.horizontal, margin)
            }
            .scrollClipDisabled()
        }
    }

    /// "Real-Debrid", what's in it (and Offline), See all. At the largest
    /// text sizes the three go one under the other.
    @ViewBuilder
    private var header: some View {
        let title = Text("Real-Debrid").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
        let info = Text(RealDebrid.subtitle(summary) + (summary.offline ? " · Offline" : ""))
            .font(.subheadline).foregroundStyle(.secondary)
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) { title; info; seeAll.padding(.top, 4) }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                title
                info.lineLimit(1)
                Spacer(minLength: 8)
                seeAll
            }
        }
    }

    private var seeAll: some View {
        Button(action: seeAllAction) {
            HStack(spacing: 2) { Text("See all"); Image(systemName: "chevron.right").font(.caption.weight(.bold)) }
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("See all of Real-Debrid")
        .accessibilityIdentifier("realDebridSeeAll")
    }
}

/// One release in the row: its poster (or initials), clean title, and what
/// it is (season, year, resolution).
struct ReleaseTile: View {
    let release: ReleaseName
    private static let width: CGFloat = 112

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ReleasePoster(release: release, width: Self.width, cornerRadius: 12)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            Text(release.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(detail).font(.caption2.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: Self.width, alignment: .leading)
    }

    private var detail: String { Self.detail(release) }

    static func detail(_ r: ReleaseName) -> String {
        [r.label, r.year, r.attribute(.resolution)].compactMap { $0 }.joined(separator: " · ")
    }

    /// What VoiceOver says: "MobLand, S01 · 2025 · 2160p".
    static func spoken(_ r: ReleaseName) -> String {
        [r.title, detail(r)].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
