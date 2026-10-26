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

    /// Terminal and iTerm tell their tabs apart by tty; this script brings the tab with the one passed in to the front.
    private static let tabScripts: [String: String] = [
        "com.apple.Terminal": """
            on run argv
                tell application id "com.apple.Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is (item 1 of argv) then
                                set selected of t to true
                                set index of w to 1
                                activate
                                return "found"
                            end if
                        end repeat
                    end repeat
                end tell
                return ""
            end run
            """,
        "com.googlecode.iterm2": """
            on run argv
                tell application id "com.googlecode.iterm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is (item 1 of argv) then
                                    select w
                                    select t
                                    select s
                                    activate
                                    return "found"
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                return ""
            end run
            """,
    ]

    /// In Terminal and iTerm, the very tab the session runs in; elsewhere, or when macOS says no, the app.
    /// osascript runs in the background: the first time, macOS asks whether Claude Notch may control the
    /// terminal, and that question mustn't hold up the notch.
    /// `found` comes on the main thread: whether it was that very tab.
    static func show(host: String?, folder: String, tty: String?, found: ((Bool) -> Void)? = nil) {
        guard let host, let tty, canShowTab(host: host, tty: tty),
              let script = tabScripts[host],
              !NSRunningApplication.runningApplications(withBundleIdentifier: host).isEmpty else {
            show(host: host, folder: folder)
            found?(false)
            return
        }
        let osascript = Process()
        osascript.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osascript.arguments = ["-e", script, tty]
        let output = Pipe()
        osascript.standardOutput = output
        osascript.standardError = FileHandle.nullDevice
        osascript.terminationHandler = { _ in
            let tab = output.fileHandleForReading.readDataToEndOfFile().starts(with: Data("found".utf8))
            DispatchQueue.main.async {
                if !tab { show(host: host, folder: folder) }
                found?(tab)
            }
        }
        do { try osascript.run() } catch {
            show(host: host, folder: folder)
            found?(false)
        }
    }

    /// Terminal or iTerm, and a tty that looks like one: the session's very tab can be brought forward.
    static func canShowTab(host: String?, tty: String?) -> Bool {
        guard let host, let tty else { return false }
        return tabScripts[host] != nil && tty.range(of: #"^/dev/ttys?[0-9]+$"#, options: .regularExpression) != nil
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

    /// Opens a session that runs in the Claude app at that very session, not just the app; `otherwise`
    /// runs when the app keeps no record of it. Looked up off the main thread: it reads a file per session.
    static func openInClaudeApp(_ sessionID: String, otherwise: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let local = claudeAppSession(for: sessionID)
            DispatchQueue.main.async {
                guard let local, let url = URL(string: "claude://code/continue?session=\(local)") else { return otherwise() }
                NSWorkspace.shared.open(url, configuration: activating)
            }
        }
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
