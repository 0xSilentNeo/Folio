import SwiftUI
import TipKit

/// Addons (1.27.0: also a sheet from Discover's header). Each addon has a
/// switch, the time it last took to answer, and its place in the list, which
/// is the order of the streams list; below them, the catalogs Discover shows.
struct AddonsManagerView: View {
    @ObservedObject private var store = AddonStore.shared
    @ObservedObject private var health = AddonHealth.shared
    @State private var url = ""
    @State private var error: String?
    @State private var removing: InstalledAddon?
    @Environment(\.openURL) private var openURL
    /// Discover's sources (1.27.1): their order, the TMDB key (moved here
    /// from Settings → Discover), Cinemeta being installed.
    @AppStorage(DiscoverSource.orderKey) private var sourceOrder = ""
    @AppStorage("tmdbApiKey") private var tmdbKey = ""
    @State private var editingKey = false
    @State private var keyDraft = ""
    @State private var installingCinemeta = false

    var body: some View {
        List {
            addSection
            sourcesSection
            if store.addons.isEmpty {
                ContentUnavailableView("No Addons", systemImage: "puzzlepiece.extension",
                                       description: Text("Addons add streams, subtitles and catalogs. Paste an addon's manifest link above."))
                    .listRowBackground(Color.clear)
            } else {
                installedSection
                catalogsSection
            }
        }
        .brandListBackground()
        .navigationTitle("Addons")
        .toolbar { EditButton() }
        .alert("TMDB API Key", isPresented: $editingKey) {
            SecureField("Key (v3)", text: $keyDraft)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Save") {
                tmdbKey = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                dlog("discover", tmdbKey.isEmpty ? "TMDB key removed" : "TMDB key added")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Free for personal use: themoviedb.org → Settings → API. Discover then goes on past IMDb's 250 titles.")
        }
        .confirmationDialog("Remove \(removing?.manifest.name ?? "Addon")?", isPresented: removingShown, titleVisibility: .visible, presenting: removing) { a in
            Button("Remove", role: .destructive) {
                store.remove(a)
                health.forget(a.id)
            }
        } message: { _ in
            Text("Its link and the options in it go with it. To use it again, configure it on its website and paste the new link.")
        }
    }

    private var removingShown: Binding<Bool> {
        Binding { removing != nil } set: { if !$0 { removing = nil } }
    }

    // MARK: Add

