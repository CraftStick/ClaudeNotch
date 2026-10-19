import AppKit

enum Phase: Equatable {
    case thinking, tool, waiting, done, stopped, failed

    var isActive: Bool { self == .thinking || self == .tool || self == .waiting }
}

enum DisplayMode: Equatable { case hidden, compact, expanded, permission, details }

struct Activity: Equatable {
    var symbol: String
    var title: String
    var detail: String
    var monospaced = false
    /// Extra line for the hover card, e.g. the description Claude gave a shell command.
    var note = ""
    /// Bookkeeping (plan updates, loading tools): doesn't pop the notch open or go into history.
    var quiet = false
    /// Lines an edit adds and removes.
    var added = 0
    var removed = 0
    /// `detail` is a shell command: lists show its description instead of the code.
    var command = false
    /// A Task/Agent call: subagents are at work.
    var agent = false

    static let thinking = Activity(symbol: "sparkle", title: "Думает…", detail: "")

    /// One readable line for lists: "Читает файл · Store.swift", or for a command what it does
    /// ("Собрать и установить приложение") rather than the command itself.
    var headline: String {
        if command { return note.isEmpty ? title : note }
        return detail.isEmpty ? title : "\(title) · \(detail)"
    }
}

/// A subagent Claude started with the Task/Agent tool. Its tool calls arrive with the parent's
/// session id plus an `agent_id`.
struct SubAgent: Equatable {
    let id: String
    var type: String
    var task = ""
    var activity: Activity?
    var actions = 0
    let started: Date
    var finished: Date?
}

/// What Clawd is doing in the notch.
enum Motion: Equatable {
    /// At the laptop; thinking hard (a speech bubble); at the desk while a long command runs;
    /// running while subagents work or tools fly by; waving while waiting for you;
    /// resting after a turn that ended in one of three ways.
    case typing, pondering, desktop, running, waving, done, stopped, failed
}

/// A one-off reaction Clawd plays over whatever he is doing: an idea when a task comes in,
/// joy when you allow something, a facepalm when a tool fails or you say no,
/// confetti after a big task.
enum Cue: Equatable { case idea, excited, facepalm, celebrate }

struct Session: Equatable {
    let id: String
    var project = ""
    var cwd = ""
    /// Bundle id of the app the session runs in (Terminal, VS Code, Claude…), for click-to-focus.
    var host: String?
    var transcriptPath: String?
    var phase = Phase.thinking
    /// Clawd's current and previous motion, so the notch can play the change between them.
    private(set) var motion = Motion.done
    private(set) var previousMotion = Motion.done
    private(set) var motionStart = Date()
    /// A one-off reaction, and what Clawd was doing when it started (to put the laptop away first).
    private(set) var cue: Cue?
    private(set) var cueStart = Date.distantPast
    private(set) var cueInterrupted = Motion.done
    var lastFacepalm = Date.distantPast
    /// When the last few tools started, to notice a burst of them.
    var recentTools: [Date] = []
    var activity = Activity.thinking
    /// The message that started this turn.
    var task = ""
    /// Finished actions of this turn, oldest first (the last few only).
    var history: [Activity] = []
    var agents: [SubAgent] = []
    /// Task/Agent calls whose subagent hasn't announced itself yet: (type, description).
    var pendingAgents: [[String]] = []
    var turnStart: Date
    var turnEnd: Date?
    var lastEvent: Date
    var actions = 0
    var linesAdded = 0
    var linesRemoved = 0
    /// From the transcript: tokens in the context now, and output tokens written this turn.
    var contextTokens = 0
    var contextWindow = 200_000
    var turnOutputTokens = 0
    var lastMessage = ""
    var lastMessageOutput = 0

    /// What Clawd should be doing now. Some of it depends on time: thinking for a while,
    /// a command that runs long, a burst of tools.
    func desiredMotion(at now: Date) -> Motion {
        let quiet = now.timeIntervalSince(lastEvent)
        switch phase {
        case .waiting: return .waving
        case .done: return .done
        case .stopped: return .stopped
        case .failed: return .failed
        case .tool:
            if activity.agent || isBusy(at: now) { return .running }
            return activity.command && quiet > 8 ? .desktop : .typing
        case .thinking:
            if isBusy(at: now) { return .running }
            return quiet > 12 ? .pondering : .typing
        }
    }

