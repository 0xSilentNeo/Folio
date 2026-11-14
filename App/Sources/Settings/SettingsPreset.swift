import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Settings presets (1.17.0): everything set up in the app, in one file you
/// keep and import later (after a reinstall, on another device).
///
/// Made to survive app updates:
/// - Each setting is written by name with its value. On import it is checked
///   against the settings this version knows, by name *and* type. A name this
///   version doesn't know (a setting that was removed or renamed) or a value of
///   the wrong type is skipped and counted, never an error.
/// - Settings missing from the file keep their current value.
/// - Parts (settings, addons, servers, mpv files) are read independently: one
///   unreadable part doesn't stop the others.
/// - The file says which format version wrote it; a newer one still imports
///   whatever this version understands.
@MainActor
enum SettingsPreset {
    // Nonisolated (1.30.4): read by `plan`, which the tests call off the main actor.
    nonisolated static let format = "folio-preset"
    nonisolated static let version = 1

    /// The kind of value a setting holds.
    enum Kind { case bool, int, double, string, strings, data, dictionary }

    /// Every setting a preset carries, with its kind. Kinds come from the
    /// app's own defaults, so they always match what the app reads.
    static var known: [String: Kind] {
        var out: [String: Kind] = [:]
        let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        for (k, v) in registered where !skip.contains(k) { if let kind = kind(of: v) { out[k] = kind } }
        for (k, kind) in extras { out[k] = kind }
        return out
    }

    /// Settings without a registered default (stored by their own screens).
    private static let extras: [String: Kind] = [
        SettingsKey.activeShaders: .strings, SettingsKey.scriptCommands: .data, SettingsKey.pictureMode: .string,
        SettingsKey.folderSorts: .dictionary,
        "libraryView": .string, "librarySort": .string, "librarySortAsc": .bool, "heroView": .string,
        "screenshotSubs": .bool, "discoverRegion": .string, "discoverPlatforms": .strings,
        "seekMarkerStyle": .string, "seekMarkerColor": .string, "seekShowChapterTitle": .bool, "seekShowSkip": .bool,
        "rememberPerShow": .bool, "subStyle": .string, "nightMode": .bool, "dialogueBoost": .bool,
        "airingAlerts": .string,
        // 1.22.0: Home's library filters. The kids profile's settings are not here (KidsProfile).
        SettingsKey.libraryFilterWatch: .string, SettingsKey.libraryFilterGenre: .string, SettingsKey.libraryFilterYear: .string,
        // 1.22.0: Live Activities, next episodes and watched downloads (Settings → Downloads).
        SettingsKey.liveActivities: .bool, SettingsKey.downloadNextEpisodes: .int, SettingsKey.downloadDeleteWatched: .int,
        // Discover's IMDb settings (review, 5 Nov: left out of presets).
        IMDbSource.Key.language: .string, IMDbSource.Key.minVotes: .int, IMDbSource.Key.animeJapan: .bool,
        // 1.23.0: the search's Files or Posters.
        SettingsKey.searchServerLayout: .string,
        // 1.30.2: the appearance and the notifications' groups, kinds and sounds were left out.
        SettingsKey.appearance: .string, SettingsKey.notifyGroupsOff: .strings, SettingsKey.notifyKindsOff: .strings,
        SettingsKey.notifySounds: .dictionary,
    ]
    /// Never exported: app bookkeeping, not choices. The test switches too
    /// (1.30.2): a preset made with Test on turned it on wherever it was imported.
    /// Keeping the traces on is a test switch as well (1.30.3).
    private static let skip: Set<String> = ["enhancedQuality", SettingsKey.notifyTest, SettingsKey.engageQuick, SettingsKey.diagnosticsKeepOn]

