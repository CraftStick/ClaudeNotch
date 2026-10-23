import Foundation

enum Paths {
    static let home = getenv("HOME").map { String(cString: $0) } ?? NSHomeDirectory()
    static let dir = home + "/Library/Application Support/ClaudeNotch"
    static let socket = dir + "/notch.sock"
    static let eventLog = dir + "/events.log"
    /// Where URLSession.shared keeps its cache and cookies for the app. Versions up to 0.1.9 left every
    /// request there, headers and all, the Claude Code login among them; the app no longer writes there
    /// (`URLSession.uncached`) and clears what's left at launch.
    static let httpStorage = ["Library/Caches", "Library/HTTPStorages"]
        .map { "\(home)/\($0)/\(Bundle.main.bundleIdentifier ?? "local.claudenotch")" }
}
