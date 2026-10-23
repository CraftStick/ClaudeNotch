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
        UserDefaults.standard.register(defaults: Store.defaults.merging(TelegramNote.defaults) { a, _ in a }
                                                    .merging([PlanLimits.key: true]) { a, _ in a })
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
    private var updateItem: NSMenuItem?
    private let updates = Updates()
    private let limits = PlanLimits()
    private let telegram = Telegram()
    private lazy var questions = TelegramQuestions(store: store, telegram: telegram)
    /// When a limit was last told from a turn that hit it, rather than from the limits themselves.
    private var lastLimitNotice = Date.distantPast
    private lazy var settings = SettingsWindow(actions: SettingsActions(
        isConnected: { ClaudeHooks.state() == .connected },
        setConnected: { [weak self] on in
            guard on != (ClaudeHooks.state() == .connected) else { return }
            self?.toggleClaudeCode()
        },
        opensAtLogin: { SMAppService.mainApp.status == .enabled },
        setOpensAtLogin: { [weak self] on in
            guard on != (SMAppService.mainApp.status == .enabled) else { return }
            self?.toggleLaunchAtLogin()
        },
        setAlive: { [weak self] on in
            if on { self?.store.moveIn() }
            self?.store.aliveChanged()
        },
        changed: { [weak self] in
            self?.buildMenu()
            self?.shortcuts = nil
            self?.updateHotKeys()
            self?.store.settingsChanged()  // the notch again, in its language, with or without the rim, quiet or not
        }), updates: updates, limits: limits, telegram: telegram)
    private var promptsObserver: AnyCancellable?
    private var visibilityObserver: AnyCancellable?
    private var hoverTimer: Timer?
    private var notchScreen: NSScreen?
    private var notch: NotchMetrics?
    private let hotKeys = HotKeys()
    private let trashWatcher = TrashWatcher()
    /// nil: none registered yet, or the settings changed which ones to take.
    private var shortcuts: Shortcuts?
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
        updates.announce = { [weak self] version, page in self?.announce(version, page) }
        updates.schedule()
        watchLimits()
        promptsObserver = store.$prompts.sink { [weak self] _ in
            DispatchQueue.main.async {  // after `prompts` has its new value
                self?.resizePanel()
                self?.updateMouseHandling()
                self?.updateHotKeys()
                self?.questions.update()
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
        // The greeting's row (or a notice's) stays open under the pointer, so it can be clicked.
        let greeting = mode == .expanded && store.focused?.isApp == true
        let zoneMode: DisplayMode = mode == .details || mode == .permission || greeting ? mode : .compact
        let details = store.detailsSession
        let size = NotchView.size(of: zoneMode, session: details,
                                  others: store.others(than: details?.id).count, prompt: store.prompt, notch: notch,
                                  busy: store.working.count)
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
    /// ones ticked); the settings may pick other modifiers, or none. System-wide hot keys take the keys
    /// away from every app, so they must not be everyday shortcuts like ⌘N, and only the ones the card
    /// on show uses are taken.

    /// The shortcuts the card on show answers to.
    private enum Shortcuts: Equatable {
        case none, permission
        case question(options: Int, multiSelect: Bool)
    }

    private func updateHotKeys() {
        let modifiers = HotKeyChoice.current.modifiers
        let wanted = modifiers == nil ? .none : store.prompt.map { prompt in
            prompt.form.map { Shortcuts.question(options: $0.current.options.count, multiSelect: $0.current.multiSelect) }
                ?? .permission
        } ?? .none
        guard wanted != shortcuts else { return }
        shortcuts = wanted
        hotKeys.unregisterAll()
        guard let modifiers else { return }
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
        updateItem = add(to: menu, "", "arrow.down.circle.fill", #selector(openUpdate))
        updateItem?.isHidden = true
        add(to: menu, tr("Настройки…", "Settings…"), "gearshape", #selector(openSettings), key: ",")
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

    /// A newer version, when the update check (on in the settings) found one.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if case .available(let version, _) = updates.status {
            updateItem?.title = tr("Вышла версия \(version) — скачать", "Version \(version) is out — download")
            updateItem?.isHidden = false
        } else {
            updateItem?.isHidden = true
        }
    }

    @objc private func openSettings() { settings.show() }

    @objc private func openUpdate() {
        if case .available(_, let page) = updates.status { NSWorkspace.shared.open(page) }
    }

    /// Told once per version, while it's on.
    private func announce(_ version: String, _ page: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = tr("Вышла Claude Notch \(version)", "Claude Notch \(version) is out")
        alert.informativeText = tr("Сейчас у тебя \(Updates.current). Скачай образ диска, открой новый Claude Notch прямо в нём и нажми «Переместить»: он встанет на место старого.",
                                   "You have \(Updates.current). Download the disk image, open the new Claude Notch right in it and click Move: it takes the old one's place.")
        alert.addButton(withTitle: tr("Открыть страницу", "Open the Page"))
        alert.addButton(withTitle: tr("Позже", "Later"))
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(page) }
    }

    // MARK: - Limits and Telegram

    private func watchLimits() {
        limits.claudeWasBusy = { [store] in
            let now = Date()
            return !store.working.isEmpty
                || store.sessions.values.contains { now.timeIntervalSince($0.turnEnd ?? .distantPast) < PlanLimits.keepLooking }
        }
        limits.onChange = { [weak self] change in self?.limitChanged(change) }
        limits.start()
        store.onNews = { [weak self] news in self?.news(news) }
        store.questionsGoFar = { [weak self] in self?.questions.active == true }
        if telegram.linked { telegram.refresh() }
    }

    /// A limit ran out: the notch opens on Clawd by his hourglass, and Telegram hears of it. It's back: a hop.
    private func limitChanged(_ change: PlanLimits.Change) {
        switch change {
        case .exhausted(let limit):
            let title = tr("\(limit.name) исчерпан", "\(limit.name) reached")
            let reset = limit.resetText()
            store.show(notice: Activity(symbol: "hourglass", title: title, detail: reset), limited: true)
            telegram.send(.limitReached, "\(TelegramEmoji.limit) \(escapeHTML(title))" + (reset.isEmpty ? "" : "\n\(escapeHTML(reset))"))
        case .restored(let limit):
            let title = tr("\(limit.name) снова доступен", "\(limit.name) is back")
            let detail = tr("Claude может работать дальше", "Claude can get back to work")
            store.show(notice: Activity(symbol: "battery.100.bolt", title: title, detail: detail), limited: false, for: 5)
            telegram.send(.limitBack, "\(TelegramEmoji.back) \(escapeHTML(title))\n\(escapeHTML(detail))")
        }
    }

    private func news(_ news: Store.News) {
        switch news {
        case .done(let s):
            limits.lookAgain()
            telegram.send(.done, Self.message(TelegramEmoji.done, tr("Готово", "Done"), s))
        case .failed(let s) where s.rateLimited:
            limits.lookAgain(urgent: true)
            // Without fresh limits to go by (Claude Code's login in the keychain expired: it's renewed
            // only when Claude Code runs in a terminal), the turn that hit the limit tells it, in Claude
            // Code's words: "5-hour limit reached ∙ resets 5pm". Once in half an hour at most.
            let fresh = limits.checked.map { Date().timeIntervalSince($0) < 15 * 60 } ?? false
            guard !fresh, Date().timeIntervalSince(lastLimitNotice) > 30 * 60 else { return }
            lastLimitNotice = Date()
            let title = tr("Лимит исчерпан", "Limit reached")
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in  // after the turn's own word
                self?.store.show(notice: Activity(symbol: "hourglass", title: title, detail: s.activity.detail), limited: true)
            }
            telegram.send(.limitReached, "\(TelegramEmoji.limit) \(escapeHTML(title))" + (s.project.isEmpty ? "" : " · \(escapeHTML(s.project))")
                          + (s.activity.detail.isEmpty ? "" : "\n\(escapeHTML(s.activity.detail))"))
        case .failed(let s):
            limits.lookAgain()
            telegram.send(.failed, Self.message(TelegramEmoji.failed, s.activity.title, s))
        case .waiting(let s):
            // Only if it's still waiting half a minute later, with nothing new since: a request answered
            // at the Mac needs no message. A question comes twice at once; the later one goes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self, let now = self.store.sessions[s.id], now.phase == .waiting, now.lastEvent == s.lastEvent else { return }
                // A question goes with its buttons instead.
                if self.questions.active, self.store.prompts.contains(where: { $0.sessionID == s.id && $0.form != nil }) { return }
                self.telegram.send(.waiting, Self.message(TelegramEmoji.waiting, now.activity.title, now))
            }
        }
    }

    /// "✅ Done · ClaudeNotch", then how long it took and how many actions, as Telegram's HTML. Nothing of
    /// what you or Claude wrote: it's a nudge, not a copy of the session.
    private static func message(_ emoji: String, _ title: String, _ s: Session) -> String {
        var lines = ["\(emoji) " + escapeHTML(s.project.isEmpty ? title : "\(title) · \(s.project)")]
        // A turn that ended has its summary ("in 9s · 3 actions"): the note under Claude's last line, or
        // the detail without one. Mid-turn (a permission request) there's none.
        let a = s.activity
        let summary = s.turnEnd == nil ? "" : !a.note.isEmpty ? a.note : a.detail
        if !summary.isEmpty { lines.append(escapeHTML(summary)) }
        return lines.joined(separator: "\n")
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
    /// it's plain it got there. A copy that's installed already is quit and put in the Trash.
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

    /// Always to /Applications, as build.sh installs it: one copy. One from before in ~/Applications goes too.
    private func copyToApplications() throws -> URL {
        let fm = FileManager.default
        let name = Bundle.main.bundleURL.lastPathComponent
        let copy = URL(fileURLWithPath: "/Applications").appendingPathComponent(name)
        let old = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").appendingPathComponent(name)

        // Quit first: put in the Trash while it runs, the old copy would offer to remove everything.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != .current }
        others.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while others.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }

        if fm.fileExists(atPath: copy.path) { try fm.trashItem(at: copy, resultingItemURL: nil) }
        if fm.fileExists(atPath: old.path) { try? fm.trashItem(at: old, resultingItemURL: nil) }
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
                "Claude Notch добавит свои хуки в ~/.claude/settings.json: так Claude Code будет сообщать ему, что делает. Остальные настройки останутся как были, а исходный файл сохранится рядом. Отключить можно в настройках: меню Clawd в строке меню → «Настройки…».",
                "Claude Notch adds its hooks to ~/.claude/settings.json, so Claude Code tells it what it's doing. Your other settings stay as they are, and the original file is saved next to it. You can disconnect in the settings: Clawd's menu in the menu bar → Settings….")
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