    /// Six or more tools in the last 12 seconds.
    private func isBusy(at now: Date) -> Bool {
        recentTools.filter { now.timeIntervalSince($0) < 12 }.count >= 6
    }

    mutating func syncMotion(at now: Date) {
        let next = desiredMotion(at: now)
        guard next != motion else { return }
        previousMotion = motion
        motion = next
        motionStart = now
    }

    mutating func play(_ cue: Cue, at now: Date) {
        self.cue = cue
        cueStart = now
        cueInterrupted = motion
    }

    mutating func startTurn(at date: Date) {
        turnStart = date
        turnEnd = nil
        actions = 0
        history = []
        linesAdded = 0
        linesRemoved = 0
        turnOutputTokens = 0
        agents.removeAll { $0.finished != nil }
    }
}

/// A PermissionRequest hook that waits for a click in the notch.
struct PermissionPrompt: Identifiable, Equatable {
    let id = UUID()
    let sessionID: String
    let question: String
    let activity: Activity
    /// Claude Code's `permission_suggestions`: the rules "Allow always" sends back.
    let suggestions: [[String: Any]]
    let created = Date()
    let reply: HookReply

    /// What "Allow always" would add, e.g. `Bash(npm run lint:*)`.
    var ruleSummary: String? {
        guard let first = suggestions.first else { return nil }
        if let rule = (first["rules"] as? [[String: Any]])?.first, let tool = rule["toolName"] as? String {
            let content = rule["ruleContent"] as? String ?? ""
            return content.isEmpty ? tool : "\(tool)(\(content))"
        }
        if let mode = first["mode"] as? String { return "режим \(mode)" }
        if let dir = (first["directories"] as? [String])?.first { return "папка \((dir as NSString).lastPathComponent)" }
        return nil
    }

    static func == (a: PermissionPrompt, b: PermissionPrompt) -> Bool { a.id == b.id }
}

/// Turns Claude Code hook events into what the notch shows. Main thread only.
final class Store: ObservableObject {
    enum Decision { case allow, allowAlways, deny, askInApp }

    static let soundsKey = "sounds"

    @Published private(set) var sessions: [String: Session] = [:]
    @Published private(set) var expanded = false
    @Published private(set) var focusID: String?
    @Published private(set) var prompts: [PermissionPrompt] = []  // oldest first
    /// The pointer rests on the notch: show the details card.
    @Published private(set) var hovering = false
    private let transcripts = TranscriptWatcher()
    private var collapseWork: DispatchWorkItem?
    private var hoverWork: DispatchWorkItem?
    private var pruneTimer: Timer?
    private var motionTimer: Timer?

    init() {
        UserDefaults.standard.register(defaults: [Self.soundsKey: true])
        transcripts.onInterrupt = { [weak self] id in self?.interrupted(id) }
        transcripts.onUsage = { [weak self] id, usage in self?.recordUsage(id, usage) }
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.prune()
        }
        motionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// Sessions where Claude is busy or waiting, most recent first.
    var working: [Session] {
        sessions.values.filter { $0.phase.isActive }.sorted { $0.lastEvent > $1.lastEvent }
    }

    var prompt: PermissionPrompt? { prompts.first }

    /// What the hover card shows: the busy session, or else the last one that finished.
    var detailsSession: Session? {
        working.first ?? sessions.values.max { $0.lastEvent < $1.lastEvent }
    }

    /// How long Clawd stays in the notch after a turn ends.
    static let restDuration: TimeInterval = 15 * 60

    /// The most recent session that finished less than `restDuration` ago.
    var resting: Session? {
        let now = Date()
        return sessions.values
            .filter { !$0.phase.isActive && now.timeIntervalSince($0.turnEnd ?? $0.lastEvent) < Self.restDuration }
            .max { $0.lastEvent < $1.lastEvent }
    }

    var focused: Session? {
        if let p = prompt, let s = sessions[p.sessionID] { return s }
        if hovering, let s = detailsSession { return s }
        if expanded, let id = focusID, let s = sessions[id] { return s }
        return working.first ?? resting
    }

    var mode: DisplayMode {
        if prompt != nil { return .permission }
        if hovering, detailsSession != nil { return .details }
        if expanded, let id = focusID, sessions[id] != nil { return .expanded }
        return working.isEmpty && resting == nil ? .hidden : .compact
    }

