import Foundation

/// Claude Code sessions that are open, from the list Claude Code keeps of them: a
/// `~/.claude/sessions/<pid>.json` for each one running. Hooks only tell about a session once something
/// happens in it, so one opened and left waiting for a task, or one that finished a while ago, is found
/// here. Read when the card opens, and by `ClaudeCodeWatcher` when sessions come and go.
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
        (records(in: dir) ?? []).compactMap { json, pid in
            guard let id = json["sessionId"] as? String, !id.isEmpty,
                  (json["status"] as? String ?? "idle") == "idle" else { return nil }
            let started = startedAt(json)
            guard isRunning(pid, since: started) else { return nil }
            return Open(id: id, cwd: json["cwd"] as? String ?? "", name: json["name"] as? String ?? "",
                        entrypoint: json["entrypoint"] as? String ?? "", started: started)
        }
    }

    /// The processes of the sessions that run now, at work or not; nil when there's no list to tell from
    /// (Claude Code has never run, or is from before it kept one).
    static func running(in dir: String = dir) -> [pid_t]? {
        records(in: dir)?.compactMap { json, pid in isRunning(pid, since: startedAt(json)) ? pid : nil }
    }

    /// Each session file with the process it names.
    private static func records(in dir: String) -> [(json: [String: Any], pid: pid_t)]? {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        return files.filter { $0.hasSuffix(".json") }.compactMap { file in
            guard let data = FileManager.default.contents(atPath: dir + "/" + file),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let pid = (json["pid"] as? NSNumber)?.int32Value else { return nil }
            return (json, pid)
        }
    }

    private static func startedAt(_ json: [String: Any]) -> Date? {
        (json["startedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    }

    /// The process is there, ours or not, and is the one the file was written for: a file left behind by
    /// a crash names one that's gone, or by now another process that was given its number, which started
    /// after the session did.
    private static func isRunning(_ pid: pid_t, since started: Date?) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard let started, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return true }
        return TimeInterval(info.pbi_start_tvsec) <= started.timeIntervalSince1970 + 1
    }
}
