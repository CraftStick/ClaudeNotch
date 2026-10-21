import AppKit

enum DisplayMode: Equatable { case hidden, compact, expanded, permission, details }

/// Turns Claude Code hook events into what the notch shows. Main thread only.
final class Store: ObservableObject {
    enum Decision { case allow, allowAlways, deny, askInApp }

    static let soundsKey = "sounds"
    /// The glowing rim around the island, on unless switched off in the menu.
    static let rimKey = "rim"
    /// Clawd stays in the notch for good, busy with his own pastimes, instead of walking off after a
    /// rest. Off unless switched on in the menu.
    static let aliveKey = "alwaysAlive"
    static var alive: Bool { UserDefaults.standard.bool(forKey: aliveKey) }

    @Published private(set) var sessions: [String: Session] = [:] { didSet { syncTicking() } }
    @Published private(set) var expanded = false
    @Published private(set) var focusID: String?
    @Published private(set) var prompts: [PermissionPrompt] = []  // oldest first
    /// The pointer rests on the notch: show the details card.
    @Published private(set) var hovering = false
    /// A session clicked in the card's list of others: the card shows it until the pointer leaves.
    @Published private(set) var pickedID: String?
    /// Shown when the app is opened and nothing else is in the notch: "Ready to work", a click opens Claude.
    @Published private(set) var greeting: Session? { didSet { syncTicking() } }
    static let greetingID = "greeting"
    /// What a second copy of the app sends before it quits, so this one greets you.
    static let openedMessage = Data(#"{"hook_event_name":"ClaudeNotchOpened"}"#.utf8)
    private let transcripts = TranscriptWatcher()
    private var collapseWork: DispatchWorkItem?
    private var hoverWork: DispatchWorkItem?
    /// The notch can be seen: no sleeping display, locked screen or other user at the Mac. While it can't,
    /// nothing in it moves and nothing ticks; it all catches up from the clock when it can be seen again.
    @Published private(set) var onScreen = true
    private var motionTimer: Timer?
    private var nextPrune = Date.distantPast
    /// Copies of the sounds playing now. NSSound(named:) hands out one shared object per sound,
    /// which won't start again while it's still playing (two sessions finishing together), and a
    /// copy has to stay alive until it ends.
    private var playingSounds: [NSSound] = []

    /// Sounds and the rim are on unless switched off in the menu. Registered at launch: tests run
    /// without them.
    static let defaults: [String: Any] = [soundsKey: true, rimKey: true]

    init() {
        transcripts.onInterrupt = { [weak self] id in self?.interrupted(id) }
        transcripts.onUsage = { [weak self] id, usage in self?.recordUsage(id, usage) }
        transcripts.onThought = { [weak self] id, thought, written in self?.recordThought(id, thought, written: written) }
        transcripts.onWrite = { [weak self] id in self?.recordWrite(id) }
    }

    func screen(visible: Bool) {
        guard visible != onScreen else { return }
        onScreen = visible
        syncTicking()
    }

    /// The clock ticks once a second while something in the notch depends on it: a session, at work or
    /// resting, or the greeting, which leaves after a while unless Clawd lives in the notch. Otherwise, and
    /// while the notch can't be seen, it doesn't wake the Mac up at all.
    private func syncTicking() {
        let needed = onScreen && (!sessions.isEmpty || (greeting != nil && !Self.alive))
        if needed, motionTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            timer.tolerance = 0.3  // needn't be on time: lets macOS bundle the wakeup with others
            motionTimer = timer
        } else if !needed, let timer = motionTimer {
            timer.invalidate()
            motionTimer = nil
        }
    }

    /// Sessions where Claude is busy or waiting, most recent first.
    var working: [Session] {
        sessions.values.filter { $0.phase.isActive }.sorted { $0.lastEvent > $1.lastEvent }
    }

    var prompt: PermissionPrompt? { prompts.first }

    /// What the hover card shows: the session picked in it, the busy one, or else the last one that finished.
    var detailsSession: Session? {
        if let id = pickedID, let s = sessions[id] { return s }
        return working.first ?? sessions.values.max { $0.lastEvent < $1.lastEvent }
    }

    /// Shows another session in the card; a click on the card then opens that one.
    func pick(_ id: String) {
        guard sessions[id] != nil else { return }
        pickedID = id
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
        return working.first ?? resting ?? greeting
    }

