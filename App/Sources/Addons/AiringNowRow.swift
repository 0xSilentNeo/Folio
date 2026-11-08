import SwiftUI

/// Discover's "Airing now" row (1.26.0): series or anime with episodes out
/// lately, chosen with a pill. Settings → Discover can hide it.
struct AiringNowRow: View {
    let margin: CGFloat
    let zoomNS: Namespace.ID
    /// Bumped by Discover's pull to refresh.
    var refresh: Int = 0
    @AppStorage(SettingsKey.discoverAiring) private var enabled = true
    @AppStorage(SettingsKey.discoverAiringKind) private var kindRaw = AiringCatalog.Kind.series.rawValue
    @ObservedObject private var kids = KidsProfile.shared
    @StateObject private var model = AiringNowRowModel()

    private var kind: AiringCatalog.Kind { AiringCatalog.Kind(rawValue: kindRaw) ?? .series }

    var body: some View {
        if enabled {
            let all = model.lists[kind] ?? []
            // The kids profile: only what its ratings allow (these lists rarely say, so often none).
            let entries = kids.activeLimits.map { l in all.filter { KidsRules.allows($0.meta, limits: l) } } ?? all
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Airing now").font(.title3.weight(.bold))
                            .accessibilityAddTraits(.isHeader)
                        Text(kind == .series ? "New episodes · TVmaze" : "This season · AniList")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    SegmentPicker(options: AiringCatalog.Kind.allCases.map { ($0.rawValue, $0.title) }, selection: $kindRaw)
                        .frame(width: 150, height: 32)
                        .accessibilityLabel("Airing now: series or anime")
                }
                .padding(.horizontal, margin)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        if entries.isEmpty && model.loading.contains(kind) {
                            ForEach(0..<6, id: \.self) { _ in
                                VStack(alignment: .leading, spacing: 6) {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card).frame(width: 118, height: 177)
                                    Capsule().fill(Theme.card).frame(width: 84, height: 10)
                                }
                            }
                            .accessibilityHidden(true)
                        }
                        ForEach(entries) { e in
                            NavigationLink {
                                MetaDetailView(preview: e.meta, sourceAddon: nil).zoomDestination("air|" + e.id, in: zoomNS)
                            } label: {
                                VStack(alignment: .leading, spacing: 0) {
                                    PosterCard(meta: e.meta, width: 118, zoom: ZoomSource("air|" + e.id, zoomNS))
                                    if let note = e.note, !note.isEmpty {
                                        Text(note).font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                                            .lineLimit(1).frame(width: 118, alignment: .leading).padding(.top, 2)
                                    }
                                }
                                .accessibilityElement(children: .combine)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { WatchlistMenuButton(meta: e.meta) }
                        }
                    }
                    .padding(.horizontal, margin)
                }
                .scrollIndicators(.hidden)
                // A scroll view per kind (1.26.2): the other kind's list starts
                // from its first title, not where this one was scrolled to.
                .id(kind)
                if entries.isEmpty && !model.loading.contains(kind) {
                    Text(kids.isOn && !all.isEmpty ? "Nothing airing that's rated for the kids profile." : "Couldn't load what's airing. Pull to refresh.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.horizontal, margin)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("airingRow")
            .onAppear { model.show(kind) }
            .onChange(of: kindRaw) { model.show(kind) }
            .onChange(of: refresh) { model.show(kind, force: true) }
        }
    }
}