    private static func kind(of v: Any) -> Kind? {
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool }
            return CFNumberIsFloatType(n) ? .double : .int
        }
        if v is String { return .string }
        if v is [String] { return .strings }
        if v is Data { return .data }
        if v is [String: Any] { return .dictionary }
        return nil
    }

    // MARK: Export

    struct Options { var includeSecrets = false }

    /// The preset as JSON (pretty, so it can be read and edited by hand).
    static func export(_ o: Options) throws -> Data {
        let d = UserDefaults.standard
        var settings: [String: Any] = [:]
        for (k, kind) in known {
            guard let v = d.object(forKey: k), let value = encode(v, kind) else { continue }
            settings[k] = value
        }
        var root: [String: Any] = [
            "format": format, "version": version,
            "app": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "created": ISO8601DateFormatter().string(from: Date()),
            "settings": settings,
        ]
        // Addon links usually carry your debrid key: only with passwords and keys.
        if o.includeSecrets, let addons = d.data(forKey: "addons"), let json = try? JSONSerialization.jsonObject(with: addons) { root["addons"] = json }
        root["webdav"] = ServerStore.shared.servers.map { s -> [String: Any] in
            var e: [String: Any] = ["name": s.name, "url": s.baseURL, "username": s.username, "root": s.rootPath]
            if o.includeSecrets, let p = s.password { e["password"] = p }
            return e
        }
        if o.includeSecrets, !TMDB.apiKey.isEmpty { root["secrets"] = ["tmdbApiKey": TMDB.apiKey] }
        root["mpv"] = mpvFiles()
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private static func encode(_ v: Any, _ kind: Kind) -> Any? {
        switch kind {
        case .bool: return (v as? NSNumber)?.boolValue
        case .int: return (v as? NSNumber)?.intValue
        case .double: return (v as? NSNumber)?.doubleValue
        case .string: return v as? String
        case .strings: return v as? [String]
        case .data: return (v as? Data)?.base64EncodedString()
        case .dictionary:
            // Only JSON-safe dictionaries (values of other kinds are dropped).
            guard let dict = v as? [String: Any] else { return nil }
            return dict.compactMapValues { x -> Any? in
                if let data = x as? Data { return ["base64": data.base64EncodedString()] }
                return JSONSerialization.isValidJSONObject([x]) ? x : nil
            }
        }
    }

    /// mpv.conf, input.conf, scripts, script options and shaders (text files
    /// up to 2 MB each); fonts and logs stay out.
    private static func mpvFiles() -> [String: String] {
        var out: [String: String] = [:]
        let base = MPVFiles.configDir.standardizedFileURL.path
        let roots = [MPVFiles.mpvConf, MPVFiles.inputConf, MPVFiles.scriptsDir, MPVFiles.disabledScriptsDir, MPVFiles.scriptOptsDir, MPVFiles.shadersDir]
        let textTypes: Set<String> = ["conf", "lua", "js", "glsl", "hook", "txt", "json"]
        for root in roots {
            var files: [URL] = []
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
                while let u = e?.nextObject() as? URL { files.append(u) }
            } else { files = [root] }
            for u in files {
                let values = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values?.isRegularFile == true, (values?.fileSize ?? 0) <= 2_000_000,
                      textTypes.contains(u.pathExtension.lowercased()), u.lastPathComponent != "README.txt",
                      let text = try? String(contentsOf: u, encoding: .utf8) else { continue }
                let rel = String(u.standardizedFileURL.path.dropFirst(base.count + 1))
                out[rel] = text
            }
        }
        return out
    }

    // MARK: Import

    struct Report {
        var applied = 0
        var skipped: [String] = []
        var addons = 0
        var servers = 0
        var mpvFiles = 0
        var notes: [String] = []
        var summary: String {
            var s = "Imported \(applied) setting\(applied == 1 ? "" : "s")"
            if !skipped.isEmpty { s += ", skipped \(skipped.count) this version doesn't use" }
            s += "."
            var more: [String] = []
            if addons > 0 { more.append("\(addons) addon\(addons == 1 ? "" : "s")") }
            if servers > 0 { more.append("\(servers) server\(servers == 1 ? "" : "s")") }
            if mpvFiles > 0 { more.append("\(mpvFiles) mpv file\(mpvFiles == 1 ? "" : "s")") }
            if !more.isEmpty { s += " Also added: " + more.joined(separator: ", ") + "." }
            if !notes.isEmpty { s += "\n" + notes.joined(separator: "\n") }
            return s
        }
    }

    enum ImportError: LocalizedError {
        case notAPreset
        var errorDescription: String? { "This file isn't a Folio settings preset." }
    }

    /// A preset read but not applied (1.30.4): what it would change, shown
    /// for a yes first. Until then the file picker's answer installed its
    /// mpv scripts, mpv.conf and input.conf, addons and servers at once: a
    /// shared preset could run a Lua script on every playback.
    struct Plan {
        enum FileKind: String { case script, conf, shader }
        struct MPVFile: Equatable { var path: String; var text: String; var kind: FileKind }
        struct Addon: Equatable { var json: Data; var name: String; var host: String; var transportURL: String }
        struct Server: Equatable { var name: String; var url: String; var username: String; var root: String; var password: String? }

        /// Applied as before (name and type checked): every setting but the two below.
        var settings: [String: Any] = [:]
        var skipped: [String] = []
        var newerVersion = false
        var addons: [Addon] = []
        var servers: [Server] = []
        var tmdbKey: String?
        var files: [MPVFile] = []
        /// mpv files outside the places a preset writes (left out).
        var strayFiles: [String] = []
        /// The player's command buttons (mpv commands, as input.conf's): with the conf files.
        var commandButtons: Data?
        /// "Delete watched downloads" turned on or made shorter (deletes files): asked on its own.
        var deleteWatched: Int?

        func filesOf(_ kind: FileKind) -> [MPVFile] { files.filter { $0.kind == kind } }

        /// What goes in. Scripts, conf files and a shorter "Delete watched"
        /// only when ticked: they're off until you say.
        struct Choices: Equatable {
            var addons = true
            var servers = true
            var shaders = true
            var scripts = false
            var conf = false
            var deleteWatched = false

            func allows(_ kind: FileKind) -> Bool {
                switch kind {
                case .script: return scripts
                case .conf: return conf
                case .shader: return shaders
                }
            }
        }
    }

    /// Where a preset's mpv file goes: scripts (anything Lua or JavaScript),
    /// mpv.conf, input.conf and script options, or shaders. Nil: not one of
    /// the places a preset writes, or a path that leaves the mpv folder.
    nonisolated static func fileKind(_ path: String) -> Plan.FileKind? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.hasPrefix("/"), !parts.isEmpty, !parts.contains(".."), !parts.contains(""), !parts.contains(".") else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "lua" || ext == "js" { return .script }
        if parts.count == 1 { return ["mpv.conf", "input.conf"].contains(parts[0]) ? .conf : nil }
        switch parts[0] {
        case "scripts", "scripts-disabled": return .script
        case "script-opts": return .conf
        case "shaders": return .shader
        default: return nil
        }
    }

    /// Reads a preset without changing anything. `known`: the settings this
    /// version has (SettingsPreset.known); `deleteWatchedNow`: the current
    /// "Delete watched downloads", to tell whether the file's would delete more.
    nonisolated static func plan(_ data: Data, known: [String: Kind], deleteWatchedNow: Int) throws -> Plan {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["format"] as? String == format else { throw ImportError.notAPreset }
        var p = Plan()
        if let v = root["version"] as? Int, v > version { p.newerVersion = true }
        for (k, raw) in (root["settings"] as? [String: Any]) ?? [:] {
            guard let kind = known[k], let value = decode(raw, kind) else { p.skipped.append(k); continue }
            if k == SettingsKey.scriptCommands {
                p.commandButtons = value as? Data
            } else if k == SettingsKey.downloadDeleteWatched, let days = value as? Int,
                      WatchedCleanup.asksBeforeDeleting(old: deleteWatchedNow, new: days) {
                p.deleteWatched = days
            } else {
                p.settings[k] = value
            }
        }
        for item in (root["addons"] as? [Any]) ?? [] {
            guard let one = try? JSONSerialization.data(withJSONObject: item),
                  let a = try? JSONDecoder().decode(InstalledAddon.self, from: one) else { continue }
            p.addons.append(.init(json: one, name: a.manifest.name, host: URL(string: a.transportURL)?.host ?? a.transportURL, transportURL: a.transportURL))
        }
        for e in (root["webdav"] as? [[String: Any]]) ?? [] {
            guard let name = e["name"] as? String, let url = e["url"] as? String else { continue }
            p.servers.append(.init(name: name, url: url, username: e["username"] as? String ?? "", root: e["root"] as? String ?? "/",
                                   password: e["password"] as? String))
        }
        if let secrets = root["secrets"] as? [String: Any], let key = secrets["tmdbApiKey"] as? String, !key.isEmpty { p.tmdbKey = key }
        for (rel, text) in ((root["mpv"] as? [String: String]) ?? [:]).sorted(by: { $0.key < $1.key }) {
            if let kind = fileKind(rel) { p.files.append(.init(path: rel, text: text, kind: kind)) } else { p.strayFiles.append(rel) }
        }
        p.skipped.sort()
        return p
    }

    /// The plan, with what you ticked.
    static func apply(_ p: Plan, _ c: Plan.Choices) -> Report {
        var r = Report()
        r.skipped = p.skipped
        if p.newerVersion { r.notes.append("The file is from a newer version of Folio; everything this version knows was imported.") }
        let d = UserDefaults.standard
        for (k, v) in p.settings { d.set(v, forKey: k); r.applied += 1 }
        if c.conf, let b = p.commandButtons { d.set(b, forKey: SettingsKey.scriptCommands); r.applied += 1 }
        if c.deleteWatched, let days = p.deleteWatched { d.set(days, forKey: SettingsKey.downloadDeleteWatched); r.applied += 1 }
        // Addons: added if not already installed (by address); existing ones stay.
        if c.addons, !p.addons.isEmpty {
            let list = p.addons.compactMap { try? JSONSerialization.jsonObject(with: $0.json) }
            if let json = try? JSONSerialization.data(withJSONObject: list) { r.addons = AddonStore.shared.merge(json) }
        }
        if c.servers {
            for e in p.servers {
                if ServerStore.shared.servers.contains(where: { $0.baseURL == e.url && $0.username == e.username }) { continue }
                let s = WebDAVServer(name: e.name, baseURL: e.url, username: e.username, rootPath: e.root)
                if let pw = e.password { s.password = pw }
                ServerStore.shared.upsert(s)
                r.servers += 1
            }
        }
        if let key = p.tmdbKey, TMDB.apiKey.isEmpty { TMDB.apiKey = key }
        let base = MPVFiles.configDir.standardizedFileURL
        var left: [Plan.FileKind: Int] = [:]
        for f in p.files {
            guard c.allows(f.kind) else { left[f.kind, default: 0] += 1; continue }
            let dest = base.appendingPathComponent(f.path).standardizedFileURL
            // Stay inside the mpv folder, whatever the file says.
            guard dest.path.hasPrefix(base.path + "/") else { continue }
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? f.text.write(to: dest, atomically: true, encoding: .utf8)) != nil { r.mpvFiles += 1 }
        }
        var out: [String] = []
        if let n = left[.script] { out.append("\(n) script\(n == 1 ? "" : "s")") }
        if let n = left[.conf] { out.append("\(n) mpv setting file\(n == 1 ? "" : "s")") }
        if let n = left[.shader] { out.append("\(n) shader\(n == 1 ? "" : "s")") }
        if !c.conf, p.commandButtons != nil { out.append("the player's command buttons") }
        if !c.deleteWatched, p.deleteWatched != nil { out.append("Delete watched downloads") }
        if !c.addons, !p.addons.isEmpty { out.append("\(p.addons.count) addon\(p.addons.count == 1 ? "" : "s")") }
        if !c.servers, !p.servers.isEmpty { out.append("\(p.servers.count) server\(p.servers.count == 1 ? "" : "s")") }
        if !out.isEmpty { r.notes.append("Left out: " + out.joined(separator: ", ") + ".") }
        dlog("app", "preset imported: \(r.applied) settings, skipped \(r.skipped), addons +\(r.addons), servers +\(r.servers), mpv files \(r.mpvFiles), left out \(out)")
        return r
    }

    nonisolated private static func decode(_ v: Any, _ kind: Kind) -> Any? {
        switch kind {
        case .bool:
            guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
            return n.boolValue
        case .int:
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == n.doubleValue.rounded() else { return nil }
            return n.intValue
        case .double:
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return n.doubleValue
        case .string: return v as? String
        case .strings: return v as? [String]
        case .data: return (v as? String).flatMap { Data(base64Encoded: $0) }
        case .dictionary:
            guard let dict = v as? [String: Any] else { return nil }
            return dict.compactMapValues { x -> Any? in
                if let b = x as? [String: Any], let s = b["base64"] as? String, b.count == 1, let data = Data(base64Encoded: s) { return data }
                return propertyList(x)
            }
        }
    }

    /// A JSON value as UserDefaults can keep it. A null anywhere inside a
    /// dictionary setting (an edited file) made `set` throw and the import
    /// crash; nulls are now left out, however deep.
    nonisolated private static func propertyList(_ x: Any) -> Any? {
        switch x {
        case is NSNull: return nil
        case let dict as [String: Any]: return dict.compactMapValues(propertyList)
        case let list as [Any]: return list.compactMap(propertyList)
        default: return x
        }
    }

    /// A file name for the export: "Folio settings 2026-10-26.json".
    static var fileName: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return "Folio settings \(f.string(from: Date())).json"
    }
}

