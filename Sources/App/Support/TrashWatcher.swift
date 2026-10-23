import AppKit
import ServiceManagement

/// Watches this copy of the app. Dragged to the Trash while it runs, it asks whether to take away
/// everything it put outside itself too (the hooks, the login item, its settings and data, as
/// uninstall.sh does) and quits. Putting it back is for Finder: macOS lets no other app take
/// anything out of the Trash.
final class TrashWatcher {
    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var asking = false

    func start() {
        fd = open(Bundle.main.bundlePath, O_EVTONLY)  // follows the bundle wherever it's moved
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.rename, .delete], queue: .main)
        // Asked from the run loop, not from this block: a modal alert inside a block on the main queue
        // would hold up the whole queue, and the notch with it, until it's answered.
        source.setEventHandler { [weak self] in RunLoop.main.perform { self?.moved() } }
        source.resume()
        self.source = source
    }

    /// Where the bundle is now; nil once it's gone for good (the Trash was emptied).
    private var currentPath: String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
        let path = String(cString: buffer)
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private func moved() {
        guard !asking else { return }
        let now = currentPath
        if let now, !now.split(separator: "/").contains(where: { $0 == ".Trash" || $0 == ".Trashes" }) {
            return  // just moved: the hooks follow it at the next launch
        }
        asking = true
        defer { asking = false }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage  // the bundle's own is no longer found in the Trash
        alert.messageText = tr("Удалить Claude Notch полностью?", "Remove Claude Notch completely?")
        alert.informativeText = tr(
            "Claude Notch в Корзине. Вместе с ним удалится всё, что он добавил: хуки в ~/.claude/settings.json, вход при запуске, настройки и данные. Отменить это будет нельзя.\n\nЧтобы оставить его, нажми «Оставить» и верни его из Корзины: правый клик → «Вернуть».",
            "Claude Notch is in the Trash. Everything it added goes with it: its hooks in ~/.claude/settings.json, the login item, its settings and data. This can't be undone.\n\nTo keep it, choose Keep and take it out of the Trash: right-click → Put Back.")
        alert.addButton(withTitle: tr("Удалить всё", "Remove All")).hasDestructiveAction = true
        alert.addButton(withTitle: tr("Оставить", "Keep"))
        if alert.runModal() == .alertFirstButtonReturn { removeEverything() }
    }

    private func removeEverything() {
        let fm = FileManager.default
        try? ClaudeHooks.disconnect()
        try? fm.removeItem(atPath: ClaudeHooks.settingsURL.path + ".bak-claudenotch")
        try? SMAppService.mainApp.unregister()
        try? fm.removeItem(atPath: Paths.dir)
        for path in Paths.httpStorage { try? fm.removeItem(atPath: path) }
        if let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
            UserDefaults.standard.synchronize()
        }
        exit(0)  // right away: nothing gets written back on the way out
    }
}
