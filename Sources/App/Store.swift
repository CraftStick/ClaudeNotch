import Foundation

enum Phase: Equatable {
    case thinking, tool, waiting, done, stopped, failed

    var isActive: Bool { self == .thinking || self == .tool || self == .waiting }
}

enum DisplayMode: Equatable { case hidden, compact, expanded, permission }

struct Activity: Equatable {
    var symbol: String
    var title: String
    var detail: String
    var monospaced = false

    static let thinking = Activity(symbol: "sparkle", title: "Думает…", detail: "")
}

struct Session: Equatable {
    let id: String
    var project = ""
    var transcriptPath: String?
    var phase = Phase.thinking
    var activity = Activity.thinking
    var turnStart: Date
    var turnEnd: Date?
    var lastEvent: Date
    var actions = 0
}

/// A PermissionRequest hook that waits for a click in the notch.
struct PermissionPrompt: Identifiable, Equatable {
    let id = UUID()
    let sessionID: String
    let question: String
    let activity: Activity
    let created = Date()
    let reply: HookReply

    static func == (a: PermissionPrompt, b: PermissionPrompt) -> Bool { a.id == b.id }
}

/// Turns Claude Code hook events into what the notch shows. Main thread only.
final class Store: ObservableObject {
    enum Decision { case allow, deny, askInApp }

    @Published private(set) var sessions: [String: Session] = [:]
    @Published private(set) var expanded = false
    @Published private(set) var focusID: String?
    @Published private(set) var prompts: [PermissionPrompt] = []  // oldest first
    private let transcripts = TranscriptWatcher()
    private var collapseWork: DispatchWorkItem?
    private var pruneTimer: Timer?