/// Settings → Presets.
struct PresetsView: View {
    @State private var includeSecrets = false
    @State private var exportURL: URL?
    @State private var importing = false
    /// A file read and waiting for your yes, with what it would add (1.30.4).
    @State private var review: PresetReview?
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Toggle("Include passwords and keys", isOn: $includeSecrets)
                Button { makeExport() } label: { Label("Save Settings to a File…", systemImage: "square.and.arrow.up") }
            } header: { Text("Save") } footer: {
                Text("Saves every setting, your WebDAV servers and your mpv files (mpv.conf, input.conf, scripts, script options, shaders) in one file. With passwords and keys on, it also has your server passwords, your TMDB key and your addons (addon links usually contain your debrid key) — anyone with the file can read them.")
            }
            Section {
                // What the file adds is shown before anything changes (1.30.4):
                // scripts and mpv's own files only when you tick them.
                Button { importing = true } label: { Label("Load Settings from a File…", systemImage: "square.and.arrow.down") }
            } header: { Text("Load") } footer: {
                Text("Settings in the file replace yours; anything the file doesn't have stays as it is. Addons and servers are added next to the ones you have. You see what the file adds first: its mpv scripts, mpv.conf and input.conf are installed only if you tick them. Settings an older or newer version of Folio had that this one doesn't use are skipped, not an error.")
            }
        }
        .brandListBackground()
        .navigationTitle("Import & Export")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(get: { exportURL.map(ShareURL.init) }, set: { exportURL = $0?.url })) { s in
            ShareSheet(items: [s.url])
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data]) { result in
            switch result {
            case .success(let url): load(url)
            case .failure(let e): error = e.localizedDescription
            }
        }
        .sheet(item: $review) { r in
            PresetReviewView(plan: r.plan) { choices in
                review = nil
                let summary = SettingsPreset.apply(r.plan, choices).summary
                // Once the sheet has gone: an alert asked for while it closes isn't shown.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { message = summary }
            }
        }
        .alert("Settings loaded", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
        .alert("Couldn't load the file", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func makeExport() {
        do {
            let data = try SettingsPreset.export(.init(includeSecrets: includeSecrets))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(SettingsPreset.fileName)
            try data.write(to: url, options: .atomic)
            exportURL = url
        } catch { self.error = error.localizedDescription }
    }

    private func load(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let now = UserDefaults.standard.integer(forKey: SettingsKey.downloadDeleteWatched)
            let next = PresetReview(plan: try SettingsPreset.plan(data, known: SettingsPreset.known, deleteWatchedNow: now))
            // After the file picker has closed: a sheet asked for while it closes isn't shown.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { review = next }
        } catch { self.error = error.localizedDescription }
    }

    private struct ShareURL: Identifiable { let url: URL; var id: String { url.path } }
    private struct PresetReview: Identifiable { let id = UUID(); let plan: SettingsPreset.Plan }
}