    /// The other sessions for the hover card, most recent first.
    func others(than id: String?) -> [Session] {
        Array(sessions.values.filter { $0.id != id }.sorted { $0.lastEvent > $1.lastEvent }.prefix(DetailsLayout.maxOtherRows))
    }

    /// Brings the app the session runs in to the front.
    func focus(_ id: String) {
        guard let s = sessions[id] else { return }
        AppFocus.show(host: s.host, folder: s.cwd)
    }

    /// Called often with where the pointer is; opens the card after a short rest, closes it
    /// a moment after the pointer leaves, so passing over the menu bar doesn't flicker.
    func pointer(inside: Bool) {
        let wanted = inside && prompt == nil && detailsSession != nil
        guard wanted != hovering else {
            hoverWork?.cancel()
            hoverWork = nil
            return
        }
        guard hoverWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.hoverWork = nil
            self?.hovering = wanted
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (wanted ? 0.3 : 0.35), execute: work)
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
            s.cwd = cwd
        }
        if let path = json["transcript_path"] as? String, !path.isEmpty {
            s.transcriptPath = path
        }
        if let host = AppFocus.host(bundleID: json["notch_host"] as? String ?? "", termProgram: json["notch_term"] as? String ?? "") {
            s.host = host
        }
        s.lastEvent = now

        if event == "PermissionRequest" {
            dropPrompts(for: id)
            s.phase = .waiting
            let activity = Describe.tool(toolName, toolInput)
            s.activity = Activity(symbol: "hand.raised.fill", title: "Ждёт разрешения",
                                  detail: activity.detail, monospaced: activity.monospaced)
            prompts.append(PermissionPrompt(sessionID: id, question: Describe.permissionQuestion(toolName, activity),
                                            activity: activity,
                                            suggestions: json["permission_suggestions"] as? [[String: Any]] ?? [],
                                            reply: reply))
            chime("Tink", for: s)
            commit(s, expandFor: .infinity)
            return
        }
        reply.send(nil)

        // A subagent's events carry the parent's session id plus its own agent id.
        if let agentID = json["agent_id"] as? String, !agentID.isEmpty {
            handleAgent(event, agentID: agentID, type: json["agent_type"] as? String ?? "", tool: toolName, input: toolInput, session: &s)
            commit(s, expandFor: nil)
            return
        }

        switch event {
        case "UserPromptSubmit":
            dropPrompts(for: id)
            let prompt = json["prompt"] as? String ?? ""
            s.phase = .thinking
            s.startTurn(at: now)
            s.task = String(prompt.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(300))
            s.activity = Activity(symbol: "sparkle", title: "Взялся за задачу", detail: oneLine(prompt))
            s.play(.idea, at: now)
            commit(s, expandFor: 3)

        case "PreToolUse":
            if !s.phase.isActive {  // new turn we didn't see a prompt for
                s.startTurn(at: now)
                s.task = ""
            }
            s.actions += 1
            s.recentTools = Array((s.recentTools + [now]).suffix(8))
            if toolName == "Task" || toolName == "Agent" {
                s.pendingAgents.append([toolInput["subagent_type"] as? String ?? "", oneLine(toolInput["description"] as? String ?? "")])
            }
            if let question = Describe.question(toolName, toolInput) {
                s.phase = .waiting
                s.activity = question
                chime("Tink", for: s)
                commit(s, expandFor: .infinity)
            } else {
                s.phase = .tool
                s.activity = Describe.tool(toolName, toolInput)
                commit(s, expandFor: s.activity.quiet ? nil : 2.5)
            }

        case "PostToolUse", "PostToolUseFailure":
            dropPrompts(for: id)
            guard s.phase.isActive else { return }
            if s.phase == .tool, !s.activity.quiet {
                s.history = Array((s.history + [s.activity]).suffix(4))
                if event == "PostToolUse" {
                    s.linesAdded += s.activity.added
                    s.linesRemoved += s.activity.removed
                } else if now.timeIntervalSince(s.lastFacepalm) > 45 {  // not for every failing grep
                    s.play(.facepalm, at: now)
                    s.lastFacepalm = now
                }
            }
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
            chime("Tink", for: s)
            commit(s, expandFor: .infinity)

        case "PreCompact":
            s.activity = Activity(symbol: "archivebox", title: "Сжимает контекст", detail: "")
            commit(s, expandFor: 2.5)

        case "Stop":
            dropPrompts(for: id)
            s.phase = .done
            s.turnEnd = now
            s.activity = Activity(symbol: "checkmark.circle.fill", title: "Готово", detail: summary(s, until: now))
            // A big task (5+ minutes or 150+ changed lines) gets confetti instead of a hop.
            if now.timeIntervalSince(s.turnStart) >= 300 || s.linesAdded + s.linesRemoved >= 150 {
                s.play(.celebrate, at: now)
            }
            // If you're in another app, the result stays up longer, with a sound.
            commit(s, expandFor: chime("Glass", for: s) ? 8 : 4)

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

    // MARK: - Subagents

    private func handleAgent(_ event: String, agentID: String, type: String, tool: String, input: [String: Any],
                             session s: inout Session) {
        let now = Date()
        var agent = s.agents.first { $0.id == agentID } ?? SubAgent(id: agentID, type: type, started: now)
        if agent.type.isEmpty { agent.type = type }
        if agent.task.isEmpty {
            // Match the Task call that started it: same type, oldest first.
            if let i = s.pendingAgents.firstIndex(where: { $0.first == agent.type }) ?? (s.pendingAgents.isEmpty ? nil : 0) {
                agent.task = s.pendingAgents[i].last ?? ""
                s.pendingAgents.remove(at: i)
            }
        }
        switch event {
        case "PreToolUse":
            let activity = Describe.tool(tool, input)
            if !activity.quiet { agent.activity = activity }
            agent.actions += 1
        case "SubagentStop":
            agent.finished = now
        default:
            break
        }
        if let i = s.agents.firstIndex(where: { $0.id == agentID }) {
            s.agents[i] = agent
        } else {
            s.agents.append(agent)
        }
    }

    // MARK: - Sound and usage

    /// Plays `sound` when you're not looking at the app the session runs in.
    /// Returns whether you were away (whether or not sounds are on).
    @discardableResult
    private func chime(_ sound: String, for s: Session) -> Bool {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let away = s.host == nil || front != s.host
        if away, UserDefaults.standard.bool(forKey: Self.soundsKey) {
            NSSound(named: sound)?.play()
        }
        return away
    }

    private func recordUsage(_ id: String, _ usage: TranscriptUsage) {
        guard var s = sessions[id] else { return }
        s.contextTokens = usage.context
        // Only 200K and 1M windows exist; the transcript doesn't say which, so go by what we see.
        if usage.context > s.contextWindow { s.contextWindow = 1_000_000 }
        if !usage.initial {
            // One message is written as several lines with the same id: count it once.
            s.turnOutputTokens += usage.messageID == s.lastMessage ? max(0, usage.output - s.lastMessageOutput) : usage.output
            s.lastMessage = usage.messageID
            s.lastMessageOutput = usage.output
        }
        sessions[id] = s
    }

    // MARK: - Permission prompts

    func answer(_ prompt: PermissionPrompt, _ decision: Decision) {
        guard let index = prompts.firstIndex(of: prompt) else { return }
        prompts.remove(at: index)
        let id = prompt.sessionID

        switch decision {
        case .allow, .allowAlways:
            var output: [String: Any] = ["behavior": "allow"]
            if decision == .allowAlways, !prompt.suggestions.isEmpty {
                output["updatedPermissions"] = prompt.suggestions
            }
            prompt.reply.send(Self.permissionOutput(output))
            update(id) { s, now in
                s.play(.excited, at: now)
                s.phase = .tool
                s.activity = prompt.activity
            }
        case .deny:
            prompt.reply.send(Self.permissionOutput(["behavior": "deny", "message": "Пользователь отклонил это действие."]))
            update(id) { s, now in
                s.play(.facepalm, at: now)
                s.lastFacepalm = now
                s.phase = .thinking
                s.activity = Activity(symbol: "xmark.circle.fill", title: "Отклонено", detail: prompt.activity.detail)
            }
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
    /// Changes a session outside an event, keeping Clawd's motion in step.
    private func update(_ id: String, _ change: (inout Session, Date) -> Void) {
        guard var s = sessions[id] else { return }
        let now = Date()
        change(&s, now)
        s.syncMotion(at: now)
        sessions[id] = s
    }

    private func commit(_ s: Session, expandFor seconds: TimeInterval?) {
        var s = s
        s.syncMotion(at: Date())
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
            case .thinking where idle > 600, .tool where idle > 1800, .waiting where idle > 1800:
                update(id) { s, _ in
                    s.phase = .done
                    s.turnEnd = s.lastEvent
                }
                transcripts.stop(sessionID: id)
            default:
                break
            }
        }
    }

    /// Every second: time-based motions (thinking for a while, a slow command, a burst of tools
    /// ending), and sessions whose rest is over leave the notch — Clawd has walked off by then.
    private func tick() {
        let now = Date()
        for (id, s) in sessions {
            if !s.phase.isActive, now.timeIntervalSince(s.turnEnd ?? s.lastEvent) > Self.restDuration {
                sessions[id] = nil
            } else if s.desiredMotion(at: now) != s.motion {
                sessions[id]?.syncMotion(at: now)
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
            (8.0, ["hook_event_name": "PermissionRequest", "tool_name": "Bash",
                   "tool_input": ["command": "rm -rf build && ./build.sh", "description": "Пересобрать приложение"]]),
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
            return Activity(symbol: "terminal", title: "Выполняет команду", detail: flat(str("command")),
                            monospaced: true, note: oneLine(str("description")), command: true)
        case "BashOutput":
            return Activity(symbol: "terminal", title: "Смотрит вывод команды", detail: "")
        case "Read":
            return Activity(symbol: "doc.text", title: "Читает файл", detail: file())
        case "Edit", "MultiEdit":
            let edits = name == "Edit" ? [input] : input["edits"] as? [[String: Any]] ?? []
            let diff = edits.reduce((added: 0, removed: 0)) { sum, edit in
                let d = lineDiff(edit["old_string"] as? String ?? "", edit["new_string"] as? String ?? "")
                return (sum.added + d.added, sum.removed + d.removed)
            }
            return Activity(symbol: "pencil", title: "Редактирует", detail: file(), added: diff.added, removed: diff.removed)
        case "Write":
            return Activity(symbol: "doc.badge.plus", title: "Пишет файл", detail: file(),
                            added: lineDiff("", str("content")).added)
        case "NotebookEdit":
            return Activity(symbol: "pencil", title: "Редактирует блокнот", detail: file("notebook_path"),
                            added: lineDiff("", str("new_source")).added)
        case "Grep":
            return Activity(symbol: "magnifyingglass", title: "Ищет в коде", detail: oneLine(str("pattern")), monospaced: true,
                            note: str("path").isEmpty ? "" : "в " + file("path"))
        case "Glob":
            return Activity(symbol: "folder", title: "Ищет файлы", detail: oneLine(str("pattern")), monospaced: true)
        case "WebSearch":
            return Activity(symbol: "globe", title: "Ищет в интернете", detail: oneLine(str("query")))
        case "WebFetch":
            return Activity(symbol: "globe", title: "Читает страницу", detail: host(str("url")))
        case "Task", "Agent":
            return Activity(symbol: "person.2", title: "Запускает агента", detail: oneLine(str("description")),
                            note: str("subagent_type"), agent: true)
        case "TodoWrite":
            return Activity(symbol: "checklist", title: "Обновляет план", detail: "", quiet: true)
        case "Skill":
            return Activity(symbol: "book", title: "Читает навык", detail: str("skill"))
        case "ToolSearch":
            return Activity(symbol: "wrench.and.screwdriver", title: "Подключает инструменты", detail: "", quiet: true)
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
        case "update_plan": return Activity(symbol: "checklist", title: "Обновляет план", detail: "", quiet: true)
        case "wrap_up": return Activity(symbol: "flag.checkered", title: "Подводит итог", detail: "", quiet: true)
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

/// Lines added and removed going from `old` to `new`: everything between the common first and
/// last lines counts as changed. Good enough for the small replacements Edit makes.
func lineDiff(_ old: String, _ new: String) -> (added: Int, removed: Int) {
    let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
    let b = new.isEmpty ? [] : new.components(separatedBy: "\n")
    var prefix = 0
    while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
        suffix += 1
    }
    return (b.count - prefix - suffix, a.count - prefix - suffix)
}

/// All lines of `text` on one line, for multi-line shell commands.
func flat(_ text: String) -> String {
    let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    return String(lines.filter { !$0.isEmpty }.joined(separator: " ⏎ ").prefix(300))
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

func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let n10 = n % 10, n100 = n % 100
    if n10 == 1 && n100 != 11 { return one }
    if (2...4).contains(n10) && !(12...14).contains(n100) { return few }
    return many
}
