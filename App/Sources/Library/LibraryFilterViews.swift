import SwiftUI

/// The filter button beside Home's sort menu (1.22.0): watched state, then
/// genre and year as submenus, each listing what the library has.
struct LibraryFilterMenu: View {
    @Binding var watch: String
    @Binding var genre: String
    @Binding var year: String
    let genres: [String]
    let years: [String]
    /// Still looking titles up: the lists may grow.
    var loading = false

    private var filter: LibraryFilter { LibraryFilter(watch: watch, genre: genre, year: year) }

    var body: some View {
        Menu {
            Picker("Show", selection: $watch) {
                ForEach(LibraryFilter.Watch.allCases) { Label($0.title, systemImage: $0.icon).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            Menu {
                Picker("Genre", selection: $genre) {
                    Text("Any Genre").tag("")
                    ForEach(genres, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text("Genre")
                Text(genre.isEmpty ? "Any" : genre)
            }
            Menu {
                Picker("Year", selection: $year) {
                    Text("Any Year").tag("")
                    ForEach(years, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text("Year")
                Text(year.isEmpty ? "Any" : year)
            }
            if loading { Text("Still reading titles…") }
            if filter.isActive {
                Divider()
                Button(role: .destructive) { clear() } label: { Label("Clear Filters", systemImage: "xmark.circle") }
            }
        } label: {
            // Sliders, not the sort's decreasing lines: the two buttons sit side by side.
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 34).menuLabelCircle()
                .overlay(alignment: .topTrailing) {
                    if filter.isActive { Circle().fill(Theme.accent).frame(width: 9, height: 9).overlay(Circle().strokeBorder(Theme.background, lineWidth: 1.5)) }
                }
        }
        .glassMenuCircle()
        .foregroundStyle(.primary)
        .accessibilityLabel(filter.isActive ? "Filter, \(filter.summary)" : "Filter")
        .accessibilityIdentifier("libraryFilterMenu")
    }

    private func clear() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { watch = LibraryFilter.Watch.all.rawValue; genre = ""; year = "" }
    }
}

/// The filters in use, under the library's header; ✕ clears them.
struct LibraryFilterChip: View {
    let summary: String
    let clear: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "slider.horizontal.3").font(.caption.weight(.semibold))
            Text(summary).font(.subheadline.weight(.semibold)).lineLimit(1)
            Button(action: clear) {
                Image(systemName: "xmark").font(.caption2.weight(.bold)).frame(width: 22, height: 22).background(Theme.fill, in: Circle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Clear filters")
        }
        .foregroundStyle(Theme.onAccent)
        .padding(.leading, 12).padding(.trailing, 5).frame(height: 32)
        .background(Theme.accent, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("libraryFilterChip")
    }
}

/// Nothing left after the filters (or the kids profile): why, and the way back.
struct LibraryFilterEmpty: View {
    let message: String
    /// nil: no filter to clear (only the kids profile hides titles).
    let clear: (() -> Void)?
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let clear {
                Button(action: clear) {
                    Text("Clear filters").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18).frame(height: 40).glass(cornerRadius: 20, interactive: true)
                }
                .buttonStyle(PressStyle())
                .accessibilityIdentifier("clearFilters")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

/// "Pick something for me" (1.22.0): one unwatched film, with Play and Pick again.
struct PickForMeSheet: View {
    let candidates: [PickForMe.Candidate]
    let play: (URL) -> Void
    @State private var current: PickForMe.Candidate?
    @State private var picked = false
    @ObservedObject private var index = LibraryMetaIndex.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.showRatings) private var showRatings = true

    var body: some View {
        NavigationStack {
            Group {
                if let c = current {
                    ScrollView { film(c).padding(20) }
                } else if picked || candidates.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing to pick", systemImage: "dice")
                    } description: {
                        Text(KidsProfile.isOnNow
                             ? "There's no unwatched film in your library that the kids profile allows."
                             : "Every film in your library is watched or started. Add some films, or mark one as unwatched.")
                    }
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(HomeBackdrop().ignoresSafeArea())
            .navigationTitle("Something to watch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .onAppear { if !picked { pickAgain() } }
    }

    private func pickAgain() {
        let next = PickForMe.pick(candidates, avoiding: current?.file)
        dlog("library", "pick for me: \(next.map { $0.file.lastPathComponent } ?? "nothing") of \(candidates.count) unwatched film(s)")
        withAnimation(.smooth(duration: 0.3)) { current = next; picked = true }
    }

    private func film(_ c: PickForMe.Candidate) -> some View {
        let meta = index.meta(for: c.file)
        let name = meta?.name ?? TitleParser.clean(c.file.lastPathComponent)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                PickPoster(file: c.file).id(c.file)
                    .frame(width: 120, height: 180)
                VStack(alignment: .leading, spacing: 6) {
                    Text(name).font(.system(.title2, design: .rounded, weight: .bold)).lineLimit(3).minimumScaleFactor(0.8)
                    let line = [LibraryFilter.year(meta: meta?.year, fileName: c.file.lastPathComponent),
                                meta?.genres.map { $0.prefix(3).joined(separator: ", ") },
                                showRatings ? meta?.rating.map { "★ \($0)" } : nil].compactMap { $0 }.filter { !$0.isEmpty }
                    if !line.isEmpty { Text(line.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary) }
                    Text("Added \(c.added.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if let plot = meta?.description, !plot.isEmpty {
                Text(plot).font(.subheadline).lineLimit(8)
            }
            HStack(spacing: 12) {
                PrimaryChip(icon: "play.fill", title: "Play") {
                    dismiss()
                    // After the sheet has gone, so the player doesn't open under it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { play(c.file) }
                }
                .accessibilityIdentifier("pickPlay")
                if candidates.count > 1 {
                    Button { pickAgain() } label: {
                        Label("Pick again", systemImage: "dice").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .glass(cornerRadius: 20, interactive: true)
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityIdentifier("pickAgain")
                }
            }
        }
        .transition(.opacity)
    }
}

/// The picked film's poster: a loader of its own for each film (`.id`), so
/// the last film's poster never shows while the next one loads.
private struct PickPoster: View {
    let file: URL
    @StateObject private var thumb = ThumbLoader()
    var body: some View {
        Color.clear
            .overlay {
                if let img = thumb.image { Image(uiImage: img).resizable().scaledToFill() } else { GeneratedArt(seed: file.lastPathComponent) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: Theme.shadow, radius: 10, y: 5)
            .onAppear { thumb.load(key: file.path, fileURL: file, artwork: nil, lookupName: file.lastPathComponent, art: .poster, points: 180) }
            .accessibilityHidden(true)
    }
}