/// What a preset adds, before anything changes (1.30.4). Settings apply as
/// they are; addons, servers and shaders are ticked; scripts, mpv.conf,
/// input.conf, script options, the command buttons and a shorter "Delete
/// watched downloads" are not, until you tick them.
private struct PresetReviewView: View {
    let plan: SettingsPreset.Plan
    let onImport: (SettingsPreset.Plan.Choices) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var choices = SettingsPreset.Plan.Choices()

    private func count(_ n: Int, _ one: String) -> String { "\(n) \(one)\(n == 1 ? "" : "s")" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Settings", value: "\(plan.settings.count)")
                    if plan.tmdbKey != nil { LabeledContent("TMDB key", value: TMDB.apiKey.isEmpty ? "Added" : "Yours kept") }
                } footer: {
                    Text("These replace yours." + (plan.skipped.isEmpty ? "" : " \(count(plan.skipped.count, "setting")) this version doesn't use are skipped."))
                }
                if !plan.addons.isEmpty {
                    Section {
                        Toggle("Add \(count(plan.addons.count, "addon"))", isOn: $choices.addons)
                        ForEach(Array(plan.addons.enumerated()), id: \.offset) { _, a in LabeledContent(a.name, value: a.host) }
                    } footer: { Text("Addons are asked for catalogs and streams; their links usually carry a debrid key. Ones you have already stay as they are.") }
                }
                if !plan.servers.isEmpty {
                    Section {
                        Toggle("Add \(count(plan.servers.count, "server"))", isOn: $choices.servers)
                        ForEach(Array(plan.servers.enumerated()), id: \.offset) { _, s in
                            LabeledContent(s.name, value: URL(string: s.url)?.host ?? s.url)
                        }
                    }
                }
                fileSection(.shader, title: "Install \(count(plan.filesOf(.shader).count, "shader"))", isOn: $choices.shaders,
                            note: "GPU shaders for the picture, used only when you pick them.")
                fileSection(.script, title: "Install \(count(plan.filesOf(.script).count, "mpv script"))", isOn: $choices.scripts,
                            note: "A script runs on every playback and can do anything mpv can. Tick this only for scripts you wrote or trust.")
                if !plan.filesOf(.conf).isEmpty || plan.commandButtons != nil {
                    Section {
                        Toggle("Replace mpv's settings files", isOn: $choices.conf)
                        ForEach(plan.filesOf(.conf), id: \.path) { f in Text(f.path).font(.footnote.monospaced()) }
                        if plan.commandButtons != nil { Text("The player's command buttons").font(.footnote) }
                    } footer: {
                        Text("mpv.conf, input.conf and script options decide what mpv does and what keys and buttons run; mpv.conf can load scripts of its own. Tick this only for a file you made or trust.")
                    }
                }
                if let days = plan.deleteWatched {
                    Section {
                        Toggle(days == 1 ? "Delete watched downloads after 1 day" : "Delete watched downloads after \(days) days", isOn: $choices.deleteWatched)
                    } footer: {
                        Text("Downloaded videos you finished longer ago than that are deleted at once. Files you added yourself are never deleted.")
                    }
                }
                if !plan.strayFiles.isEmpty {
                    Section {
                        ForEach(plan.strayFiles, id: \.self) { Text($0).font(.footnote.monospaced()) }
                    } footer: { Text("Not in a place mpv's files go: left out.") }
                }
            }
            .brandListBackground()
            .navigationTitle("Load Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Load") { onImport(choices) } }
            }
        }
    }

    @ViewBuilder
    private func fileSection(_ kind: SettingsPreset.Plan.FileKind, title: String, isOn: Binding<Bool>, note: String) -> some View {
        let files = plan.filesOf(kind)
        if !files.isEmpty {
            Section {
                Toggle(title, isOn: isOn)
                ForEach(files, id: \.path) { f in Text(f.path).font(.footnote.monospaced()) }
            } footer: { Text(note) }
        }
    }
}

/// The system share sheet (Save to Files, AirDrop…).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
