import SwiftUI

/// Home's Real-Debrid entry: quick access to your Real-Debrid library, in
/// the Library, pinned first.
///
/// - Shown when a Real-Debrid server is added with a user name and the last
///   check of its library worked. It's drawn from a saved summary
///   (LibraryIndexStore.Summary, UserDefaults), so it's there on Home's
///   first frame with nothing added to launch; the library is checked again
///   in the background (LibraryIndexStore.refreshIfNeeded).
/// - A refused login, or the server removed: it leaves, animated. Offline:
///   it stays, marked offline, and its page says so.
/// - Pinned first, whatever the sort: it's a way into another library, not
///   one of your titles, and stays where your thumb expects it. It isn't
///   counted in the Library number, which counts what's on this phone.
enum RealDebrid {
    static func isRealDebrid(_ s: WebDAVServer) -> Bool {
        (s.base?.host?.lowercased().hasSuffix("real-debrid.com") ?? false) && !s.username.isEmpty
    }

    static func names(_ summary: LibraryIndexStore.Summary) -> [ReleaseName] {
        summary.recent.compactMap { ReleaseName.folder($0) }
    }

    static func subtitle(_ s: LibraryIndexStore.Summary) -> String {
        "\(s.files) item\(s.files == 1 ? "" : "s")" + (s.offline ? " · offline" : "")
    }

    static func accessibility(_ s: LibraryIndexStore.Summary) -> String {
        "Real-Debrid library, \(s.files) items, \(s.bytes.byteString)" + (s.offline ? ", offline" : "")
    }
}

/// Four of the newest releases' posters in a 2 × 2 grid, as a folder's collage.
struct ReleaseCollage: View {
    let releases: [ReleaseName]
    let gap: CGFloat
    let cell: CGFloat

    var body: some View {
        GeometryReader { geo in
            let h = (geo.size.height - gap) / 2
            LazyVGrid(columns: [GridItem(.flexible(), spacing: gap), GridItem(.flexible(), spacing: gap)], spacing: gap) {
                ForEach(0..<4, id: \.self) { i in
                    Group {
                        if i < releases.count { ReleasePoster(release: releases[i], width: nil) } else { Theme.fill }
                    }
                    .frame(height: max(0, h))
                    .clipShape(RoundedRectangle(cornerRadius: cell, style: .continuous))
                }
            }
        }
    }
}

/// Thumbnails layout: a tile like a folder's.
struct RealDebridTile: View {
    let summary: LibraryIndexStore.Summary
    var poster: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(poster ? 2.0 / 3.0 : 16.0 / 9.0, contentMode: .fit)
                .overlay { ReleaseCollage(releases: RealDebrid.names(summary), gap: poster ? 4 : 6, cell: poster ? 7 : 9).padding(poster ? 5 : 7) }
                .overlay(alignment: .bottomTrailing) { SizeBadge(size: summary.bytes).padding(poster ? 8 : 11) }
                .overlay(alignment: .topTrailing) { if summary.offline { OfflineBadge() } }
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: poster ? 12 : 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: poster ? 12 : 18, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            Text("Real-Debrid").font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(RealDebrid.subtitle(summary)).font(.caption2.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RealDebrid.accessibility(summary))
        .accessibilityAddTraits(.isButton)
    }
}

/// List and Details layouts: a row like a folder's.
struct RealDebridRow: View {
    let summary: LibraryIndexStore.Summary
    let detail: Bool

    var body: some View {
        HStack(spacing: 12) {
            ReleaseCollage(releases: RealDebrid.names(summary), gap: 3, cell: 5)
                .padding(4)
                .frame(width: detail ? 150 : 78, height: detail ? 84 : 44)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: detail ? 12 : 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("Real-Debrid").font(.subheadline.weight(.semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    if summary.offline { Image(systemName: "wifi.slash") }
                    Text("Library · " + RealDebrid.subtitle(summary))
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(summary.bytes.byteString).font(.caption2.weight(.medium).monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(detail ? 8 : 6)
        .background(RoundedRectangle(cornerRadius: detail ? 16 : 12, style: .continuous).fill(Theme.card))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RealDebrid.accessibility(summary))
        .accessibilityAddTraits(.isButton)
    }
}

private struct OfflineBadge: View {
    var body: some View {
        Image(systemName: "wifi.slash")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(5)
            .background(.black.opacity(0.55), in: Circle())
            .padding(6)
    }
}
