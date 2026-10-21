import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement
import SwiftUI

@main
enum ClaudeNotchMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--unregister-login-item") {  // used by uninstall.sh
            try? SMAppService.mainApp.unregister()
            return
        }
        signal(SIGPIPE, SIG_IGN)  // a hook may hang up before we answer
        UserDefaults.standard.register(defaults: Store.defaults)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // no Dock icon
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = Store()
    private let panel = NotchPanel()
    private var server: SocketServer?
    private var statusItem: NSStatusItem?
    private var loginItem: NSMenuItem?
    private var promptsObserver: AnyCancellable?
    private var visibilityObserver: AnyCancellable?
    private var hoverTimer: Timer?
    private var notchScreen: NSScreen?
    private var notch: NotchMetrics?
    private var soundsItem: NSMenuItem?
    private var rimItem: NSMenuItem?
    private var aliveItem: NSMenuItem?
    private var claudeCodeItem: NSMenuItem?
    private let hotKeys = HotKeys()
    private let trashWatcher = TrashWatcher()
    private var shortcuts = Shortcuts.none
    /// The pointer is over the visible notch: take clicks there (to focus a session).
    private var pointerInside = false
    /// Where the pointer was at the last look, and whether the notch changed since: with neither,
    /// there's nothing to work out.
    private var lastPointer: NSPoint?
    private var notchChanged = true
    private var pointerNear = false
    /// The pointer is followed from mouse events, once one has come in; polled until then.
    private var followingMouse = false
    private var lookPending = false
    /// What keeps anyone from seeing the notch, besides the panel being covered.
    private var screensAsleep = false, locked = false, switchedAway = false
    private static let screenLocked = Notification.Name("com.apple.screenIsLocked")
    private static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.runsFromDiskImage { return offerToMove() }  // before the check below: it may replace the running one
        // Already running, e.g. this is another copy of the app: that one says hi instead.
        if SocketServer.isAlive(Paths.socket, telling: Store.openedMessage) {
            NSApp.terminate(nil)
            return
        }

        let server = SocketServer(path: Paths.socket) { [store] data, reply in
            // Parsed here, off the main thread: a payload can carry megabytes of tool output.
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            DispatchQueue.main.async { store.handle(json, reply: reply) }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            NSLog("ClaudeNotch: can't listen on \(Paths.socket): \(error)")
        }

        layoutPanel()
        setUpStatusItem()
        trashWatcher.start()
        syncLaunchAtLogin()
        connectToClaudeCodeIfNeeded()
        promptsObserver = store.$prompts.sink { [weak self] _ in
            DispatchQueue.main.async {  // after `prompts` has its new value
                self?.resizePanel()
                self?.updateMouseHandling()
                self?.updateHotKeys()
            }
        }
        visibilityObserver = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {  // after the change
                guard let self else { return }
                self.notchChanged = true
                self.updatePointerTracking()
                // The notch changed under a pointer that may not move: is it still over it?
                if self.followingMouse, self.store.mode != .hidden, self.store.onScreen { self.trackPointer() }
            }
        }
        observeVisibility()
        followMouse()
        updatePointerTracking()
        NotificationCenter.default.addObserver(
            self, selector: #selector(layoutPanel),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Sessions already under way show up at once; with none, Clawd says hi. Clawd's sprites are read
        // from Claude.app here too, off the main thread, rather than on the first event.
        DispatchQueue.global(qos: .userInitiated).async { [store] in
            _ = ClawdAssets.laptop
            let running = TranscriptWatcher.running()
            DispatchQueue.main.async {
                store.adopt(running)
                store.greet()
            }
        }
    }

    /// Opened again while running (Finder, Spotlight, Launchpad): there's no window to show, so the notch says hi.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        store.greet()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    @objc private func layoutPanel() {
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? screens.first else { return }
        let notch = NotchMetrics(screen: screen)
        notchScreen = screen
        self.notch = notch
        notchChanged = true

        let hosting = FirstClickHostingView(rootView: NotchView(store: store, notch: notch))
        hosting.sizingOptions = []
        panel.contentView = hosting
        resizePanel()
        panel.orderFrontRegardless()
    }

    /// Tall enough for the hover card; only as tall as the permission card while that one takes
    /// clicks, so the transparent rest of the window doesn't swallow clicks meant for other apps.
    private func resizePanel() {
        guard let screen = notchScreen, let notch else { return }
        let height = store.prompts.isEmpty
            ? NotchView.maxHeight(notch: notch) + 30
            : notch.height + NotchView.promptHeight(store.prompt) + 30
        let size = NSSize(width: 640, height: height)
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    // MARK: - Can the notch be seen

    /// Nobody sees the notch while its display sleeps, the screen is locked, another user is at the Mac or
    /// the panel is covered: the store's clock stops then, and Clawd and the rim hold still.
    private func observeVisibility() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(self, selector: #selector(visibilityChanged(_:)), name: name, object: nil)
        }
        for name in [Self.screenLocked, Self.screenUnlocked] {
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(visibilityChanged(_:)), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged(_:)),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: panel)
        updateVisibility()
    }

    @objc private func visibilityChanged(_ note: Notification) {
        switch note.name {
        case NSWorkspace.screensDidSleepNotification: screensAsleep = true
        case NSWorkspace.screensDidWakeNotification: screensAsleep = false
        case NSWorkspace.sessionDidResignActiveNotification: switchedAway = true
        case NSWorkspace.sessionDidBecomeActiveNotification: switchedAway = false
        case Self.screenLocked: locked = true
        case Self.screenUnlocked: locked = false
        default: break  // the panel was covered or uncovered
        }
        updateVisibility()
    }

    private func updateVisibility() {
        let visible = panel.occlusionState.contains(.visible) && !screensAsleep && !locked && !switchedAway
        if visible != store.onScreen { EventLog.append(visible ? "Notch on screen" : "Notch out of sight") }
        store.screen(visible: visible)
    }

    // MARK: - Hover

    /// Looks at the pointer when the mouse moves, at most 20 times a second, over other apps and over the
    /// notch: with the mouse at rest, nothing wakes the app up for it. Only where the pointer is comes in,
    /// and it stays in the app; watching mouse moves needs no permission, unlike keys. Should no event
    /// come in all the same, the pointer is polled instead.
    private func followMouse() {
        let moved: (NSEvent) -> Void = { [weak self] _ in self?.mouseMoved() }
        _ = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: moved)
        _ = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            moved(event)
            return event
        }
    }

    private func mouseMoved() {
        if !followingMouse {
            followingMouse = true
            EventLog.append("Pointer followed from mouse events")
            hoverTimer?.invalidate()
            hoverTimer = nil
        }
        guard !lookPending, store.mode != .hidden, store.onScreen else { return }
        lookPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.lookPending = false
            self?.trackPointer()
        }
    }

    /// Until mouse events come in, the pointer is polled while there's a notch to hover and it can be seen:
    /// no wakeups otherwise.
    private func updatePointerTracking() {
        let watching = store.mode != .hidden && store.onScreen
        if watching, hoverTimer == nil, !followingMouse {
            lookAgain(after: 0.1)
        } else if !watching, let timer = hoverTimer {
            timer.invalidate()
            hoverTimer = nil
            trackPointer()  // once more, to let go of the hover and the clicks
        }
    }

    /// The next look at the pointer: 10 times a second while it's near the notch, about 3 times a second
    /// while it's elsewhere, where it takes a moment to get to the notch anyway.
    private func lookAgain(after delay: TimeInterval) {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.hoverTimer = nil
            let near = self.trackPointer()
            if self.store.mode != .hidden, self.store.onScreen, !self.followingMouse { self.lookAgain(after: near ? 0.1 : 0.3) }
        }
        timer.tolerance = delay / 5  // lets macOS bundle the wakeup with others
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    /// Where the pointer is against the notch. The panel lets clicks through, so it can't track the pointer
    /// itself. A look finds nothing new unless the pointer moved or the notch changed. Returns whether the
    /// pointer is near the notch.
    @discardableResult
    private func trackPointer() -> Bool {
        guard let screen = notchScreen, let notch else { return false }
        let location = NSEvent.mouseLocation
        guard location != lastPointer || notchChanged else { return pointerNear }
        lastPointer = location
        notchChanged = false
        let mode = store.mode
        // The greeting's row stays open under the pointer, so it can be clicked.
        let greeting = mode == .expanded && store.focused?.isGreeting == true
        let zoneMode: DisplayMode = mode == .details || mode == .permission || greeting ? mode : .compact
        let details = store.detailsSession
        let size = NotchView.size(of: zoneMode, session: details,
                                  others: store.others(than: details?.id).count, prompt: store.prompt, notch: notch)
        let zone = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                          width: size.width, height: size.height).insetBy(dx: -4, dy: -4)
        let inside = zone.contains(location)
        pointerNear = zone.insetBy(dx: -150, dy: -100).contains(location)
        store.pointer(inside: inside)
        let visible = inside && mode != .hidden
        if visible != pointerInside {
            pointerInside = visible
            updateMouseHandling()
        }
        return pointerNear
    }

    /// Click-through, except over a visible notch or while a permission card has buttons.
    private func updateMouseHandling() {
        panel.ignoresMouseEvents = store.prompts.isEmpty && !pointerInside
    }

    // MARK: - Permission shortcuts

    /// ⌃⌥⌘Y / ⌃⌥⌘N answer the oldest request, ⌃⌥⌘1…4 pick an answer to a question (and ⌃⌥⌘Y sends the
    /// ones ticked). System-wide hot keys take the keys away from every app, so they must not be
    /// everyday shortcuts like ⌘N, and only the ones the card on show uses are taken.
    static let hotKeyModifiers = cmdKey | optionKey | controlKey

    /// The shortcuts the card on show answers to.
    private enum Shortcuts: Equatable {
        case none, permission
        case question(options: Int, multiSelect: Bool)
    }

    private func updateHotKeys() {
        let wanted = store.prompt.map { prompt in
            prompt.form.map { Shortcuts.question(options: $0.current.options.count, multiSelect: $0.current.multiSelect) }
                ?? .permission
        } ?? .none
        guard wanted != shortcuts else { return }
        shortcuts = wanted
        hotKeys.unregisterAll()
        let modifiers = Self.hotKeyModifiers
        switch wanted {
        case .none:
            break
        case .permission:
            hotKeys.register(keyCode: kVK_ANSI_Y, modifiers: modifiers) { [weak self] in self?.answerPrompt(.allow) }
            hotKeys.register(keyCode: kVK_ANSI_N, modifiers: modifiers) { [weak self] in self?.answerPrompt(.deny) }
        case .question(let options, let multiSelect):
            for (i, key) in [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4].prefix(options).enumerated() {
                hotKeys.register(keyCode: key, modifiers: modifiers) { [weak self] in self?.chooseOption(i) }
            }
            if multiSelect {
                hotKeys.register(keyCode: kVK_ANSI_Y, modifiers: modifiers) { [weak self] in self?.submitAnswers() }
            }
        }
    }

    private func answerPrompt(_ decision: Store.Decision) {
        guard let prompt = store.prompt, prompt.form == nil else { return }
        store.answer(prompt, decision)
    }

    private func chooseOption(_ index: Int) {
        guard let prompt = store.prompt else { return }
        store.choose(prompt, option: index)
    }

    private func submitAnswers() {
        guard let prompt = store.prompt else { return }
        store.submitPicked(prompt)
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = ClawdSprite.menuBarImage()
        item.button?.toolTip = "Claude Notch"
        statusItem = item
        buildMenu()
    }

    /// Rebuilt when the language changes. Every row has an SF Symbol in front, as in macOS's own menus:
    /// macOS 26 puts one on Quit by itself, and rows without one were left with a gap.
    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        let title = NSMenuItem(title: "Claude Notch", action: nil, keyEquivalent: "")
        title.image = ClawdSprite.menuBarImage(cell: 1.2)
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        claudeCodeItem = add(to: menu, tr("Подключено к Claude Code", "Connected to Claude Code"), "link", #selector(toggleClaudeCode))
        loginItem = add(to: menu, tr("Запускать при входе", "Open at login"), "arrow.up.forward.app", #selector(toggleLaunchAtLogin))
        soundsItem = add(to: menu, tr("Звук, когда готово или нужен ответ", "Sound when done or waiting for you"),
                         "speaker.wave.2", #selector(toggleSounds))
        rimItem = add(to: menu, tr("Переливающаяся обводка", "Glowing rim"), "sparkles", #selector(toggleRim))
        aliveItem = add(to: menu, tr("Clawd живёт в чёлке всегда", "Clawd stays in the notch"), "pawprint", #selector(toggleAlive))

        let languages = NSMenu()
        for (choice, name) in [(nil, tr("Как в системе", "System")), (Language.en, "English"), (Language.ru, "Русский")] {
            let option = NSMenuItem(title: name, action: #selector(pickLanguage(_:)), keyEquivalent: "")
            option.target = self
            option.representedObject = choice?.rawValue
            option.state = Language.choice == choice ? .on : .off
            languages.addItem(option)
        }
        let language = add(to: menu, tr("Язык", "Language"), "globe", nil)
        language.submenu = languages

        menu.addItem(.separator())
        let quit = add(to: menu, tr("Выйти", "Quit"), "power", #selector(NSApplication.terminate(_:)), key: "q")
        quit.target = nil  // goes to NSApp
        statusItem?.menu = menu
    }

    @discardableResult
    private func add(to menu: NSMenu, _ title: String, _ symbol: String, _ action: Selector?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menu.addItem(item)
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        claudeCodeItem?.state = ClaudeHooks.state() == .connected ? .on : .off
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        soundsItem?.state = UserDefaults.standard.bool(forKey: Store.soundsKey) ? .on : .off
        rimItem?.state = UserDefaults.standard.bool(forKey: Store.rimKey) ? .on : .off
        aliveItem?.state = Store.alive ? .on : .off
    }

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        Language.choice = (sender.representedObject as? String).flatMap(Language.init(rawValue:))
        buildMenu()
        store.objectWillChange.send()  // redraw the notch in the new language
    }

    @objc private func toggleRim() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Store.rimKey), forKey: Store.rimKey)
        store.objectWillChange.send()  // redraw the notch with or without it
    }

    /// On, Clawd floats in under a parachute; off, he leaves once the rest after the last turn is over.
    @objc private func toggleAlive() {
        UserDefaults.standard.set(!Store.alive, forKey: Store.aliveKey)
        if Store.alive { store.moveIn() }
        store.objectWillChange.send()
    }

    @objc private func toggleSounds() {
        let on = !UserDefaults.standard.bool(forKey: Store.soundsKey)
        UserDefaults.standard.set(on, forKey: Store.soundsKey)
        if on { NSSound(named: "Glass")?.play() }
    }

    // MARK: - Claude Code

    private static let hooksDeclinedKey = "hooksDeclined"

    /// Opened right from the disk image, or from Downloads, which macOS runs from a hidden read-only copy:
    /// the hooks and the login item would point at a copy that's gone once the image is ejected.
    private static var runsFromDiskImage: Bool {
        let app = Bundle.main.bundleURL
        return app.path.contains("/AppTranslocation/")
            || (try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
    }

    /// Opened from the disk image: offers to copy itself to Applications and open from there, so
    /// it's plain it got there. A copy that's there already is quit and put in the Trash.
    private func offerToMove() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = tr("Переместить Claude Notch в «Программы»?", "Move Claude Notch to Applications?")
        alert.informativeText = tr("Из образа диска он перестанет работать, когда тот извлекут. Claude Notch скопирует себя в «Программы» и откроется оттуда.",
                                   "Run from the disk image, it would stop once the image is ejected. Claude Notch copies itself to Applications and opens from there.")
        alert.addButton(withTitle: tr("Переместить", "Move"))
        alert.addButton(withTitle: tr("Выйти", "Quit"))
        guard alert.runModal() == .alertFirstButtonReturn else { return NSApp.terminate(nil) }

        let copy: URL
        do {
            copy = try copyToApplications()
        } catch {
            show(error)
            return NSApp.terminate(nil)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true  // this one, from the image, still runs
        NSWorkspace.shared.openApplication(at: copy, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error { self.show(error) }
                NSApp.terminate(nil)
            }
        }
    }

    /// Where a copy is already, else /Applications, else ~/Applications for a user who can't write there.
    private func copyToApplications() throws -> URL {
        let fm = FileManager.default
        let name = Bundle.main.bundleURL.lastPathComponent
        let folders = [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        let copy = folders.map { $0.appendingPathComponent(name) }.first { fm.fileExists(atPath: $0.path) }
            ?? (fm.isWritableFile(atPath: folders[0].path) ? folders[0] : folders[1]).appendingPathComponent(name)

        // Quit first: put in the Trash while it runs, the old copy would offer to remove everything.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != .current }
        others.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while others.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }

        try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: copy.path) { try fm.trashItem(at: copy, resultingItemURL: nil) }
        try fm.copyItem(at: Bundle.main.bundleURL, to: copy)
        // Opened once already with Gatekeeper's OK: the copy needn't ask again.
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", copy.path]
        if (try? xattr.run()) != nil { xattr.waitUntilExit() }
        return copy
    }

    /// Copied in from the disk image, the app connects itself: the first time it asks, and once
    /// connected it quietly points the hooks at itself again after a move or an update that adds
    /// events. An install from source has connected it already.
    private func connectToClaudeCodeIfNeeded() {
        switch ClaudeHooks.state() {
        case .connected:
            return
        case .outdated:
            connectToClaudeCode(asked: false)
        case .missing:
            guard !UserDefaults.standard.bool(forKey: Self.hooksDeclinedKey) else { return }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = tr("Подключить Claude Notch к Claude Code?", "Connect Claude Notch to Claude Code?")
            alert.informativeText = tr(
                "Claude Notch добавит свои хуки в ~/.claude/settings.json: так Claude Code будет сообщать ему, что делает. Остальные настройки останутся как были, а исходный файл сохранится рядом. Отключить можно в меню Clawd в строке меню.",
                "Claude Notch adds its hooks to ~/.claude/settings.json, so Claude Code tells it what it's doing. Your other settings stay as they are, and the original file is saved next to it. You can disconnect in Clawd's menu in the menu bar.")
            alert.addButton(withTitle: tr("Подключить", "Connect"))
            alert.addButton(withTitle: tr("Не сейчас", "Not now"))
            if alert.runModal() == .alertFirstButtonReturn {
                connectToClaudeCode(asked: true)
            } else {
                UserDefaults.standard.set(true, forKey: Self.hooksDeclinedKey)  // the menu can still do it
            }
        }
    }

    /// `asked`: you chose it, so a failure is worth an alert; otherwise it only goes to the log.
    private func connectToClaudeCode(asked: Bool) {
        do {
            try ClaudeHooks.connect()
            UserDefaults.standard.set(false, forKey: Self.hooksDeclinedKey)
            EventLog.append("Hooks connected: \(ClaudeHooks.hookPath)")
        } catch {
            EventLog.append("Hooks not connected: \(error.localizedDescription)")
            if asked { show(error) }
        }
    }

    @objc private func toggleClaudeCode() {
        guard ClaudeHooks.state() == .connected else { return connectToClaudeCode(asked: true) }
        do {
            try ClaudeHooks.disconnect()
            UserDefaults.standard.set(true, forKey: Self.hooksDeclinedKey)  // don't ask again at the next launch
            EventLog.append("Hooks disconnected")
        } catch {
            show(error)
        }
    }

    private func show(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        NSAlert(error: error).runModal()
    }

    // MARK: - Launch at login

    private static let launchAtLoginKey = "launchAtLogin"

    /// Turned on at the first launch. After that the menu toggle and System Settings decide; the only
    /// repair is for a rebuilt app whose login item went missing (.notFound) while it's meant to be on.
    private func syncLaunchAtLogin() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.launchAtLoginKey) == nil {
            defaults.set(true, forKey: Self.launchAtLoginKey)
            setLaunchAtLogin(true)
        } else if defaults.bool(forKey: Self.launchAtLoginKey), SMAppService.mainApp.status == .notFound {
            setLaunchAtLogin(true)
        } else {
            EventLog.append("LaunchAtLogin status=\(SMAppService.mainApp.status.rawValue)")
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let enable = SMAppService.mainApp.status != .enabled
        UserDefaults.standard.set(enable, forKey: Self.launchAtLoginKey)
        setLaunchAtLogin(enable)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("ClaudeNotch: launch at login \(enabled ? "on" : "off") failed: \(error)")
        }
        EventLog.append("LaunchAtLogin status=\(SMAppService.mainApp.status.rawValue)")
    }
}
