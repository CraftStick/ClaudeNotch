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
    private var hoverTimer: Timer?
    private var notchScreen: NSScreen?
    private var notch: NotchMetrics?
    private var soundsItem: NSMenuItem?
    private let hotKeys = HotKeys()
    /// The pointer is over the visible notch: take clicks there (to focus a session).
    private var pointerInside = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SocketServer.isAlive(Paths.socket) {  // already running
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
        _ = ClawdAssets.laptop  // read Clawd's sprites from Claude.app now, not on the first event
        promptsObserver = store.$prompts.sink { [weak self] _ in
            DispatchQueue.main.async {  // after `prompts` has its new value
                self?.resizePanel()
                self?.updateMouseHandling()
                self?.updateHotKeys()
            }
        }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.trackPointer()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(layoutPanel),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
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

    /// The pointer is polled rather than tracked: the panel lets clicks through, so it gets no
    /// mouse events, and polling needs no special permission.
    private func trackPointer() {
        guard let screen = notchScreen, let notch else { return }
        let mode = store.mode
        let zoneMode: DisplayMode = mode == .details || mode == .permission ? mode : .compact
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
        let login = NSMenuItem(title: tr("Запускать при входе", "Open at login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        loginItem = login
        let sounds = NSMenuItem(title: tr("Звук, когда готово или нужен ответ", "Sound when done or waiting for you"),
                                action: #selector(toggleSounds), keyEquivalent: "")
        sounds.target = self
        menu.addItem(sounds)
        soundsItem = sounds

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
        menu.addItem(NSMenuItem(title: tr("Выйти", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        soundsItem?.state = UserDefaults.standard.bool(forKey: Store.soundsKey) ? .on : .off
    }

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        Language.choice = (sender.representedObject as? String).flatMap(Language.init(rawValue:))
        buildMenu()
        store.objectWillChange.send()  // redraw the notch in the new language
    }

    @objc private func toggleSounds() {
        let on = !UserDefaults.standard.bool(forKey: Store.soundsKey)
        UserDefaults.standard.set(on, forKey: Store.soundsKey)
        if on { NSSound(named: "Glass")?.play() }
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
