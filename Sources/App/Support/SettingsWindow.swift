import AppKit
import SwiftUI

/// What the settings change that the rest of the app has to act on, given by the app delegate.
struct SettingsActions {
    var isConnected: () -> Bool
    var setConnected: (Bool) -> Void
    var opensAtLogin: () -> Bool
    var setOpensAtLogin: (Bool) -> Void
    var setAlive: (Bool) -> Void
    /// The language, the rim or the shortcuts changed: redraw the notch, the menu, the hot keys.
    var changed: () -> Void
}

/// Claude Notch's settings, in a window of their own (Clawd's menu → Settings…, ⌘,).
final class SettingsWindow {
    private var window: NSWindow?
    private let actions: SettingsActions
    private let updates: Updates
    private let limits: PlanLimits
    private let telegram: Telegram
    private let state = SettingsState()

    init(actions: SettingsActions, updates: Updates, limits: PlanLimits, telegram: Telegram) {
        self.actions = actions
        self.updates = updates
        self.limits = limits
        self.telegram = telegram
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(actions: actions, updates: updates, limits: limits,
                                                                                      telegram: telegram, state: state))
            window.center()
            self.window = window
        }
        state.connected = actions.isConnected()
        state.atLogin = actions.opensAtLogin()
        limits.lookAgain()
        if telegram.linked { telegram.refresh() }
        window?.title = tr("Настройки Claude Notch", "Claude Notch Settings")
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// What the window shows that lives outside UserDefaults: read again each time it opens.
final class SettingsState: ObservableObject {
    @Published var connected = false
    @Published var atLogin = false
}

struct SettingsView: View {
    let actions: SettingsActions
    @ObservedObject var updates: Updates
    @ObservedObject var limits: PlanLimits
    @ObservedObject var telegram: Telegram
    @ObservedObject var state: SettingsState
    @AppStorage(Store.soundsKey) private var sounds = true
    @AppStorage(Store.rimKey) private var rim = true
    @AppStorage(Store.aliveKey) private var alive = false
    @AppStorage(Store.quietKey) private var quiet = false
    @AppStorage(HotKeyChoice.key) private var hotKeys = HotKeyChoice.controlOptionCommand.rawValue
    @AppStorage(Language.key) private var language = ""