    var mode: DisplayMode {
        if prompt != nil { return .permission }
        if hovering, detailsSession != nil { return .details }
        if expanded, let id = focusID, sessions[id] != nil { return .expanded }
        if !working.isEmpty || resting != nil { return .compact }
        guard greeting != nil else { return .hidden }
        return expanded || hovering ? .expanded : .compact  // the greeting opens while new or under the pointer
    }

    /// The other sessions for the hover card, most recent first.
    func others(than id: String?) -> [Session] {
        Array(sessions.values.filter { $0.id != id }.sorted { $0.lastEvent > $1.lastEvent }.prefix(DetailsLayout.maxOtherRows))
    }

    /// Brings the app the session runs in to the front; the greeting opens Claude and goes away.
    /// Living in the notch for good, Clawd is there with Claude closed too, easy to brush against: a click
    /// only makes him hop and wave, unless he's in the middle of something.
    func focus(_ id: String) {
        EventLog.append("Focus \(id)")
        if id == Self.greetingID {
            guard !Self.alive else { return poke() }
            greeting = nil
            if let app = AppFocus.claudeApp { AppFocus.open(app) }
            return
        }
        guard let s = sessions[id] else { return }
        if s.host == AppFocus.claudeBundleID || s.entrypoint == "claude-desktop" {
            AppFocus.openInClaudeApp(id) { AppFocus.show(host: s.host, folder: s.cwd, tty: s.tty) }
        } else {
            AppFocus.show(host: s.host, folder: s.cwd, tty: s.tty)
        }
    }

    /// Sessions Claude was already at work in when the app started: shown now rather than at their
    /// next hook event, which may be a while off if Claude is writing a long answer.
    func adopt(_ running: [TranscriptWatcher.Running]) {
        let now = Date()
        for r in running where sessions[r.id] == nil {
            var s = Session(id: r.id, turnStart: r.started ?? now, lastEvent: now)
            s.cwd = r.cwd
            s.project = (r.cwd as NSString).lastPathComponent
            s.transcriptPath = r.path
            s.entrypoint = r.entrypoint
            s.host = r.entrypoint == "claude-desktop" ? AppFocus.claudeBundleID : AppFocus.lastHost
            s.task = Describe.prompt(r.task).text
            if let tool = r.tool {
                s.phase = .tool
                s.activity = Describe.tool(tool.name, tool.input)
                s.currentTool = s.activity
            } else {
                s.phase = .thinking
            }
            EventLog.append("Adopted running session (transcript)")
            commit(s, expandFor: nil)
        }
    }

    /// The app was opened, at launch or again from Finder or Spotlight: show that it runs. With nothing
    /// in the notch Clawd hops, waves and says he's ready; otherwise the notch opens on Claude for a
    /// moment, and a resting Clawd wakes up to say hi.
    func greet() {
        let now = Date()
        let shown = working.first ?? resting
        if let shown, !shown.phase.isActive {
            update(shown.id) { s, now in s.play(.hello, at: now) }
        }
        if shown == nil {
            greeting = Self.makeGreeting(at: now)
        }
        focusID = shown?.id ?? Self.greetingID
        expanded = true
        scheduleCollapse(after: 5)
    }

    /// "Stays in the notch" was just switched on: Clawd floats in under a parachute where you can see
    /// him, a resting session's Clawd too. One at work carries on.
    func moveIn() {
        let now = Date()
        if let shown = working.first ?? resting, !shown.phase.isActive {
            update(shown.id) { s, now in s.play(.arrive, at: now) }
        }
        greeting = Self.makeGreeting(at: now, cue: .arrive)
    }

    private func poke() {
        guard let g = greeting else { return }
        let now = Date()
        if let laptop = ClawdAssets.laptop, let waving = ClawdAssets.waving,
           ClawdAnimator(session: g, laptop: laptop, waving: waving).frame(at: now).busy { return }
        greeting?.play(.hello, at: now)
    }

    /// Clawd on his own in the notch, hopping and waving hello (or floating in under a parachute):
    /// "Ready to work", a click opens Claude.
    private static func makeGreeting(at now: Date, cue: Cue = .hello) -> Session {
        var g = Session(id: greetingID, turnStart: now, lastEvent: now)
        let app = AppFocus.claudeApp.map { $0.deletingPathExtension().lastPathComponent }
        g.activity = Activity(symbol: "hand.wave.fill", title: tr("Готов к работе", "Ready to work"),
                              detail: app.map { tr("Нажми, чтобы открыть \($0)", "Click to open \($0)") } ?? "")
        g.play(cue, at: now)
        return g
    }

