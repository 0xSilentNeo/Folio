import Foundation

/// Layout of the user-visible mpv config folder (Files app → GlassPlayer → mpv).
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

    private static func seed(_ dest: URL, resource: String) {
        guard !fm.fileExists(atPath: dest.path) else { return }
        if let src = Bundle.main.url(forResource: resource, withExtension: nil, subdirectory: "defaults") {
            try? fm.copyItem(at: src, to: dest)
        }
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
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: src, to: dest)
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
        let name = filename ?? url.lastPathComponent
        let dest = dir.appendingPathComponent(name)
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

    static func writeText(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
