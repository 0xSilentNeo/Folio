import Foundation
import CryptoKit

/// Layout of the user-visible mpv config folder (Files app → Folio → mpv).
///
///   mpv/mpv.conf            options, loaded at startup (config-dir)
///   mpv/input.conf          key bindings (hardware keyboards)
///   mpv/scripts/            Lua scripts, auto-loaded
///   mpv/scripts-disabled/   scripts switched off in the app
///   mpv/script-opts/        <script>.conf option files
///   mpv/shaders/            .glsl / .hook user shaders
///   mpv/fonts/              extra subtitle fonts
///   mpv/logs/last.log       log of the most recent playback session
enum MPVFiles {
    static let fm = FileManager.default

    static var documents: URL { fm.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var configDir: URL { documents.appendingPathComponent("mpv", isDirectory: true) }
    static var scriptsDir: URL { configDir.appendingPathComponent("scripts", isDirectory: true) }
    static var disabledScriptsDir: URL { configDir.appendingPathComponent("scripts-disabled", isDirectory: true) }
    static var scriptOptsDir: URL { configDir.appendingPathComponent("script-opts", isDirectory: true) }
    static var shadersDir: URL { configDir.appendingPathComponent("shaders", isDirectory: true) }
    static var fontsDir: URL { configDir.appendingPathComponent("fonts", isDirectory: true) }
    static var logsDir: URL { configDir.appendingPathComponent("logs", isDirectory: true) }
    static var logFile: URL { logsDir.appendingPathComponent("last.log") }
    static var mpvConf: URL { configDir.appendingPathComponent("mpv.conf") }
    static var inputConf: URL { configDir.appendingPathComponent("input.conf") }
    static var mediaDir: URL { documents.appendingPathComponent("Media", isDirectory: true) }
    static var screenshotsDir: URL { documents.appendingPathComponent("Screenshots", isDirectory: true) }
    static var watchLaterDir: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("watch_later", isDirectory: true)
    }

