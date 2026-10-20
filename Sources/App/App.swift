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
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // no Dock icon
        app.run()
    }
}

/// Borderless window that sits over the notch, above the menu bar. Click-through,
/// except while a permission prompt shows its buttons.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 8)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = true
        isMovable = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Allow the frame to overlap the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Buttons must react to the first click: the panel never becomes key.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
    private var claudeCodeItem: NSMenuItem?
    private let hotKeys = HotKeys()
    /// The pointer is over the visible notch: take clicks there (to focus a session).
    private var pointerInside = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Already running, e.g. this is another copy of the app: that one says hi instead.
        if SocketServer.isAlive(Paths.socket, telling: Store.openedMessage) {
            NSApp.terminate(nil)
            return
        }
        if Self.runsFromDiskImage {
            askToMoveFirst()
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
        syncLaunchAtLogin()
        connectToClaudeCodeIfNeeded()
        _ = ClawdAssets.laptop  // read Clawd's sprites from Claude.app now, not on the first event
        promptsObserver = store.$prompts.sink { [weak self] _ in
            DispatchQueue.main.async {  // after `prompts` has its new value
                self?.resizePanel()
                self?.updateMouseHandling()
                self?.updateHotKeys()
            }
        }
        visibilityObserver = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updatePointerTracking() }  // after the change
        }
        updatePointerTracking()
        NotificationCenter.default.addObserver(
            self, selector: #selector(layoutPanel),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Sessions already under way show up at once; with none, Clawd says hi.
        DispatchQueue.global(qos: .userInitiated).async { [store] in
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
            : notch.height + NotchView.permissionHeight + 30
        let size = NSSize(width: 640, height: height)
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    // MARK: - Hover

    /// The pointer is only watched while there's a notch to hover: no wakeups while it's hidden.
    private func updatePointerTracking() {
        let visible = store.mode != .hidden
        if visible, hoverTimer == nil {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.trackPointer() }
            timer.tolerance = 0.02
            RunLoop.main.add(timer, forMode: .common)
            hoverTimer = timer
        } else if !visible, let timer = hoverTimer {
            timer.invalidate()
            hoverTimer = nil
            trackPointer()  // once more, to let go of the hover and the clicks
        }
    }

    /// The pointer is polled rather than tracked: the panel lets clicks through, so it gets no
    /// mouse events, and polling needs no special permission.
    private func trackPointer() {
        guard let screen = notchScreen, let notch else { return }
        let mode = store.mode
        // The greeting's row stays open under the pointer, so it can be clicked.
        let greeting = mode == .expanded && store.focused?.isGreeting == true
        let zoneMode: DisplayMode = mode == .details || mode == .permission || greeting ? mode : .compact
        let details = store.detailsSession
        let size = NotchView.size(of: zoneMode, session: details,
                                  others: store.others(than: details?.id).count, notch: notch)
        let zone = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                          width: size.width, height: size.height).insetBy(dx: -4, dy: -4)
        let inside = zone.contains(NSEvent.mouseLocation)
        store.pointer(inside: inside)
        let visible = inside && mode != .hidden
        if visible != pointerInside {
            pointerInside = visible
            updateMouseHandling()
        }
    }

    /// Click-through, except over a visible notch or while a permission card has buttons.
    private func updateMouseHandling() {
        panel.ignoresMouseEvents = store.prompts.isEmpty && !pointerInside
    }

    // MARK: - Permission shortcuts

    /// ⌃⌥⌘Y / ⌃⌥⌘N answer the oldest request, only while one is shown. System-wide hot keys take
    /// the keys away from every app, so they must not be everyday shortcuts like ⌘N.
    static let hotKeyModifiers = cmdKey | optionKey | controlKey

    private func updateHotKeys() {
        if store.prompts.isEmpty {
            hotKeys.unregisterAll()
        } else if !hotKeys.isRegistered {
            hotKeys.register(keyCode: kVK_ANSI_Y, modifiers: Self.hotKeyModifiers) { [weak self] in self?.answerPrompt(.allow) }
            hotKeys.register(keyCode: kVK_ANSI_N, modifiers: Self.hotKeyModifiers) { [weak self] in self?.answerPrompt(.deny) }
        }
    }

    private func answerPrompt(_ decision: Store.Decision) {
        guard let prompt = store.prompt else { return }
        store.answer(prompt, decision)
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = ClawdSprite.menuBarImage()
        item.button?.toolTip = "Claude Notch"
        statusItem = item
        buildMenu()
    }

    /// Rebuilt when the language changes.
    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        let title = NSMenuItem(title: "Claude Notch", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        let claudeCode = NSMenuItem(title: tr("Подключено к Claude Code", "Connected to Claude Code"),
                                    action: #selector(toggleClaudeCode), keyEquivalent: "")
        claudeCode.target = self
        menu.addItem(claudeCode)
        claudeCodeItem = claudeCode
        let login = NSMenuItem(title: tr("Запускать при входе", "Open at login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        loginItem = login
        let sounds = NSMenuItem(title: tr("Звук, когда готово или нужен ответ", "Sound when done or waiting for you"),
                                action: #selector(toggleSounds), keyEquivalent: "")
        sounds.target = self
        menu.addItem(sounds)
        soundsItem = sounds
        let rim = NSMenuItem(title: tr("Переливающаяся обводка", "Glowing rim"), action: #selector(toggleRim), keyEquivalent: "")
        rim.target = self
        menu.addItem(rim)
        rimItem = rim

        let languages = NSMenu()
        for (choice, name) in [(nil, tr("Как в системе", "System")), (Language.en, "English"), (Language.ru, "Русский")] {
            let option = NSMenuItem(title: name, action: #selector(pickLanguage(_:)), keyEquivalent: "")
            option.target = self
            option.representedObject = choice?.rawValue
            option.state = Language.choice == choice ? .on : .off
            languages.addItem(option)
        }
        let language = NSMenuItem(title: tr("Язык", "Language"), action: nil, keyEquivalent: "")
        language.submenu = languages
        menu.addItem(language)

        menu.addItem(.separator())
        let remove = NSMenuItem(title: tr("Удалить Claude Notch…", "Remove Claude Notch…"), action: #selector(removeApp), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
        menu.addItem(NSMenuItem(title: tr("Выйти", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        claudeCodeItem?.state = ClaudeHooks.state() == .connected ? .on : .off
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        soundsItem?.state = UserDefaults.standard.bool(forKey: Store.soundsKey) ? .on : .off
        rimItem?.state = UserDefaults.standard.bool(forKey: Store.rimKey) ? .on : .off
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

    private func askToMoveFirst() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = tr("Сначала перетащи Claude Notch в «Программы»", "Drag Claude Notch to Applications first")
        alert.informativeText = tr("Потом открой его оттуда: из образа диска оно работать не сможет, когда тот извлекут.",
                                   "Then open it from there: run from the disk image, it would stop once the image is ejected.")
        alert.addButton(withTitle: tr("Понятно", "OK"))
        alert.runModal()
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

    /// What uninstall.sh does, for a copy dragged in from the disk image: no hooks left pointing at an app
    /// that's gone (Claude Code would complain about them on every event), no login item, and the app
    /// and its data in the Trash.
    @objc private func removeApp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = tr("Удалить Claude Notch?", "Remove Claude Notch?")
        alert.informativeText = tr(
            "Хуки уберутся из ~/.claude/settings.json, автозапуск выключится, а приложение и его данные отправятся в Корзину.",
            "Its hooks come out of ~/.claude/settings.json, it stops opening at login, and the app and its data go to the Trash.")
        alert.addButton(withTitle: tr("Удалить", "Remove")).hasDestructiveAction = true
        alert.addButton(withTitle: tr("Отмена", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try ClaudeHooks.disconnect()
        } catch {
            return show(error)
        }
        try? SMAppService.mainApp.unregister()
        server?.stop()
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "local.claudenotch")
        NSWorkspace.shared.recycle([Bundle.main.bundleURL, URL(fileURLWithPath: Paths.dir)]) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
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
