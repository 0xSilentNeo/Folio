import SwiftUI

/// Fix Match (1.29.0): the title Folio matched a file to is wrong, or it
/// found none. Search IMDb, pick the right one, and every file of that
/// title follows it. Until then the only cure was Settings → Refresh
/// Metadata, which threw everything away and matched the same way again.
struct FixMatchSheet: View {
    /// A file of the title.
    let file: URL
    /// Matched (or put back to automatic): the page behind reloads.
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [MetaItem] = []
    @State private var phase = Phase.idle
    @State private var pinned: MetadataService.Pin?
    @State private var working = false

    private enum Phase: Equatable { case idle, searching, done, failed }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(results) { m in
                        Button { choose(m) } label: { row(m) }
                            .buttonStyle(.plain)
                            .disabled(working)
                            .accessibilityIdentifier("fixMatch:" + m.id)
                    }
                    if phase == .searching && results.isEmpty {
                        FolioWorkingRow(text: "Searching IMDb…")
                    }
                    if phase == .done && results.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                    if phase == .failed {
                        ContentUnavailableView("Couldn't Reach IMDb", systemImage: "wifi.slash",
                                               description: Text("Check the connection and try again."))
                    }
                } header: {
                    Text("File: \(file.lastPathComponent)").textCase(nil).lineLimit(2)
                } footer: {
                    Text("Every file of this title uses the one you pick: its poster, description, rating and episode names.")
                }
                if pinned != nil {
                    Section {
                        Button("Use the Automatic Match", role: .destructive) { apply(nil) }
                            .disabled(working)
                    } footer: {
                        Text("This title was matched by hand.")
                    }
                }
            }
            .navigationTitle("Fix Match")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Title on IMDb")
            .autocorrectionDisabled()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task {
                let p = TitleParser.parse(file.lastPathComponent)
                query = TitleParser.baseTitle(p)
                pinned = await MetadataService.shared.pin(forFile: file.lastPathComponent)
            }
            // As you type, after a pause.
            .task(id: query) {
                let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard q.count >= 2 else { results = []; phase = .idle; return }
                phase = .searching
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                do {
                    let found = try await IMDbSource.suggest(q)
                    guard !Task.isCancelled else { return }
                    results = found
                    phase = .done
                } catch {
                    guard !IMDbSource.isCancellation(error), !Task.isCancelled else { return }
                    phase = .failed
                }
            }
        }
    }

    private func row(_ m: MetaItem) -> some View {
        HStack(spacing: 12) {
            PosterImage(url: m.poster, cornerRadius: 8)
                .frame(width: 46)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(m.name).font(.body.weight(.semibold)).lineLimit(2)
                Text([m.releaseInfo, m.type == "series" ? "Series" : "Movie"].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if let cast = m.description, !cast.isEmpty {
                    Text(cast).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if pinned?.id == m.id {
                Image(systemName: "checkmark").foregroundStyle(Theme.accent).accessibilityLabel("Current match")
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func choose(_ m: MetaItem) { apply(MetadataService.Pin(id: m.id, type: m.type)) }

    private func apply(_ pin: MetadataService.Pin?) {
        working = true
        Task {
            await MetadataService.shared.setPin(pin, forFile: file.lastPathComponent)
            ImageCache.shared.forgetPictures()
            LibraryMetaIndex.shared.forget(titleOf: file)
            // Tiles already showing the title look it up again (1.30.4):
            // Home's kept their poster and details until the next launch.
            NotificationCenter.default.post(name: .folioMetadataChanged, object: MetadataService.pinKey(TitleParser.parse(file.lastPathComponent)))
            onChange()
            dismiss()
        }
    }
}

extension Notification.Name {
    /// A title was matched by hand or put back (Fix Match). Object: its
    /// key, MetadataService.pinKey.
    static let folioMetadataChanged = Notification.Name("FolioMetadataChanged")
}
