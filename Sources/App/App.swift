import AppKit
import Combine
import ServiceManagement
import SwiftUI

@main
enum ClaudeNotchMain {
    @MainActor
    static func main() {
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SocketServer.isAlive(Paths.socket) {  // already running
            NSApp.terminate(nil)
            return
        }

        let server = SocketServer(path: Paths.socket) { [store] data, reply in
            DispatchQueue.main.async { store.handle(data, reply: reply) }
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
        promptsObserver = store.$prompts.sink { [panel] prompts in
            panel.ignoresMouseEvents = prompts.isEmpty
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
        let size = NSSize(width: 640, height: notch.height + NotchView.permissionHeight + 40)
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height)

        let hosting = FirstClickHostingView(rootView: NotchView(store: store, notch: notch))
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Claude Notch")

        let menu = NSMenu()
        menu.delegate = self
        let title = NSMenuItem(title: "Claude Notch", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        let demo = NSMenuItem(title: "Показать демо", action: #selector(runDemo), keyEquivalent: "")
        demo.target = self
        menu.addItem(demo)
        let login = NSMenuItem(title: "Запускать при входе", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        loginItem = login
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func runDemo() {
        store.runDemo()
    }

    // MARK: - Launch at login

    private static let launchAtLoginKey = "launchAtLogin"

    /// On by default. Re-registered on every launch, since a rebuilt app can lose its login item.
    private func syncLaunchAtLogin() {
        UserDefaults.standard.register(defaults: [Self.launchAtLoginKey: true])
        if UserDefaults.standard.bool(forKey: Self.launchAtLoginKey), SMAppService.mainApp.status != .enabled {
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