    init() {
        transcripts.onInterrupt = { [weak self] id in self?.interrupted(id) }
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.prune()
        }
    }

    /// Sessions where Claude is busy or waiting, most recent first.
    var working: [Session] {
        sessions.values.filter { $0.phase.isActive }.sorted { $0.lastEvent > $1.lastEvent }
    }

    var prompt: PermissionPrompt? { prompts.first }

    var focused: Session? {
        if let p = prompt, let s = sessions[p.sessionID] { return s }
        if expanded, let id = focusID, let s = sessions[id] { return s }
        return working.first
    }

    var mode: DisplayMode {
        if prompt != nil { return .permission }
        if expanded, let id = focusID, sessions[id] != nil { return .expanded }
        return working.isEmpty ? .hidden : .compact
    }

    func handle(_ data: Data, reply: HookReply) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = json["hook_event_name"] as? String else {
            reply.send(nil)
            return
        }
        let toolName = json["tool_name"] as? String ?? ""
        let toolInput = json["tool_input"] as? [String: Any] ?? [:]
        EventLog.append(toolName.isEmpty ? event : "\(event) \(toolName)")

        let id = json["session_id"] as? String ?? "default"
        let now = Date()
        var s = sessions[id] ?? Session(id: id, turnStart: now, lastEvent: now)
        if let cwd = json["cwd"] as? String, !cwd.isEmpty {
            s.project = (cwd as NSString).lastPathComponent
        }
        if let path = json["transcript_path"] as? String, !path.isEmpty {
            s.transcriptPath = path
        }
        s.lastEvent = now

        if event == "PermissionRequest" {
            dropPrompts(for: id)
            s.phase = .waiting
            let activity = Describe.tool(toolName, toolInput)
            s.activity = Activity(symbol: "hand.raised.fill", title: "Ждёт разрешения",
                                  detail: activity.detail, monospaced: activity.monospaced)
            prompts.append(PermissionPrompt(sessionID: id, question: Describe.permissionQuestion(toolName, activity),
                                            activity: activity, reply: reply))
            commit(s, expandFor: .infinity)
            return
        }
        reply.send(nil)

        switch event {
        case "UserPromptSubmit":
            dropPrompts(for: id)
            s.phase = .thinking
            s.turnStart = now
            s.turnEnd = nil
            s.actions = 0
            s.activity = Activity(symbol: "sparkle", title: "Взялся за задачу",
                                  detail: oneLine(json["prompt"] as? String ?? ""))
            commit(s, expandFor: 3)

        case "PreToolUse":
            if !s.phase.isActive {  // new turn we didn't see a prompt for
                s.turnStart = now
                s.turnEnd = nil
                s.actions = 0
            }
            s.actions += 1
            if let question = Describe.question(toolName, toolInput) {
                s.phase = .waiting
                s.activity = question
                commit(s, expandFor: .infinity)
            } else {
                s.phase = .tool
                s.activity = Describe.tool(toolName, toolInput)
                commit(s, expandFor: 2.5)
            }

        case "PostToolUse", "PostToolUseFailure":
            dropPrompts(for: id)
            guard s.phase.isActive else { return }
            s.phase = .thinking
            commit(s, expandFor: nil)

        case "Notification":
            let message = json["message"] as? String ?? ""
            let type = json["notification_type"] as? String ?? ""
            // "Claude is waiting for your input" after a finished turn is just noise.
            if type == "idle_prompt" || message.localizedCaseInsensitiveContains("waiting for your input") { return }
            guard type == "permission_prompt" || type.hasPrefix("elicitation") || type == "agent_needs_input" || type.isEmpty else { return }
            if prompts.contains(where: { $0.sessionID == id }) { return }  // already asking in the notch
            s.phase = .waiting
            s.activity = Activity(symbol: "hand.raised.fill",
                                  title: type == "permission_prompt" ? "Ждёт разрешения" : "Ждёт тебя",
                                  detail: oneLine(message))
            commit(s, expandFor: .infinity)

        case "PreCompact":
            s.activity = Activity(symbol: "archivebox", title: "Сжимает контекст", detail: "")
            commit(s, expandFor: 2.5)

        case "Stop":
            dropPrompts(for: id)
            s.phase = .done
            s.turnEnd = now
            s.activity = Activity(symbol: "checkmark.circle.fill", title: "Готово", detail: summary(s, until: now))
            commit(s, expandFor: 4)

        case "StopFailure":
            dropPrompts(for: id)
            s.phase = .failed
            s.turnEnd = now
            let error = json["last_assistant_message"] as? String ?? json["error"] as? String ?? ""
            s.activity = Activity(symbol: "exclamationmark.triangle.fill", title: "Ошибка", detail: oneLine(error))
            commit(s, expandFor: 6)

        case "SessionEnd":
            dropPrompts(for: id)
            transcripts.stop(sessionID: id)
            sessions[id] = nil
            if focusID == id { collapse() }

        default:
            return
        }
    }

    // MARK: - Permission prompts

    func answer(_ prompt: PermissionPrompt, _ decision: Decision) {
        guard let index = prompts.firstIndex(of: prompt) else { return }
        prompts.remove(at: index)
        let id = prompt.sessionID

        switch decision {
        case .allow:
            prompt.reply.send(Self.permissionOutput(["behavior": "allow"]))
            sessions[id]?.phase = .tool
            sessions[id]?.activity = prompt.activity
        case .deny:
            prompt.reply.send(Self.permissionOutput(["behavior": "deny", "message": "Пользователь отклонил это действие."]))
            sessions[id]?.phase = .thinking
            sessions[id]?.activity = Activity(symbol: "xmark.circle.fill", title: "Отклонено", detail: prompt.activity.detail)
        case .askInApp:
            prompt.reply.send(nil)  // no decision: Claude Code's own dialog takes over
        }
        if prompts.isEmpty { scheduleCollapse(after: decision == .askInApp ? 0.3 : 1.2) }
    }

    /// Requests that were answered elsewhere (or replaced) quietly close their hook.
    private func dropPrompts(for sessionID: String) {
        guard prompts.contains(where: { $0.sessionID == sessionID }) else { return }
        prompts.removeAll { p in
            guard p.sessionID == sessionID else { return false }
            p.reply.send(nil)
            return true
        }
        if prompts.isEmpty && expanded && collapseWork == nil { scheduleCollapse(after: 1) }
    }

    private static func permissionOutput(_ decision: [String: Any]) -> Data? {
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return try? JSONSerialization.data(withJSONObject: output)
    }

    // MARK: - Expand / collapse

    /// `expandFor`: seconds to stay expanded (`.infinity` = until the next event), nil = don't expand.
    private func commit(_ s: Session, expandFor seconds: TimeInterval?) {
        sessions[s.id] = s
        if s.phase.isActive, let path = s.transcriptPath {
            transcripts.watch(sessionID: s.id, path: path)
        } else if !s.phase.isActive {
            transcripts.stop(sessionID: s.id)
        }

        guard let seconds else {
            // Left open by "waiting"? The session moved on, so close it.
            if expanded, collapseWork == nil, focusID == s.id { scheduleCollapse(after: 1) }
            return
        }
        focusID = s.id
        expanded = true
        collapseWork?.cancel()
        collapseWork = nil
        if seconds.isFinite { scheduleCollapse(after: seconds) }
    }

    private func scheduleCollapse(after seconds: TimeInterval) {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.collapse() }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func collapse() {
        collapseWork?.cancel()
        collapseWork = nil
        expanded = false
    }

    /// Esc: Claude Code sends no hook, the transcript watcher tells us.
    private func interrupted(_ id: String) {
        guard var s = sessions[id], s.phase.isActive else { return }
        EventLog.append("Interrupt (transcript)")
        dropPrompts(for: id)
        let now = Date()
        s.phase = .stopped
        s.turnEnd = now
        s.lastEvent = now
        s.activity = Activity(symbol: "stop.circle.fill", title: "Остановлено", detail: summary(s, until: now))
        commit(s, expandFor: 3)
    }

    /// Safety net for anything we missed: stale sessions and prompts quietly time out.
    private func prune() {
        let now = Date()
        for p in prompts where now.timeIntervalSince(p.created) > 600 {
            answer(p, .askInApp)
        }
        for (id, s) in sessions {
            let idle = now.timeIntervalSince(s.lastEvent)
            switch s.phase {
            case .done where idle > 600, .stopped where idle > 600, .failed where idle > 600:
                sessions[id] = nil
            case .thinking where idle > 600, .tool where idle > 1800, .waiting where idle > 1800:
                sessions[id]?.phase = .done
                sessions[id]?.turnEnd = s.lastEvent
                transcripts.stop(sessionID: id)
            default:
                break
            }
        }
    }

    // MARK: - Demo

    func runDemo() {
        let id = "demo-\(UUID().uuidString)"
        let steps: [(TimeInterval, [String: Any])] = [
            (0.0, ["hook_event_name": "UserPromptSubmit", "prompt": "Сделай статус Claude в чёлке MacBook"]),
            (2.5, ["hook_event_name": "PreToolUse", "tool_name": "Read", "tool_input": ["file_path": "/src/NotchView.swift"]]),
            (3.5, ["hook_event_name": "PostToolUse"]),
            (5.0, ["hook_event_name": "PreToolUse", "tool_name": "Edit", "tool_input": ["file_path": "/src/Store.swift"]]),
            (6.0, ["hook_event_name": "PostToolUse"]),
            (8.0, ["hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": "rm -rf build && ./build.sh"]]),
            // 12 s to try the buttons (nothing real is allowed or denied), then the turn ends.
            (20.0, ["hook_event_name": "PostToolUse"]),
            (21.0, ["hook_event_name": "Stop"]),
        ]
        for (delay, var payload) in steps {
            payload["session_id"] = id
            payload["cwd"] = "/Users/demo/ClaudeNotch"
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.handle(data, reply: .none) }
        }
    }
}

