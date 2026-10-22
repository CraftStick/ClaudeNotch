import Foundation

/// Claude Code sessions that are open, from the list Claude Code keeps of them: a
/// `~/.claude/sessions/<pid>.json` for each one running. Hooks only tell about a session once something
/// happens in it, so one opened and left waiting for a task, or one that finished a while ago, is found
/// here. Only read, and only when the card opens: nothing runs for it in between.
enum SessionRegistry {
    struct Open: Equatable {
        var id: String
        var cwd: String
        /// The session's title, when Claude Code has given it one.
        var name: String
        /// Like CLAUDE_CODE_ENTRYPOINT: "cli" in a terminal, "claude-desktop" in the Claude app…
        var entrypoint: String
        var started: Date?
    }

    static let dir = Paths.home + "/.claude/sessions"

    /// The sessions whose process still runs and which aren't at work: Claude Code says "idle" for
    /// those. One at work tells about itself through the hooks.
    static func open(in dir: String = dir) -> [Open] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files.filter { $0.hasSuffix(".json") }.compactMap { file in
            guard let data = FileManager.default.contents(atPath: dir + "/" + file),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = json["sessionId"] as? String, !id.isEmpty,
                  let pid = (json["pid"] as? NSNumber)?.int32Value, isRunning(pid),
                  (json["status"] as? String ?? "idle") == "idle"
            else { return nil }
            return Open(id: id, cwd: json["cwd"] as? String ?? "", name: json["name"] as? String ?? "",
                        entrypoint: json["entrypoint"] as? String ?? "",
                        started: (json["startedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) })
        }
    }

    /// The process is there, ours or not: a file left behind by a crash names one that's gone.
    private static func isRunning(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }
}
