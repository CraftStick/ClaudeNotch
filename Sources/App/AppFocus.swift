import AppKit

/// Brings the app a session runs in to the front when you click the notch.
enum AppFocus {
    /// Editors that switch to the window of a folder when asked to open it.
    private static let folderEditors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.exafunction.windsurf", "dev.zed.Zed",
    ]

    /// The hook reports `__CFBundleIdentifier` (the app that launched Claude Code) and
    /// `TERM_PROGRAM`; the bundle id is the more precise of the two.
    static func host(bundleID: String, termProgram: String) -> String? {
        if !bundleID.isEmpty { return bundleID }
        switch termProgram {
        case "Apple_Terminal": return "com.apple.Terminal"
        case "iTerm.app": return "com.googlecode.iterm2"
        case "vscode": return "com.microsoft.VSCode"
        case "WarpTerminal": return "dev.warp.Warp-Stable"
        case "ghostty": return "com.mitchellh.ghostty"
        default: return nil
        }
    }

    /// The app Claude Code last ran in, remembered across launches.
    static var lastHost: String? {
        get { UserDefaults.standard.string(forKey: "lastHost") }
        set { UserDefaults.standard.set(newValue, forKey: "lastHost") }
    }

    /// What the greeting opens: the app Claude Code last ran in, else the Claude app, else Terminal.
    static var claudeApp: URL? {
        [lastHost, claudeBundleID, "com.apple.Terminal"].lazy
            .compactMap { $0.flatMap(NSWorkspace.shared.urlForApplication(withBundleIdentifier:)) }
            .first
    }

    static func show(host: String?, folder: String) {
        guard let host, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: host) else { return }
        if folderEditors.contains(host), let root = workspaceRoot(of: folder) {
            NSWorkspace.shared.open([root], withApplicationAt: app, configuration: activating)
        } else {
            open(app)
        }
    }

    /// Opened through Launch Services: an app that isn't active itself (we never are) can't
    /// reliably activate another one directly on recent macOS.
    static func open(_ app: URL) {
        NSWorkspace.shared.openApplication(at: app, configuration: activating)
    }

    static let claudeBundleID = "com.anthropic.claudefordesktop"

    /// Opens a session that runs in the Claude app at that very session, not just the app.
    /// False when the app keeps no record of it.
    static func openInClaudeApp(_ sessionID: String) -> Bool {
        guard let local = claudeAppSession(for: sessionID),
              let url = URL(string: "claude://code/continue?session=\(local)") else { return false }
        NSWorkspace.shared.open(url, configuration: activating)
        return true
    }

    /// The Claude app's own id ("local_…") for a Claude Code session. The app keeps a record per
    /// session in ~/Library/Application Support/Claude/claude-code-sessions with the Claude Code
    /// session id in `cliSessionId` (and earlier ones of a resumed session in `priorCliSessionIds`).
    /// That's the app's own format, so a miss just means bringing the app forward instead.
    static func claudeAppSession(for sessionID: String) -> String? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        let needle = Data(sessionID.utf8)
        for case let file as URL in files where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), data.range(of: needle) != nil,
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let local = record["sessionId"] as? String else { continue }
            let ids = [record["cliSessionId"] as? String] + (record["priorCliSessionIds"] as? [String] ?? []).map(Optional.some)
            if ids.contains(sessionID) { return local }
        }
        return nil
    }

    private static var activating: NSWorkspace.OpenConfiguration {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        return config
    }

    /// The folder an editor most likely has open for `path`: its git root. Nil (just bring the
    /// editor forward) when there is none or the path isn't on this Mac (a remote session): opening
    /// any other folder makes the editor open a new window for it.
    private static func workspaceRoot(of path: String) -> URL? {
        let fm = FileManager.default
        guard !path.isEmpty, fm.fileExists(atPath: path) else { return nil }
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        var dir = URL(fileURLWithPath: path).standardizedFileURL
        while dir.path != "/" && dir.path != home {
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) { return dir }
            dir.deleteLastPathComponent()
        }
        return nil
    }
}