    static func bootstrap() {
        for dir in [configDir, scriptsDir, disabledScriptsDir, scriptOptsDir, shadersDir, fontsDir, logsDir, mediaDir, screenshotsDir, watchLaterDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        seed(mpvConf, resource: "mpv.conf")
        seed(inputConf, resource: "input.conf")
        seed(scriptsDir.appendingPathComponent("README.txt"), resource: "scripts-README.txt")
        seed(shadersDir.appendingPathComponent("README.txt"), resource: "shaders-README.txt")
    }

    /// Every earlier version of the bundled files (SHA-256), from the repo's
    /// history. A file still exactly like one of them was never edited, so
    /// it's replaced by this version's, which explains much more (1.21.0).
    /// A file you've changed is never touched.
    private static let earlierDefaults: [String: Set<String>] = [
        "mpv.conf": ["298e8b217b4f9ffad7628cf84910c67439c3939b445363efc377579597536f18",
                     "6391e027cf25facde9b29ec76d149cb1191c5f60332f30f23c9e9ebb655a38d4"],
        "input.conf": ["4fec4304d8b6a07682af8086b3ff1da430935a0cbd80ef7df01cef3fd88a2369",
                       "abb4dff70e168635a87e40f4ebc45bdadd58f5f93e90f673359294e8e12645b9"],
        "scripts-README.txt": ["768eb8f9234d06bc9e3d0053efa8935d9a608b96ce00f7a0d442672650c9bc79",
                               "8a839949cd5c7abe69dc359ebed549f2986b1bfbefa529c072179a1fa9372329"],
        "shaders-README.txt": ["120a647776251ba668f66023ac1594aad63b127bb48d7723023aae88ed8f1d5f",
                               "926da425c3463f609756c43b6c70ff60a9e622f6ec6d777b6b199f58fa611404",
                               "e1e777b71eee4b8627b29210542a369ef0883948b44c695e805eb6888fa6ef38"],
    ]

    private static func seed(_ dest: URL, resource: String) {
        guard let src = Bundle.main.url(forResource: resource, withExtension: nil, subdirectory: "defaults") else { return }
        if let current = try? Data(contentsOf: dest) {
            let hash = SHA256.hash(data: current).map { String(format: "%02x", $0) }.joined()
            guard earlierDefaults[resource]?.contains(hash) == true, let fresh = try? Data(contentsOf: src) else { return }
            if (try? fresh.write(to: dest, options: .atomic)) != nil { dlog("mpv", "\(resource): the unedited earlier default was updated") }
            return
        }
        try? fm.copyItem(at: src, to: dest)
    }

    // MARK: Scripts

    struct Script: Identifiable, Hashable {
        var id: String { url.path }
        let name: String
        let url: URL
        let isDirectory: Bool
        let enabled: Bool
    }

    static func isScript(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        if isDir.boolValue {
            return fm.fileExists(atPath: url.appendingPathComponent("main.lua").path)
        }
        return url.pathExtension.lowercased() == "lua"
    }

    static func scripts() -> [Script] {
        func list(_ dir: URL, enabled: Bool) -> [Script] {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            return items.filter(isScript).map { url in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return Script(name: url.lastPathComponent, url: url, isDirectory: isDir == true, enabled: enabled)
            }
        }
        return (list(scriptsDir, enabled: true) + list(disabledScriptsDir, enabled: false))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func setEnabled(_ script: Script, _ enabled: Bool) throws {
        guard script.enabled != enabled else { return }
        let destDir = enabled ? scriptsDir : disabledScriptsDir
        let dest = destDir.appendingPathComponent(script.url.lastPathComponent)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: script.url, to: dest)
    }

    static func importItem(from src: URL, into dir: URL) throws -> URL {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        let dest = dir.appendingPathComponent(src.lastPathComponent)
        // Copied beside it under another name first (1.30.2): the file already
        // there was deleted before the copy, and lost when the copy failed.
        // (A hidden name with no .lua: mpv and the lists here pass it over.)
        let tmp = dir.appendingPathComponent(".import-\(UUID().uuidString).tmp")
        do {
            try fm.copyItem(at: src, to: tmp)
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: dest)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        return dest
    }

    static func download(_ remote: URL, into dir: URL, filename: String? = nil) async throws -> URL {
        var url = remote
        // github.com/<u>/<r>/blob/<branch>/<path> -> raw
        if url.host == "github.com", url.path.contains("/blob/") {
            let raw = "https://raw.githubusercontent.com" + url.path.replacingOccurrences(of: "/blob/", with: "/")
            url = URL(string: raw) ?? url
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        // Only the last part of the name, whatever the link decodes to: a
        // "..%2F" in it used to step outside the folder.
        let raw = (filename ?? url.lastPathComponent).replacingOccurrences(of: "\\", with: "/")
        let name = raw.split(separator: "/").last.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix(".") else { throw URLError(.cannotCreateFile) }
        let dest = dir.appendingPathComponent(name)
        guard dest.standardizedFileURL.deletingLastPathComponent().path == dir.standardizedFileURL.path else { throw URLError(.cannotCreateFile) }
        try data.write(to: dest, options: .atomic)
        return dest
    }

    static func scriptOptFiles() -> [URL] {
        ((try? fm.contentsOfDirectory(at: scriptOptsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "conf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Shaders

    static func shaders() -> [URL] {
        ((try? fm.contentsOfDirectory(at: shadersDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["glsl", "hook"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// The shaders, listed again at most every two seconds (1.24.1): the
    /// player's settings panel asked four times a redraw, and redraws on
    /// every control change while open (6 Nov report: 78–88 ms taps).
    @MainActor static func shadersRecent() -> [URL] {
        if let c = shaderMemo, Date().timeIntervalSince(c.at) < 2 { return c.list }
        let list = shaders()
        shaderMemo = (Date(), list)
        return list
    }
    @MainActor private static var shaderMemo: (at: Date, list: [URL])?

    /// Active shader file names, in order.
    static var activeShaderNames: [String] {
        get { UserDefaults.standard.stringArray(forKey: SettingsKey.activeShaders) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKey.activeShaders) }
    }

    static var activeShaderPaths: [String] {
        let existing = Set(shaders().map { $0.lastPathComponent })
        return activeShaderNames.filter { existing.contains($0) }.map { shadersDir.appendingPathComponent($0).path }
    }

    static func readText(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// For the editor: "" for a file that isn't there yet, nil for one that
    /// exists but isn't UTF-8 text. readText gives "" for both, and the editor
    /// then saved that "" over a Latin-1 input.conf or .lua (review, 2 Nov).
    static func readEditableText(_ url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func writeText(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
