import Foundation

/// The hooks in ~/.claude/settings.json that make Claude Code tell the app what it does. The app adds
/// them itself when it's installed from the disk image; install-hooks.sh adds the same ones for an
/// install from source. Keep the two lists alike (a test checks).
enum ClaudeHooks {
    /// event → (matcher, timeout in seconds)
    static let events: [String: (matcher: String?, timeout: Int)] = [
        "SessionStart": (nil, 3),  // also starts the app if it isn't running
        "UserPromptSubmit": (nil, 3),
        "PreToolUse": ("*", 3),
        "PostToolUse": ("*", 3),
        "PostToolUseFailure": ("*", 3),
        "PermissionRequest": ("*", 600),  // waits for a click in the notch
        "PermissionDenied": ("*", 3),
        "Notification": (nil, 3),
        "Elicitation": (nil, 3),
        "ElicitationResult": (nil, 3),
        "PreCompact": (nil, 3),
        "PostCompact": (nil, 3),
        "Stop": (nil, 3),
        "StopFailure": (nil, 3),
        "SessionEnd": (nil, 3),
        "SubagentStart": (nil, 3),
        "SubagentStop": (nil, 3),
    ]

    enum State: Equatable {
        /// Every hook is there and runs this copy of the app.
        case connected
        /// Some are missing, or they run another copy (the app was moved, or a newer one adds events).
        case outdated
        case missing
    }

    enum Failure: LocalizedError {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let why):
                return tr("Не получилось прочитать ~/.claude/settings.json: \(why). Файл не тронут.",
                          "Couldn't read ~/.claude/settings.json: \(why). The file is left as it was.")
            }
        }
    }

    static var settingsURL: URL {
        if let path = ProcessInfo.processInfo.environment["CLAUDE_SETTINGS"], !path.isEmpty {  // like install-hooks.sh
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// The hook binary inside this copy of the app.
    static var hookPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/claude-notch-hook").path
    }

    /// Claude Code runs the command through a shell: a path with spaces needs quotes. With the app
    /// gone (put in the Trash while it wasn't running, so it couldn't take its hooks out) the hook
    /// quietly does nothing, rather than Claude Code reporting a missing file at every step.
    static func command(for hook: String) -> String {
        let path = hook.contains(" ") ? "\"\(hook)\"" : hook
        return "[ ! -x \(path) ] || \(path)"
    }

    static func state(settings: URL = settingsURL, hook: String = hookPath) -> State {
        guard let hooks = (try? read(settings))?["hooks"] as? [String: Any] else { return .missing }
        var found = false
        var complete = true
        for event in Set(hooks.keys).union(events.keys) {
            let ours = (hooks[event] as? [[String: Any]] ?? []).flatMap(commands).filter(isOurs)
            found = found || !ours.isEmpty
            if events[event] != nil, ours != [command(for: hook)] { complete = false }
            if events[event] == nil, !ours.isEmpty { complete = false }
        }
        return !found ? .missing : complete ? .connected : .outdated
    }

    /// Adds this copy's hooks, replacing any of ours that were there. Other settings and hooks stay;
    /// the first time, the original file is saved next to it.
    static func connect(settings: URL = settingsURL, hook: String = hookPath) throws {
        try update(settings) { hooks in
            for (event, spec) in events {
                var group: [String: Any] = ["hooks": [["type": "command", "command": command(for: hook), "timeout": spec.timeout]]]
                if let matcher = spec.matcher { group["matcher"] = matcher }
                hooks[event] = (hooks[event] ?? []) + [group]
            }
        }
    }

    static func disconnect(settings: URL = settingsURL) throws {
        guard FileManager.default.fileExists(atPath: settings.path) else { return }
        try update(settings) { _ in }
    }

    // MARK: -

    private static func isOurs(_ command: String) -> Bool { command.contains("claude-notch-hook") }

    private static func commands(_ group: [String: Any]) -> [String] {
        (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
    }

    private static func read(_ settings: URL) throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: settings.path) else { return [:] }  // no file yet
        if data.allSatisfy({ " \n\r\t".utf8.contains($0) }) { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data), let settings = object as? [String: Any] else {
            throw Failure.unreadable(tr("это не JSON-объект", "it isn't a JSON object"))
        }
        return settings
    }

    /// Takes our hooks out of every event, lets `add` put this copy's back, and writes the file:
    /// through a symlink to where it points, and atomically, so Claude Code never reads half a file.
    /// Groups without ours, and anything that isn't a list of groups, stay exactly as they were.
    private static func update(_ url: URL, add: (inout [String: [[String: Any]]]) -> Void) throws {
        let fm = FileManager.default
        let target = url.resolvingSymlinksInPath()
        var settings = try read(target)
        var raw = settings["hooks"] as? [String: Any] ?? [:]
        var lists: [String: [[String: Any]]] = [:]
        for (event, value) in raw {
            guard let groups = value as? [[String: Any]] else { continue }
            lists[event] = groups.compactMap { group in
                let entries = group["hooks"] as? [[String: Any]] ?? []
                guard entries.contains(where: { isOurs($0["command"] as? String ?? "") }) else { return group }
                let rest = entries.filter { !isOurs($0["command"] as? String ?? "") }
                if rest.isEmpty { return nil }
                var group = group
                group["hooks"] = rest
                return group
            }
        }
        add(&lists)
        for (event, groups) in lists { raw[event] = groups.isEmpty ? nil : groups }
        settings["hooks"] = raw.isEmpty ? nil : raw

        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = URL(fileURLWithPath: url.path + ".bak-claudenotch")
        if !fm.fileExists(atPath: backup.path) {  // only once, like install-hooks.sh: later runs would save our own edits
            if fm.fileExists(atPath: target.path) { try fm.copyItem(at: target, to: backup) } else { try Data("{}\n".utf8).write(to: backup) }
        }
        var data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(Data("\n".utf8))
        try data.write(to: target, options: .atomic)
    }
}