// MARK: - Formatting

enum Describe {
    static func tool(_ name: String, _ input: [String: Any]) -> Activity {
        func str(_ key: String) -> String { input[key] as? String ?? "" }
        func file(_ key: String = "file_path") -> String { (str(key) as NSString).lastPathComponent }

        switch name {
        case "Bash":
            return Activity(symbol: "terminal", title: "Выполняет команду", detail: oneLine(str("command")), monospaced: true)
        case "BashOutput":
            return Activity(symbol: "terminal", title: "Смотрит вывод команды", detail: "")
        case "Read":
            return Activity(symbol: "doc.text", title: "Читает файл", detail: file())
        case "Edit", "MultiEdit":
            return Activity(symbol: "pencil", title: "Редактирует", detail: file())
        case "Write":
            return Activity(symbol: "doc.badge.plus", title: "Пишет файл", detail: file())
        case "NotebookEdit":
            return Activity(symbol: "pencil", title: "Редактирует блокнот", detail: file("notebook_path"))
        case "Grep":
            return Activity(symbol: "magnifyingglass", title: "Ищет в коде", detail: oneLine(str("pattern")), monospaced: true)
        case "Glob":
            return Activity(symbol: "folder", title: "Ищет файлы", detail: oneLine(str("pattern")), monospaced: true)
        case "WebSearch":
            return Activity(symbol: "globe", title: "Ищет в интернете", detail: oneLine(str("query")))
        case "WebFetch":
            return Activity(symbol: "globe", title: "Читает страницу", detail: host(str("url")))
        case "Task", "Agent":
            return Activity(symbol: "person.2", title: "Запускает агента", detail: oneLine(str("description")))
        case "TodoWrite":
            return Activity(symbol: "checklist", title: "Обновляет план", detail: "")
        case "Skill":
            return Activity(symbol: "book", title: "Читает навык", detail: str("skill"))
        case "ToolSearch":
            return Activity(symbol: "wrench.and.screwdriver", title: "Подключает инструменты", detail: "")
        default:
            return mcp(name, input)
        }
    }