    /// Called often with where the pointer is; opens the card after a short rest, so passing over the
    /// menu bar doesn't flicker, and closes it as soon as the pointer leaves: all the way down, not to
    /// the row it opened over, which a question would keep up until it's answered. The next time the
    /// card opens on the freshest session again.
    func pointer(inside: Bool) {
        let wanted = inside && prompt == nil && (detailsSession ?? greeting) != nil
        guard wanted != hovering else {
            hoverWork?.cancel()
            hoverWork = nil
            return
        }
        guard hoverWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverWork = nil
            self.hovering = wanted
            if !wanted {
                self.pickedID = nil
                self.collapse()
            }
        }
        hoverWork = work
        // Leaving waits one more look at the pointer (it's polled every 0.1 s), for a pointer on the edge.
        DispatchQueue.main.asyncAfter(deadline: .now() + (wanted ? 0.3 : 0.1), execute: work)
    }

    func handle(_ json: [String: Any]?, reply: HookReply) {
        guard let json, let event = json["hook_event_name"] as? String else {
            reply.send(nil)
            return
        }
        let toolName = json["tool_name"] as? String ?? ""
        let toolInput = json["tool_input"] as? [String: Any] ?? [:]
        EventLog.append(toolName.isEmpty ? event : "\(event) \(toolName)")
        if event == "ClaudeNotchOpened" {
            reply.send(nil)
            greet()
            return
        }

        let id = json["session_id"] as? String ?? "default"
        let agentID = (json["agent_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let now = Date()
        let known = sessions[id] != nil
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
            AppFocus.lastHost = host
        }
        if let entry = json["notch_entry"] as? String, !entry.isEmpty {
            s.entrypoint = entry
        }
        if let tty = json["notch_tty"] as? String, !tty.isEmpty {
            s.tty = tty
        }
        s.lastEvent = now

        if event == "PermissionRequest" {
            // A newer request from the same agent means its older one was answered elsewhere.
            dropPrompts(for: id) { $0.agentID == agentID }
            s.phase = .waiting
            let activity = Describe.tool(toolName, toolInput)
            // A question Claude asks you comes through here too: its options become the buttons.
            let form = toolName == "AskUserQuestion" ? QuestionForm(toolInput) : nil
            if form != nil, let question = Describe.question(toolName, toolInput) {
                s.activity = question
            } else {
                s.activity = Activity(symbol: "hand.raised.fill", title: tr("Ждёт разрешения", "Waiting for permission"),
                                      detail: activity.detail, monospaced: activity.monospaced)
            }
            let prompt = PermissionPrompt(sessionID: id, agentID: agentID,
                                          question: Describe.permissionQuestion(toolName, activity),
                                          activity: activity,
                                          suggestions: json["permission_suggestions"] as? [[String: Any]] ?? [],
                                          input: toolInput, form: form, reply: reply)
            prompts.append(prompt)
            // In a terminal, hand the question back to the usual prompt after a while instead of
            // holding it for the hook's full ~10 minutes; a question takes longer to read.
            expire(prompt, after: s.dialogRunsInParallel ? 590 : form == nil ? 20 : 90)
            chime("Tink", for: &s)
            commit(s, expandFor: .infinity)
            return
        }
        reply.send(nil)

        // A subagent's events carry the parent's session id plus its own agent id.
        if let agentID {
            if !known {
                guard event != "SubagentStop" else { return }  // a stray stop for a session we never saw
                s.phase = .tool  // the app started while a subagent was already at work
                s.activity = Describe.tool("Task", [:])
            }
            if event == "PostToolUse" || event == "PostToolUseFailure" {
                dropPrompts(for: id) { $0.agentID == agentID }  // answered in the app or terminal
                if s.phase == .waiting, !prompts.contains(where: { $0.sessionID == id }) {
                    s.phase = .tool  // back to waiting for the subagents
                    s.activity = s.currentTool ?? Describe.tool("Task", [:])
                }
            }
            handleAgent(event, agentID: agentID, type: json["agent_type"] as? String ?? "", tool: toolName, input: toolInput, session: &s)
            commit(s, expandFor: nil)
            return
        }

        switch event {
        case "UserPromptSubmit":
            dropPrompts(for: id)
            let said = Describe.prompt(json["prompt"] as? String ?? "")
            s.phase = .thinking
            s.startTurn(at: now)
            if let notice = said.notice {
                // Claude picks up a background task that finished: the task is still the one you gave it.
                if s.task.isEmpty { s.task = said.text }
                s.activity = notice
            } else {
                s.task = said.text
                s.activity = Activity(symbol: "sparkle", title: tr("Взялся за задачу", "New task"), detail: said.text, prose: true)
                s.play(.idea, at: now)
            }
            commit(s, expandFor: 3)

        case "PreToolUse":
            if !s.phase.isActive {  // new turn we didn't see a prompt for
                s.startTurn(at: now)
                s.task = ""
            }
            s.actions += 1
            if TaskList.handles(toolName) { s.tasks.apply(toolName, toolInput, useID: json["tool_use_id"] as? String) }
            let previousTool = s.recentTools.last ?? .distantPast
            s.recentTools = Array((s.recentTools + [now]).suffix(8))
            if toolName == "Task" || toolName == "Agent" {
                s.pendingAgents.append([toolInput["subagent_type"] as? String ?? "", oneLine(toolInput["description"] as? String ?? "")])
            }
            if let question = Describe.question(toolName, toolInput) {
                s.phase = .waiting
                s.activity = question
                s.currentTool = question
                chime("Tink", for: &s)
                commit(s, expandFor: .infinity)
            } else {
                s.phase = .tool
                s.activity = Describe.tool(toolName, toolInput)
                // What Claude wrote since its previous tool is why it runs this one. (Written before
                // that tool, it was about that one and only reached the transcript after it.)
                if !s.activity.quiet, !s.thought.isEmpty {
                    if s.activity.note.isEmpty, s.thoughtWritten > previousTool { s.activity.reason = s.thought }
                    s.thought = ""
                }
                s.currentTool = s.activity
                // Not opened for every tool, which would keep the notch moving the whole time Claude
                // works: what it runs shows under the pointer.
                commit(s, expandFor: nil)
            }

        case "PostToolUse", "PostToolUseFailure":
            // The main agent's request was answered elsewhere; a finished Task ends its subagents' too.
            let endsSubagents = s.currentTool?.agent == true
            dropPrompts(for: id) { endsSubagents || $0.agentID == nil }
            if !known { s.phase = .thinking }  // the app started mid-turn: Claude is between tools
            guard s.phase.isActive else { return }
            if TaskList.handles(toolName) { s.tasks.finish(toolName, response: json["tool_response"], useID: json["tool_use_id"] as? String) }
            // A failure Claude now has to deal with. An abort isn't one: Esc shows as "Stopped".
            let failed = event == "PostToolUseFailure" && json["is_interrupt"] as? Bool != true
            // Recorded from currentTool, not the shown activity: a tool approved in the app's own
            // dialog arrives here while the notch still says "Waiting for permission".
            if var tool = s.currentTool, !tool.quiet {
                tool.failed = failed
                s.record(tool)
                if event == "PostToolUse" {
                    s.linesAdded += tool.added
                    s.linesRemoved += tool.removed
                    s.failStreak = 0
                    if toolName == "Bash", let cue = Describe.cheer(for: toolInput["command"] as? String ?? "") { s.play(cue, at: now) }
                } else if failed {
                    s.toolFailed(at: now)
                }
            }
            let tool = s.currentTool ?? Describe.tool(toolName, toolInput)
            s.currentTool = nil
            s.phase = .thinking
            if failed, !tool.quiet {
                // What went wrong stays up until Claude writes its next thought or picks its next tool.
                s.activity = Describe.failure(toolName, tool, error: json["error"] as? String ?? "")
                s.failedAt = now
                commit(s, expandFor: 2.5)
            } else {
                commit(s, expandFor: nil)
            }

        case "PermissionDenied":
            // Auto mode turned the tool down (a dialog you answer "no" in sends no hook); Claude carries on without it.
            dropPrompts(for: id) { $0.agentID == nil }
            let tool = s.currentTool ?? Describe.tool(toolName, toolInput)
            if !tool.quiet {
                var denied = tool
                denied.failed = true
                s.record(denied)
            }
            s.currentTool = nil
            s.phase = .thinking
            // "[Irreversible Local Destruction]": the rule it matched.
            let reason = oneLine(json["reason"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            s.activity = Activity(symbol: "nosign", title: tr("Авторежим запретил действие", "Auto mode blocked this"),
                                  detail: tool.command ? tool.detail : tool.headline, monospaced: tool.command,
                                  note: reason, failed: true)
            s.failedAt = now
            s.play(.shrug, at: now)  // not a failure: Claude carries on another way
            commit(s, expandFor: 4)

        case "Elicitation":
            // An MCP server asks you for something mid-tool: a form, or a page to open. Its dialog shows as usual.
            let server = json["mcp_server_name"] as? String ?? ""
            let page = json["mode"] as? String == "url"
            s.phase = .waiting
            s.activity = Activity(symbol: page ? "safari" : "keyboard",
                                  title: page ? tr("MCP-сервер просит открыть страницу", "An MCP server asks you to open a page")
                                              : tr("MCP-сервер просит данные", "An MCP server needs your input"),
                                  detail: oneLine(json["message"] as? String ?? ""), note: Describe.server(server), prose: true)
            chime("Tink", for: &s)
            commit(s, expandFor: .infinity)

        case "ElicitationResult":
            // Answered: back to the tool that asked.
            guard s.phase == .waiting, !prompts.contains(where: { $0.sessionID == id }) else { return }
            if let tool = s.currentTool {
                s.phase = .tool
                s.activity = tool
            } else {
                s.phase = .thinking
                s.activity = .thinking
            }
            commit(s, expandFor: nil)

        case "Notification":
            let message = json["message"] as? String ?? ""
            let type = json["notification_type"] as? String ?? ""
            // "Claude is waiting for your input" after a finished turn is just noise.
            if type == "idle_prompt" || message.localizedCaseInsensitiveContains("waiting for your input") { return }
            // Only dialogs that wait for you: "elicitation_complete" and "elicitation_response" mean it's over.
            let dialogs = ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input", ""]
            guard dialogs.contains(type) else { return }
            if prompts.contains(where: { $0.sessionID == id }) { return }  // already asking in the notch
            // The Elicitation hook has put it up already, in the server's own words.
            if type.hasPrefix("elicitation"), s.phase == .waiting { return }
            s.phase = .waiting
            s.activity = Activity(symbol: "hand.raised.fill",
                                  title: type == "permission_prompt" ? tr("Ждёт разрешения", "Waiting for permission") : tr("Ждёт тебя", "Waiting for you"),
                                  detail: oneLine(message))
            chime("Tink", for: &s)
            commit(s, expandFor: .infinity)

        case "PreCompact":
            // Only mid-turn: a manual /compact between turns isn't Claude at work.
            guard known, s.phase.isActive else { return }
            s.activity = .compacting
            commit(s, expandFor: nil)

        case "PostCompact":
            // Done compacting: back to work, rather than "Compacting" until the next tool.
            guard known, s.phase.isActive, s.activity == .compacting else { return }
            s.activity = s.currentTool ?? .thinking(about: s.thought)
            commit(s, expandFor: nil)

        case "Stop":
            dropPrompts(for: id)
            s.turnEnd = now
            s.currentTool = nil
            // How the reply ends: its last line, from the hook or else the transcript.
            let reply = (json["last_assistant_message"] as? String) ?? s.transcriptPath.flatMap(TranscriptWatcher.lastReply)
            let last = reply.flatMap(TranscriptWatcher.lastLine) ?? ""
            if last.hasSuffix("?") || last.hasSuffix("？") {
                // It ended with a question: Claude waits for your answer.
                s.phase = .waiting
                s.activity = Activity(symbol: "questionmark.bubble.fill", title: tr("Ждёт ответа", "Waiting for your answer"),
                                      detail: last, note: summary(s, until: now), prose: true)
                let away = chime("Tink", for: &s)
                commit(s, expandFor: away ? 8 : 4)
                return
            }
            s.phase = .done
            s.activity = last.isEmpty
                ? Activity(symbol: "checkmark.circle.fill", title: tr("Готово", "Done"), detail: summary(s, until: now))
                : Activity(symbol: "checkmark.circle.fill", title: tr("Готово", "Done"), detail: last, note: summary(s, until: now), prose: true)
            // A big task (5+ minutes or 150+ changed lines) gets confetti instead of a hop.
            if now.timeIntervalSince(s.turnStart) >= 300 || s.linesAdded + s.linesRemoved >= 150 {
                s.play(.celebrate, at: now)
            }
            // If you're in another app, the result stays up longer, with a sound.
            let away = chime("Glass", for: &s)
            commit(s, expandFor: away ? 8 : 4)

        case "StopFailure":
            dropPrompts(for: id)
            s.phase = .failed
            s.rateLimited = json["error"] as? String == "rate_limit"
            s.turnEnd = now
            s.currentTool = nil
            // `error` is the kind ("rate_limit"); the message is the error as Claude Code shows it
            // ("API Error: Rate limit reached"), often with when to try again.
            let message = json["last_assistant_message"] as? String ?? json["error_details"] as? String ?? ""
            s.activity = Activity(symbol: "exclamationmark.triangle.fill", title: Describe.apiError(json["error"] as? String ?? ""),
                                  detail: oneLine(message), note: summary(s, until: now), prose: true)
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

    /// Plays `sound` while sounds are on in the menu, once for events that come together. Whether the
    /// session's app is in front says little (the Claude app has many sessions, a terminal many tabs),
    /// so it only decides how long the result stays up: returns whether you're in another app.
    @discardableResult
    private func chime(_ sound: String, for s: inout Session) -> Bool {
        if s.takesChime(at: Date()), UserDefaults.standard.bool(forKey: Self.soundsKey),
           let copy = NSSound(named: sound)?.copy() as? NSSound {
            playingSounds.removeAll { !$0.isPlaying }
            playingSounds.append(copy)
            copy.play()
            EventLog.append("Sound \(sound)")
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return s.host == nil || front != s.host
    }

    /// Claude wrote down a thought or a message: the notch shows what it thinks about, or why it runs the
    /// tool it has just started, under the pointer. Claude Code writes the text out around the time of
    /// the call, often a moment after the tool's hook.
    private func recordThought(_ id: String, _ thought: String, written: Date) {
        guard var s = sessions[id] else { return }
        switch s.phase {
        case .thinking:
            s.thought = thought
            s.thoughtWritten = written
            s.lastEvent = Date()
            // A failure stays up until Claude has something new to say. What it wrote before the tool
            // only reaches the transcript after the tool's hook, so it would hide the failure at once.
            if s.activity.failed, written <= s.failedAt {
                sessions[id] = s
                return
            }
            s.activity = .thinking(about: thought)
        case .tool where s.activity.aside.isEmpty && !s.activity.quiet:
            s.activity.reason = thought
            if s.currentTool?.aside.isEmpty == true { s.currentTool?.reason = thought }
        default:
            return
        }
        commit(s, expandFor: nil)
    }

    /// The transcript grew. Noted at most every 10 seconds: it only serves to notice long silences.
    private func recordWrite(_ id: String) {
        let now = Date()
        guard let s = sessions[id], now.timeIntervalSince(s.lastWrite) > 10 else { return }
        sessions[id]?.lastWrite = now
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
                s.lastEvent = now  // the tool starts now, not when it asked
                s.phase = .tool
                // Back to what the agent was doing: the approved tool, or a Task whose subagent asked.
                s.activity = s.currentTool ?? prompt.activity
            }
        case .deny:
            prompt.reply.send(Self.permissionOutput(["behavior": "deny", "message": tr("Пользователь отклонил это действие.", "The user denied this action.")]))
            update(id) { s, now in
                s.play(.facepalm, at: now)
                s.lastFacepalm = now
                s.lastEvent = now
                if prompt.agentID != nil, let task = s.currentTool {
                    s.phase = .tool  // the subagent carries on without it
                    s.activity = task
                } else {
                    s.phase = .thinking
                    s.activity = Activity(symbol: "xmark.circle.fill", title: tr("Отклонено", "Denied"), detail: prompt.activity.detail)
                }
            }
        case .askInApp:
            prompt.reply.send(nil)  // no decision: Claude Code's own dialog takes over
        }
        if prompts.isEmpty { scheduleCollapse(after: decision == .askInApp ? 0.3 : 1.2) }
    }

    /// Picks option `index` of the question on show: the answer to it, or a tick where it takes several
    /// (sent with `submitPicked`). After the last question the answers go to Claude Code.
    func choose(_ prompt: PermissionPrompt, option index: Int) {
        guard let at = prompts.firstIndex(of: prompt), var form = prompts[at].form,
              form.current.options.indices.contains(index) else { return }
        if form.current.multiSelect {
            if !form.picked.insert(index).inserted { form.picked.remove(index) }
            prompts[at].form = form
        } else {
            advance(at, form, with: [index])
        }
    }

    /// Answers a question that takes several options with the ones ticked.
    func submitPicked(_ prompt: PermissionPrompt) {
        guard let at = prompts.firstIndex(of: prompt), let form = prompts[at].form, !form.picked.isEmpty else { return }
        advance(at, form, with: Array(form.picked))
    }

    private func advance(_ at: Int, _ form: QuestionForm, with options: [Int]) {
        var form = form
        guard form.answer(options) else {
            prompts[at].form = form
            return
        }
        let prompt = prompts.remove(at: at)
        var input = prompt.input
        input["answers"] = form.answers
        prompt.reply.send(Self.permissionOutput(["behavior": "allow", "updatedInput": input]))
        EventLog.append("Answered \(form.answers.count) question(s) from the notch")
        let summary = form.questions.compactMap { form.answers[$0.text] }.joined(separator: " · ")
        update(prompt.sessionID) { s, now in
            s.play(.excited, at: now)
            s.lastEvent = now
            s.phase = .tool
            s.activity = Activity(symbol: "checkmark.bubble.fill", title: tr("Ответ отправлен", "Answer sent"), detail: summary, prose: true)
        }
        if prompts.isEmpty { scheduleCollapse(after: 1.2) }
    }

    /// Requests that were answered elsewhere (or replaced) quietly close their hook.
    /// `match` narrows it down, e.g. to one agent's requests.
    private func dropPrompts(for sessionID: String, where match: (PermissionPrompt) -> Bool = { _ in true }) {
        let stale = prompts.filter { $0.sessionID == sessionID && match($0) }
        guard !stale.isEmpty else { return }
        prompts.removeAll { stale.contains($0) }
        stale.forEach { $0.reply.send(nil) }
        if prompts.isEmpty && expanded && collapseWork == nil { scheduleCollapse(after: 1) }
    }

    /// Hands a request nobody answered back to Claude Code's own prompt.
    private func expire(_ prompt: PermissionPrompt, after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.prompts.contains(prompt) else { return }
            self.answer(prompt, .askInApp)
        }
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
        // Claude is here, and the greeting gives way. Living in the notch for good, Clawd stays on in
        // it for when the sessions are gone: made again, he'd float in under a parachute every time.
        if !Self.alive { greeting = nil }
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
        s.activity = Activity(symbol: "stop.circle.fill", title: tr("Остановлено", "Stopped"), detail: summary(s, until: now))
        commit(s, expandFor: 3)
    }

    /// Safety net for anything we missed: stale sessions quietly time out. Worked out from the clock, so it
    /// catches up after a while without ticks.
    private func prune() {
        let now = Date()
        for (id, s) in sessions {
            let idle = now.timeIntervalSince(max(s.lastEvent, s.lastWrite))  // a long reply is no hook event
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
    /// When he lives in the notch for good, the greeting stays instead, and comes back if it's gone.
    /// Every 10 seconds, stale sessions too.
    private func tick() {
        let now = Date()
        if now >= nextPrune {
            nextPrune = now.addingTimeInterval(10)
            prune()
        }
        if Self.alive {
            if greeting == nil { greeting = Self.makeGreeting(at: now, cue: .arrive) }
        } else if let g = greeting, now.timeIntervalSince(g.lastEvent) > Self.restDuration {
            greeting = nil
        }
        for (id, s) in sessions {
            if !s.phase.isActive, now.timeIntervalSince(s.turnEnd ?? s.lastEvent) > Self.restDuration {
                sessions[id] = nil
            } else if s.desiredMotion(at: now) != s.motion {
                sessions[id]?.syncMotion(at: now)
            }
        }
    }
}

private func summary(_ s: Session, until end: Date) -> String {
    let time = tr("за ", "in ") + formatElapsed(end.timeIntervalSince(s.turnStart))
    guard s.actions > 0 else { return time }
    return time + " · " + actionsText(s.actions)
}
