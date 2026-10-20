import Foundation

enum Paths {
    static let home = getenv("HOME").map { String(cString: $0) } ?? NSHomeDirectory()
    static let dir = home + "/Library/Application Support/ClaudeNotch"
    static let socket = dir + "/notch.sock"
    static let eventLog = dir + "/events.log"
}
