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

    static func show(host: String?, folder: String) {
        guard let host, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: host) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        // Open through Launch Services: an app that isn't active itself (we never are) can't
        // reliably activate another one directly on recent macOS.
        if folderEditors.contains(host), !folder.isEmpty {
            NSWorkspace.shared.open([URL(fileURLWithPath: folder)], withApplicationAt: app, configuration: config)
        } else {
            NSWorkspace.shared.openApplication(at: app, configuration: config)
        }
    }
}
