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
    static let format = "folio-preset"
    static let version = 1

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
        SettingsKey.folderSorts: .dictionary, SettingsKey.menuRelay: .bool,
        "libraryView": .string, "librarySort": .string, "librarySortAsc": .bool, "heroView": .string,
        "screenshotSubs": .bool, "discoverRegion": .string, "discoverPlatforms": .strings,
        "seekMarkerStyle": .string, "seekMarkerColor": .string, "seekShowChapterTitle": .bool, "seekShowSkip": .bool,
    ]
    /// Never exported: app bookkeeping, not choices.
    private static let skip: Set<String> = ["enhancedQuality"]

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

    static func importPreset(_ data: Data) throws -> Report {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["format"] as? String == format else { throw ImportError.notAPreset }
        var r = Report()
        if let v = root["version"] as? Int, v > version {
            r.notes.append("The file is from a newer version of Folio; everything this version knows was imported.")
        }
        let d = UserDefaults.standard
        let known = self.known
        for (k, raw) in (root["settings"] as? [String: Any]) ?? [:] {
            guard let kind = known[k], let value = decode(raw, kind) else { r.skipped.append(k); continue }
            d.set(value, forKey: k)
            r.applied += 1
        }
        // Addons: added if not already installed (by address); existing ones stay.
        if let list = root["addons"], let json = try? JSONSerialization.data(withJSONObject: list) {
            r.addons = AddonStore.shared.merge(json)
        }
        if let servers = root["webdav"] as? [[String: Any]] {
            for e in servers {
                guard let name = e["name"] as? String, let url = e["url"] as? String else { continue }
                if ServerStore.shared.servers.contains(where: { $0.baseURL == url && $0.username == (e["username"] as? String ?? "") }) { continue }
                let s = WebDAVServer(name: name, baseURL: url, username: e["username"] as? String ?? "", rootPath: e["root"] as? String ?? "/")
                if let p = e["password"] as? String { s.password = p }
                ServerStore.shared.upsert(s)
                r.servers += 1
            }
        }
        if let secrets = root["secrets"] as? [String: Any], let key = secrets["tmdbApiKey"] as? String, !key.isEmpty, TMDB.apiKey.isEmpty {
            TMDB.apiKey = key
        }
        if let files = root["mpv"] as? [String: String] {
            let base = MPVFiles.configDir.standardizedFileURL
            for (rel, text) in files {
                let dest = base.appendingPathComponent(rel).standardizedFileURL
                // Stay inside the mpv folder, whatever the file says.
                guard dest.path.hasPrefix(base.path + "/"), !rel.contains("..") else { continue }
                try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? text.write(to: dest, atomically: true, encoding: .utf8)) != nil { r.mpvFiles += 1 }
            }
        }
        dlog("app", "preset imported: \(r.applied) settings, skipped \(r.skipped), addons +\(r.addons), servers +\(r.servers), mpv files \(r.mpvFiles)")
        return r
    }

    private static func decode(_ v: Any, _ kind: Kind) -> Any? {
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
            return dict.mapValues { x -> Any in
                if let b = x as? [String: Any], let s = b["base64"] as? String, b.count == 1, let data = Data(base64Encoded: s) { return data }
                return x
            }
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
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Toggle("Include passwords and keys", isOn: $includeSecrets)
                Button { makeExport() } label: { Label("Save settings to a file…", systemImage: "square.and.arrow.up") }
            } header: { Text("Save") } footer: {
                Text("Saves every setting, your WebDAV servers and your mpv files (mpv.conf, input.conf, scripts, script options, shaders) in one file. With passwords and keys on, it also has your server passwords, your TMDB key and your addons (addon links usually contain your debrid key) — anyone with the file can read them.")
            }
            Section {
                Button { importing = true } label: { Label("Load settings from a file…", systemImage: "square.and.arrow.down") }
            } header: { Text("Load") } footer: {
                Text("Settings in the file replace yours; anything the file doesn't have stays as it is. Addons and servers are added next to the ones you have. Settings an older or newer version of Folio had that this one doesn't use are skipped, not an error.")
            }
        }
        .brandListBackground()
        .navigationTitle("Presets")
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
            message = try SettingsPreset.importPreset(data).summary
        } catch { self.error = error.localizedDescription }
    }

    private struct ShareURL: Identifiable { let url: URL; var id: String { url.path } }
}

/// The system share sheet (Save to Files, AirDrop…).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