    /// Tools that stop and wait for the user to answer.
    static func question(_ name: String, _ input: [String: Any]) -> Activity? {
        switch name {
        case "AskUserQuestion":
            let first = (input["questions"] as? [[String: Any]])?.first?["question"] as? String ?? ""
            return Activity(symbol: "questionmark.bubble.fill", title: "Задаёт тебе вопрос", detail: oneLine(first))
        case "ExitPlanMode":
            return Activity(symbol: "list.bullet.clipboard", title: "Ждёт одобрения плана", detail: "")
        default:
            return nil
        }
    }

    static func permissionQuestion(_ tool: String, _ activity: Activity) -> String {
        switch tool {
        case "Bash": return "Разрешить команду?"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "Разрешить изменить файл?"
        case "WebFetch": return "Разрешить открыть страницу?"
        case "WebSearch": return "Разрешить поиск в интернете?"
        case "Read", "Grep", "Glob": return "Разрешить чтение?"
        default: return "Разрешить «\(activity.title)»?"
        }
    }

    /// MCP tools are named `mcp__<server>__<tool>`.
    private static func mcp(_ name: String, _ input: [String: Any]) -> Activity {
        let parts = name.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp" else {
            return Activity(symbol: "hammer", title: name, detail: "")
        }
        let server = parts[1]
        let tool = parts[2...].joined(separator: "__")
        switch tool {
        case "update_plan": return Activity(symbol: "checklist", title: "Обновляет план", detail: "")
        case "wrap_up": return Activity(symbol: "flag.checkered", title: "Подводит итог", detail: "")
        default: break
        }
        if server.localizedCaseInsensitiveContains("browser") || server.localizedCaseInsensitiveContains("chrome") {
            let url = input["url"] as? String
            return Activity(symbol: "safari", title: "Браузер", detail: url.map(host) ?? pretty(tool))
        }
        let isOpaqueID = server.count >= 32 && server.allSatisfy { $0.isHexDigit || $0 == "-" }
        return Activity(symbol: "puzzlepiece.extension", title: isOpaqueID ? "MCP" : pretty(server), detail: pretty(tool))
    }

    private static func pretty(_ s: String) -> String { s.replacingOccurrences(of: "_", with: " ") }

    private static func host(_ url: String) -> String { URL(string: url)?.host ?? url }
}

/// Last events, for checking which hooks actually reach the app.
enum EventLog {
    private static let formatter = ISO8601DateFormatter()

    static func append(_ line: String) {
        let path = Paths.eventLog
        let data = Data("\(formatter.string(from: Date())) \(line)\n".utf8)
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size > 256_000 {
            try? FileManager.default.removeItem(atPath: path)
        }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}

func oneLine(_ text: String) -> String {
    let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    return String(line.trimmingCharacters(in: .whitespaces).prefix(200))
}

func formatElapsed(_ interval: TimeInterval) -> String {
    let s = max(0, Int(interval))
    if s < 60 { return "\(s)с" }
    if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
    return String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
}

private func summary(_ s: Session, until end: Date) -> String {
    let time = "за " + formatElapsed(end.timeIntervalSince(s.turnStart))
    guard s.actions > 0 else { return time }
    return time + " · \(s.actions) " + plural(s.actions, "действие", "действия", "действий")
}

private func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let n10 = n % 10, n100 = n % 100
    if n10 == 1 && n100 != 11 { return one }
    if (2...4).contains(n10) && !(12...14).contains(n100) { return few }
    return many
}