    private var addSection: some View {
        Section {
            HStack {
                TextField("https://…/manifest.json", text: $url)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Button {
                    Task {
                        do { try await store.install(url); url = ""; error = nil } catch { self.error = error.localizedDescription }
                    }
                } label: {
                    if store.installing { FolioSpinner(size: .small) } else { Text("Install").fontWeight(.semibold) }
                }
                .disabled(url.isEmpty || store.installing)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            // The system's paste button (1.24.1): no "allow paste" prompt, and
            // no main thread waiting on one (a 1.6 s stall, 3 Nov report).
            PasteButton(payloadType: String.self) { strings in
                if let s = strings.first { url = s.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        } header: { Text("Add Addon") } footer: {
            Text("Works with addons that have a manifest link (Torrentio, Comet or MediaFusion with your debrid key, OpenSubtitles, anime catalogs…). Configure an addon on its website, then paste its manifest link here. Only direct HTTP(S) streams play; torrents need an addon set up with a debrid service.")
        }
    }

    // MARK: Discover's titles

    private var sourceList: [DiscoverSource] { DiscoverSource.order(sourceOrder).filter { $0 != .imdb } }

    private var sourcesSection: some View {
        Section {
            ForEach(sourceList) { s in sourceRow(s) }
                .onMove { from, to in
                    var list = sourceList
                    list.move(fromOffsets: from, toOffset: to)
                    sourceOrder = list.map(\.rawValue).joined(separator: ",")
                    dlog("discover", "sources in order: \(list.map(\.name).joined(separator: ", ")), then IMDb")
                }
            SourceRow(name: "IMDb", detail: "Built in. Its lists stop at 250 titles.", inUse: DiscoverSource.current == .imdb) {
                EmptyView()
            }
            .moveDisabled(true)
        } header: {
            Text("Discover's Titles")
        } footer: {
            Text("Discover's grid comes from the first of these that's set up, and from the next when it doesn't answer: tap Edit and drag to change the order. IMDb is used when neither Cinemeta nor TMDB is set up.")
        }
    }

    @ViewBuilder
    private func sourceRow(_ s: DiscoverSource) -> some View {
        let inUse = DiscoverSource.current == s
        switch s {
        case .cinemeta:
            let installed = store.cinemetaInstalled
            SourceRow(name: "Cinemeta",
                      detail: installed == nil ? "Stremio's catalog of IMDb's titles. No key needed."
                          : installed!.enabled ? "Installed" : "Installed, switched off below",
                      inUse: inUse) {
                if installed == nil {
                    Button {
                        installingCinemeta = true
                        Task {
                            do { try await store.installCinemeta(); error = nil } catch { self.error = error.localizedDescription }
                            installingCinemeta = false
                        }
                    } label: {
                        if installingCinemeta { FolioSpinner(size: .small) } else { Text("Install") }
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .tint(Theme.action)
                    .disabled(installingCinemeta)
                    .accessibilityIdentifier("installCinemeta")
                }
            }
        case .tmdb:
            SourceRow(name: "TMDB", detail: tmdbKey.isEmpty ? "Needs your free API key." : "Key added", inUse: inUse) {
                Button(tmdbKey.isEmpty ? "Add Key" : "Change") {
                    keyDraft = tmdbKey
                    editingKey = true
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .accessibilityIdentifier("tmdbKey")
            }
            .swipeActions(allowsFullSwipe: false) {
                if !tmdbKey.isEmpty {
                    Button("Remove Key", systemImage: "key.slash", role: .destructive) { tmdbKey = "" }
                }
            }
        case .imdb:
            EmptyView()
        }
    }

    // MARK: Installed

    private var installedSection: some View {
        Section {
            ForEach($store.addons) { $a in
                AddonRow(addon: a, answer: health.last[a.id], isOn: $a.enabled)
                    .swipeActions(allowsFullSwipe: false) {
                        Button("Remove…", systemImage: "trash", role: .destructive) { removing = a }
                        if a.manifest.configurable {
                            Button("Configure", systemImage: "gear") { configure(a) }.tint(.gray)
                        }
                    }
                    .contextMenu {
                        Button("Copy Manifest Link", systemImage: "doc.on.doc") { UIPasteboard.general.string = a.transportURL }
                        if a.manifest.configurable {
                            Button("Configure", systemImage: "gear") { configure(a) }
                        }
                        Button("Remove…", systemImage: "trash", role: .destructive) { removing = a }
                    }
            }
            .onMove { store.move(from: $0, to: $1) }
        } header: {
            Text("Installed")
        } footer: {
            Text("Streams are listed in this order: tap Edit and drag an addon to move it. An addon switched off keeps its link but isn't asked for streams, subtitles or catalogs.")
        }
    }

    private func configure(_ a: InstalledAddon) {
        if let u = URL(string: a.baseURL + "/configure") { openURL(u) }
    }

    // MARK: Catalogs

    @ViewBuilder
    private var catalogsSection: some View {
        let catalogs = store.browsableCatalogs
        if !catalogs.isEmpty {
            Section {
                ForEach(catalogs) { ref in
                    Toggle(isOn: shown(ref.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(CatalogRow.title(ref.catalog))
                            Text(ref.addon.manifest.name).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("On Discover")
            } footer: {
                Text("Rows on Discover above the grid, in the addons' order. Not shown in the Kids Profile.")
            }
        }
    }

    private func shown(_ id: String) -> Binding<Bool> {
        Binding {
            !store.hiddenCatalogs.contains(id)
        } set: { on in
            if on { store.hiddenCatalogs.remove(id) } else { store.hiddenCatalogs.insert(id) }
        }
    }
}

/// One of Discover's sources: its name, how it's set up, a mark on the one
/// in use, and an action (Install, Add Key).
struct SourceRow<Action: View>: View {
    let name: String
    let detail: String
    let inUse: Bool
    @ViewBuilder var action: Action

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.body.weight(.semibold))
                    if inUse {
                        Text("In Use")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.action)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.action.opacity(0.14), in: Capsule())
                    }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            action
        }
        .accessibilityElement(children: .contain)
    }
}

/// An installed addon: logo, name, what it gives, how it last answered, and
/// its switch.
struct AddonRow: View {
    let addon: InstalledAddon
    let answer: AddonHealth.Answer?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(alignment: .top, spacing: 12) {
                AddonLogo(addon: addon)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(addon.manifest.name).font(.headline)
                        if let v = addon.manifest.version { Text("v\(v)").font(.caption).foregroundStyle(.secondary) }
                    }
                    Text(addon.manifest.resources.map { Self.resourceName($0.name) }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(Theme.accent)
                    answerLine
                    if let d = addon.manifest.description {
                        Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .opacity(isOn ? 1 : 0.55)
            }
        }
        .tint(Theme.action)
        .accessibilityIdentifier("addon-\(addon.manifest.id)")
    }

    /// What a resource gives, in words: "addon_catalog" isn't one.
    static func resourceName(_ r: String) -> String {
        switch r.lowercased() {
        case "stream": "Streams"
        case "subtitles": "Subtitles"
        case "catalog": "Catalogs"
        case "meta": "Details"
        case "addon_catalog": "Addon Lists"
        default: r.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    @ViewBuilder
    private var answerLine: some View {
        if let answer {
            Text("\(AddonHealth.describe(answer)), \(answer.at.formatted(.relative(presentation: .named)))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(answer.ok ? Color.secondary : Color.orange)
        } else {
            Text("Not asked yet").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The addon's own logo, or a puzzle piece on a card when it has none.
struct AddonLogo: View {
    let addon: InstalledAddon
    @ScaledMetric(relativeTo: .headline) private var side: CGFloat = 32

    var body: some View {
        Group {
            if let logo = addon.manifest.logo, let u = URL(string: logo) {
                CachedImage(url: u, maxPixel: 120) { $0.resizable().scaledToFit() } placeholder: { placeholder }
            } else {
                placeholder
            }
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: side * 0.225, style: .continuous))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Image(systemName: "puzzlepiece.extension.fill")
            .font(.system(size: side * 0.5))
            .foregroundStyle(.secondary)
            .frame(width: side, height: side)
            .background(Theme.card)
    }
}

/// Addons as a sheet, from Discover's header (1.27.0).
struct AddonsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AddonsManagerView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }.accessibilityIdentifier("addonsDone")
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

/// Discover's addons button (1.27.0). Addons had no place of their own
/// until then, only an item in the "…" menu. 1.27.1: the sheet slides up,
/// as the Watchlist's beside it does (it grew out of the button).
struct AddonsSheetButton: View {
    @ObservedObject private var store = AddonStore.shared
    @State private var showing = false

    var body: some View {
        let on = store.active.count
        Button { showing = true } label: {
            Image(systemName: "puzzlepiece.extension")
                .symbolVariant(on > 0 ? .fill : .none)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .glassCircle()
        }
        .buttonStyle(PressStyle())
        .foregroundStyle(.primary)
        .accessibilityLabel("Addons")
        .accessibilityValue(store.addons.isEmpty ? "None installed" : "\(on) of \(store.addons.count) on")
        .accessibilityIdentifier("addonsButton")
        .popoverTip(AddonsTip(), arrowEdge: .top)
        .sheet(isPresented: $showing) { AddonsSheet() }
        .onChange(of: showing) { _, open in if open { AddonsTip().invalidate(reason: .actionPerformed) } }
        // The welcome's "Add Addons" (1.27.0).
        .onReceive(FirstRunRouter.shared.$request) { if $0 == .addons, FirstRunRouter.shared.take(.addons) { showing = true } }
        .onChange(of: store.addons.isEmpty, initial: true) { _, none in AddonsTip.noAddons = none }
    }
}
