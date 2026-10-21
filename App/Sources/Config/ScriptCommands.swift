import Foundation

/// User-defined buttons that run an mpv command (input.conf syntax), e.g.
/// "script-binding stats/display-stats-toggle". This is how touch users
/// trigger script key bindings without a keyboard.
struct ScriptCommand: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var command: String
}

enum ScriptCommandStore {
    static let defaults: [ScriptCommand] = [
        ScriptCommand(name: "Cycle deband", command: "cycle deband"),
        ScriptCommand(name: "Show playlist", command: "show-text ${playlist} 4000"),
        ScriptCommand(name: "Cycle subtitle style", command: "cycle-values sub-ass-override force yes"),
        ScriptCommand(name: "Frame step", command: "frame-step"),
    ]

    static var all: [ScriptCommand] {
        get {
            guard let data = UserDefaults.standard.data(forKey: SettingsKey.scriptCommands),
                  let list = try? JSONDecoder().decode([ScriptCommand].self, from: data) else { return defaults }
            // mpv's stats.lua overlay is disabled (the app has a live stats card);
            // drop the entry older versions saved for it.
            return list.filter { !$0.command.contains("stats/display-stats") }
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: SettingsKey.scriptCommands)
        }
    }
}
