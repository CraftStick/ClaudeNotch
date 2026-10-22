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
    private let state = SettingsState()

    init(actions: SettingsActions, updates: Updates) {
        self.actions = actions
        self.updates = updates
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(actions: actions, updates: updates, state: state))
            window.center()
            self.window = window
        }
        state.connected = actions.isConnected()
        state.atLogin = actions.opensAtLogin()
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
    @ObservedObject var state: SettingsState
    @AppStorage(Store.soundsKey) private var sounds = true
    @AppStorage(Store.rimKey) private var rim = true
    @AppStorage(Store.aliveKey) private var alive = false
    @AppStorage(Store.quietKey) private var quiet = false
    @AppStorage(HotKeyChoice.key) private var hotKeys = HotKeyChoice.controlOptionCommand.rawValue
    @AppStorage(Language.key) private var language = ""

    var body: some View {
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

            Section {
                Toggle(isOn: Binding(get: { updates.enabled }, set: { updates.enabled = $0 })) {
                    Label(tr("Проверять обновления", "Check for updates"), systemImage: "arrow.down.circle")
                    Text(tr("Раз в день на GitHub. Иначе приложение не выходит в сеть.",
                            "Once a day, on GitHub. Otherwise the app never goes online."))
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
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
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