    var body: some View {
        // Two short pages rather than one long one, which didn't fit on a laptop's screen.
        TabView {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Claude Notch")
                                .font(.title3.weight(.semibold))
                            Text(tr("Claude Code в чёлке · версия \(Updates.current)", "Claude Code in the notch · version \(Updates.current)"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Link(destination: URL(string: "https://github.com/CraftStick/ClaudeNotch")!) {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .help("GitHub")
                    }
                    .padding(.vertical, 2)
                }

                Section(tr("Основное", "General")) {
                    Toggle(isOn: Binding(get: { state.connected }, set: { actions.setConnected($0); refresh() })) {
                        Label(tr("Подключено к Claude Code", "Connected to Claude Code"), systemImage: "link")
                        Text(tr("Хуки в ~/.claude/settings.json: так Claude Code сообщает, что делает.",
                                "Hooks in ~/.claude/settings.json, so Claude Code tells it what it's doing."))
                    }
                    Toggle(isOn: Binding(get: { state.atLogin }, set: { actions.setOpensAtLogin($0); refresh() })) {
                        Label(tr("Запускать при входе", "Open at login"), systemImage: "arrow.up.forward.app")
                    }
                    Picker(selection: Binding(get: { language }, set: { pick(language: $0) })) {
                        Text(tr("Как в системе", "System")).tag("")
                        Text("English").tag(Language.en.rawValue)
                        Text("Русский").tag(Language.ru.rawValue)
                    } label: {
                        Label(tr("Язык", "Language"), systemImage: "globe")
                    }
                }

                Section {
                    Toggle(isOn: Binding(get: { updates.enabled }, set: { updates.enabled = $0 })) {
                        Label(tr("Проверять обновления", "Check for updates"), systemImage: "arrow.down.circle")
                        Text(tr("Раз в день на GitHub.",
                                "Once a day, on GitHub."))
                    }
                    HStack {
                        Text(statusText)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if case .available(_, let page) = updates.status {
                            Button(tr("Скачать", "Download")) { NSWorkspace.shared.open(page) }
                        }
                        Button(tr("Проверить сейчас", "Check Now")) { updates.check() }
                            .disabled(updates.status == .checking)
                    }
                } header: {
                    Text(tr("Обновления", "Updates"))
                }
            }
            .formStyle(.grouped)
            .tabItem { Label(tr("Основное", "General"), systemImage: "gearshape") }
            Form {
                Section(tr("Чёлка", "Notch")) {
                    Toggle(isOn: $sounds) {
                        Label(tr("Звук, когда готово или нужен ответ", "Sound when done or waiting for you"), systemImage: "speaker.wave.2")
                    }
                    .onChange(of: sounds) { _, on in if on { NSSound(named: "Glass")?.play() } }
                    Toggle(isOn: $rim) {
                        Label(tr("Переливающаяся обводка", "Glowing rim"), systemImage: "sparkles")
                    }
                    .onChange(of: rim) { actions.changed() }
                    Toggle(isOn: $quiet) {
                        Label(tr("Тихая чёлка", "Quiet notch"), systemImage: "moon")
                        Text(tr("Чёлка пустая, пока Claude работает: появляется, только когда он ждёт тебя или закончил.",
                                "The notch stays empty while Claude works: it shows up only when Claude waits for you or is done."))
                    }
                    .onChange(of: quiet) { actions.changed() }
                    Toggle(isOn: Binding(get: { alive }, set: { alive = $0; actions.setAlive($0) })) {
                        Label(tr("Clawd живёт в чёлке всегда", "Clawd stays in the notch"), systemImage: "pawprint")
                        Text(tr("Когда у Claude нет дел, он остаётся и сам находит себе занятие.",
                                "When Claude has nothing on, he stays and keeps himself busy."))
                    }
                }

                Section {
                    Picker(selection: $hotKeys) {
                        ForEach(HotKeyChoice.allCases, id: \.rawValue) { choice in
                            Text(choice == .off ? tr("Выключены", "Off") : choice.symbols).tag(choice.rawValue)
                        }
                    } label: {
                        Label(tr("Ответ из чёлки", "Answering from the notch"), systemImage: "keyboard")
                    }
                    .onChange(of: hotKeys) { actions.changed() }
                } header: {
                    Text(tr("Горячие клавиши", "Shortcuts"))
                } footer: {
                    Text(HotKeyChoice.current == .off
                         ? tr("Отвечать можно только кликом по чёлке.", "Answer with a click on the notch only.")
                         : tr("\(HotKeyChoice.current.label("Y")) — разрешить, \(HotKeyChoice.current.label("N")) — запретить, \(HotKeyChoice.current.label("1"))…4 — ответ на вопрос. Заняты, только пока висит запрос.",
                              "\(HotKeyChoice.current.label("Y")) allows, \(HotKeyChoice.current.label("N")) denies, \(HotKeyChoice.current.label("1"))…4 answer a question. Taken only while a request is up."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

            }
            .formStyle(.grouped)
            .tabItem { Label(tr("Чёлка", "Notch"), systemImage: "menubar.rectangle") }
            NotificationsPage(limits: limits, telegram: telegram)
                .tabItem { Label(tr("Уведомления", "Notifications"), systemImage: "bell") }
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .tint(claudeOrange)  // switches and buttons in Claude's colour
        .id(language)  // every label again in the language just picked
        .onAppear(perform: refresh)
    }

    private var statusText: String {
        switch updates.status {
        case .idle: return tr("Версия \(Updates.current)", "Version \(Updates.current)")
        case .checking: return tr("Проверяю…", "Checking…")
        case .upToDate: return tr("Версия \(Updates.current) — самая новая", "Version \(Updates.current) is the latest")
        case .available(let version, _): return tr("Вышла версия \(version)", "Version \(version) is out")
        case .failed: return tr("Не получилось проверить", "Couldn't check")
        }
    }

    private func refresh() {
        state.connected = actions.isConnected()
        state.atLogin = actions.opensAtLogin()
    }

    private func pick(language choice: String) {
        Language.choice = Language(rawValue: choice)
        language = choice
        actions.changed()
    }
}

/// The plan's limits, and notifications in Telegram.
private struct NotificationsPage: View {
    @ObservedObject var limits: PlanLimits
    @ObservedObject var telegram: Telegram

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { limits.enabled }, set: { limits.enabled = $0 })) {
                    Label(tr("Следить за лимитами плана", "Watch the plan's limits"), systemImage: "hourglass")
                    Text(tr("Чёлка скажет, когда лимит закончился и когда он снова есть. Пока Claude работает, приложение раз в несколько минут спрашивает о них api.anthropic.com, входя как Claude Code.",
                            "The notch tells you when a limit runs out and when it's back. While Claude works, the app asks api.anthropic.com about them every few minutes, signed in as Claude Code."))
                }
                if limits.enabled {
                    ForEach(limits.limits, id: \.kind) { LimitRow(limit: $0) }
                }
            } header: {
                Text(tr("Лимиты", "Limits"))
            }

            Section {
                TelegramRow(telegram: telegram)
            } header: {
                Text("Telegram")
            } footer: {
                Text(tr("Через бота Claude Notch: он знает только твой чат. Уведомления уходят, даже когда чёлку не видно.",
                        "Through Claude Notch's bot, which knows nothing but your chat. They go out while the notch can't be seen too."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if telegram.linked {
                Section(tr("Что присылать в Telegram", "What to send to Telegram")) {
                    ForEach(TelegramNote.allCases, id: \.self) { NoteToggle(note: $0, changed: telegram.syncPrefs) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// "Session limit · resets in 4 h 51 min · 4 %", over a bar.
private struct LimitRow: View {
    let limit: PlanLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(limit.name)
                Spacer()
                Text(limit.resetText())
                    .foregroundStyle(.secondary)
                Text("\(Int(limit.used.rounded())) %")
                    .monospacedDigit()
                    .foregroundStyle(limit.exhausted ? .red : .secondary)
            }
            ProgressView(value: min(limit.used, 100), total: 100)
                .tint(limit.exhausted ? .red : claudeOrange)
        }
    }
}

private struct NoteToggle: View {
    let note: TelegramNote
    let changed: () -> Void
    @AppStorage private var on: Bool

    init(note: TelegramNote, changed: @escaping () -> Void) {
        self.note = note
        self.changed = changed
        _on = AppStorage(wrappedValue: false, note.key)
    }

    var body: some View {
        // Set from here only: what the chat switched comes in without being sent back.
        Toggle(isOn: Binding(get: { on }, set: { on = $0; changed() })) { Label(note.label, systemImage: note.symbol) }
    }
}

/// Linked, with a test message and a way out; or a code to send the bot.
private struct TelegramRow: View {
    @ObservedObject var telegram: Telegram

    var body: some View {
        if let chat = telegram.chat {
            HStack {
                Label(tr("Подключено: \(chat)", "Linked: \(chat)"), systemImage: "paperplane.fill")
                Spacer()
                Button(tr("Проверить", "Test")) { telegram.sendTest() }
                Button(tr("Отключить", "Unlink")) { telegram.unlink() }
            }
        } else {
            switch telegram.linking {
            case .idle, .failed:
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(tr("Уведомления в Telegram", "Notifications in Telegram"), systemImage: "paperplane")
                        Text(telegram.linking == .failed
                             ? tr("Не получилось связаться с ботом, попробуй ещё раз.", "Couldn't reach the bot, try again.")
                             : tr("Возьми код и отправь его боту: так он узнает, куда писать.", "Get a code and send it to the bot, so it knows where to write."))
                            .font(.callout)
                            .foregroundStyle(telegram.linking == .failed ? .red : .secondary)
                    }
                    Spacer()
                    Button(tr("Получить код", "Get Code")) { telegram.requestCode() }
                }
            case .asking:
                HStack {
                    Text(tr("Спрашиваю код…", "Getting a code…")).foregroundStyle(.secondary)
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            case .code(let code, let link, let bot, _):
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(code.prefix(4) + "-" + code.dropFirst(4))
                            .font(.system(size: 24, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                    Text(tr("Отправь этот код боту \(bot.isEmpty ? "" : "@" + bot) или открой ссылку: он сам его отправит. Код действует 15 минут.",
                            "Send this code to the bot\(bot.isEmpty ? "" : " @" + bot), or open the link, which sends it for you. The code works for 15 minutes."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(tr("Открыть в Telegram", "Open in Telegram")) { NSWorkspace.shared.open(link) }
                            .keyboardShortcut(.defaultAction)
                        Button(tr("Скопировать код", "Copy Code")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                        }
                    }
                }
            }
        }
    }
}
