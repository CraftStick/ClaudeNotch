import Darwin
import Foundation
import Testing
@testable import ClaudeNotch

/// A hook's connection to the app, whose answer can be read back once the app has given it.
final class Hook {
    let reply: HookReply
    private let output: Int32

    init() {
        signal(SIGPIPE, SIG_IGN)  // as in the app: a hook may be gone before it's answered
        var fds: [Int32] = [0, 0]
        precondition(pipe(&fds) == 0)
        output = fds[0]
        reply = HookReply(fd: fds[1])
    }

    deinit { close(output) }

    /// The decision sent back, or nil when the hook was let go without one.
    func decision() -> [String: Any]? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(output, &chunk, chunk.count)
            if n <= 0 { break }
            data.append(chunk, count: n)
        }
        guard !data.isEmpty, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = json["hookSpecificOutput"] as? [String: Any] else { return nil }
        #expect(output["hookEventName"] as? String == "PermissionRequest")
        return output["decision"] as? [String: Any]
    }
}

/// Hook events through the store, as Claude Code sends them. On the main actor, like the app: the
/// store schedules work on the main queue.
@MainActor
struct StoreTests {
    private let store = Store()

    init() {
        UserDefaults.standard.set(Date(), forKey: Store.lastPromptKey)  // not the first task of the day: no stretch
    }

    @discardableResult
    private func send(_ event: String, _ fields: [String: Any] = [:]) -> Hook {
        let hook = Hook()
        var json: [String: Any] = ["hook_event_name": event, "session_id": "s1", "cwd": "/tmp/notch-project"]
        json.merge(fields) { $1 }
        store.handle(json, reply: hook.reply)
        return hook
    }

    private var session: Session? { store.sessions["s1"] }

    static let questions: [String: Any] = ["questions": [
        ["question": "Which animation?", "multiSelect": false, "options": [["label": "Wizard"], ["label": "Chef"]]],
        ["question": "Which props?", "multiSelect": true, "options": [["label": "Mug"], ["label": "Book"], ["label": "Pan"]]],
    ]]

    @Test func clawdIsSurprisedByAHugeOutput() {
        send("UserPromptSubmit", ["prompt": "build it"])
        send("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "make"]])
        send("PostToolUse", ["tool_name": "Bash", "tool_input": ["command": "make"],
                             "tool_response": ["stdout": String(repeating: "x", count: 25_000), "stderr": ""]])
        #expect(session?.cue == .surprise)
        #expect(!Store.isHuge(["stdout": "ok", "stderr": ""]))
        #expect(Store.isHuge(["type": "text", "file": ["content": "x", "numLines": 2000]]))
    }

    @Test func theFirstTaskOfTheDayGetsAStretch() {
        let now = Date()
        UserDefaults.standard.set(now.addingTimeInterval(-26 * 3600), forKey: Store.lastPromptKey)
        #expect(Store.firstPromptOfTheDay(at: now))
        #expect(!Store.firstPromptOfTheDay(at: now.addingTimeInterval(60)))  // the second one isn't
    }

    @Test func pokedAgainAndAgainHisHeadSpins() {
        UserDefaults.standard.set(true, forKey: Store.aliveKey)
        defer { UserDefaults.standard.removeObject(forKey: Store.aliveKey) }
        store.moveIn()
        for _ in 0..<4 { store.focus(Store.greetingID) }
        #expect(store.greeting?.cue == .dizzy)
    }

    @Test func workTakingTheNotchFromTheClawdLivingInItKnowsWhatHeWasDoing() {
        UserDefaults.standard.set(true, forKey: Store.aliveKey)
        defer { UserDefaults.standard.removeObject(forKey: Store.aliveKey) }
        store.moveIn()
        send("UserPromptSubmit", ["prompt": "fix it"])
        #expect(session?.handOff?.from.id == Store.greetingID)
    }

    @Test func aQuietNotchShowsUpOnlyWhenNeeded() {
        UserDefaults.standard.set(true, forKey: Store.quietKey)
        defer { UserDefaults.standard.removeObject(forKey: Store.quietKey) }
        send("UserPromptSubmit", ["prompt": "fix it"])
        #expect(store.mode == .hidden)  // at work: nothing to see
        send("PreToolUse", ["tool_name": "AskUserQuestion", "tool_input": Self.questions])
        #expect(store.mode != .hidden)  // waiting for you
        send("PostToolUse", ["tool_name": "AskUserQuestion", "tool_input": Self.questions])
        #expect(store.mode != .compact)  // answered: it closes, and doesn't stay as a compact notch
        send("Stop")
        #expect(store.mode != .hidden)  // done, for a minute
    }

    @Test func openSessionsWaitingForATaskAreListed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notch-sessions-\(UUID())").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        func write(_ name: String, _ json: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: dir + "/" + name))
        }
        let me = Int(getpid())
        try write("1.json", ["pid": me, "sessionId": "open", "cwd": "/tmp/waiting", "status": "idle", "entrypoint": "cli"])
        try write("2.json", ["pid": me, "sessionId": "busy", "cwd": "/tmp/busy", "status": "busy"])
        try write("3.json", ["pid": 999_999, "sessionId": "gone", "cwd": "/tmp/gone", "status": "idle"])
        try write("4.json", ["pid": me, "sessionId": "s1", "cwd": "/tmp/notch-project", "status": "idle"])
        try "x".write(toFile: dir + "/1.abc.key", atomically: true, encoding: .utf8)
        send("UserPromptSubmit", ["prompt": "fix it"])

        store.findIdle(in: dir)
        #expect(store.idle.map(\.id) == ["open"])  // not one at work, gone, or known through the hooks
        #expect(store.idle.first?.project == "waiting")
        #expect(store.idle.first?.waitingForTask == true)
        #expect(store.others(than: "s1").map(\.id) == ["open"])
        #expect(store.working.map(\.id) == ["s1"])  // the notch itself doesn't show it

        // Claude Code runs while any of them does, at work or not.
        #expect(SessionRegistry.running(in: dir)?.count == 3)
        #expect(SessionRegistry.running(in: dir + "/none") == nil)  // no list: can't tell
    }

    @Test func aFileLeftByACrashDoesNotCountOnceItsNumberIsTaken() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notch-sessions-\(UUID())").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // This process started long after 2001: it isn't the one that session ran in.
        let json: [String: Any] = ["pid": Int(getpid()), "sessionId": "old", "cwd": "/tmp/old", "status": "idle",
                                   "startedAt": 1_000_000_000_000]
        try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: dir + "/1.json"))
        #expect(SessionRegistry.running(in: dir) == [])
        #expect(SessionRegistry.open(in: dir).isEmpty)
    }

    @Test func withClaudeCodeGoneTheAppKeepsOutOfSight() {
        send("UserPromptSubmit", ["prompt": "Hi"])
        let hook = send("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "ls"]])
        #expect(store.shown)
        store.claudeCode(running: false)  // killed: no SessionEnd
        #expect(session == nil)
        #expect(store.prompts.isEmpty)
        #expect(hook.decision() == nil)  // let go, back to Claude Code (gone anyway)
        #expect(!store.shown)
        #expect(store.mode == .hidden)
        store.show(notice: Activity(symbol: "hourglass", title: "Limit reached", detail: ""), limited: true)
        #expect(store.notice == nil)  // Telegram tells it

        store.greet()  // opened by hand: Clawd says hi, icon and all
        #expect(store.shown)
        store.claudeCode(running: true)
        send("UserPromptSubmit", ["prompt": "Again"])
        #expect(store.mode != .hidden)
        store.claudeCode(running: false)  // quit again: the greeting goes with the rest
        #expect(store.greeting == nil)
        #expect(!store.shown)
    }

    @Test func aQuestionIsAnsweredFromTheNotch() throws {
        send("PreToolUse", ["tool_name": "AskUserQuestion", "tool_input": Self.questions])
        #expect(session?.phase == .waiting)
        let hook = send("PermissionRequest", ["tool_name": "AskUserQuestion", "tool_input": Self.questions])
        let prompt = try #require(store.prompt)
        #expect(prompt.form?.questions.count == 2)

        store.choose(prompt, option: 0)
        #expect(store.prompt?.form?.step == 1)
        store.choose(prompt, option: 2)
        store.choose(prompt, option: 1)
        store.choose(prompt, option: 1)  // ticked off again
        #expect(store.prompt?.form?.picked == [2])
        store.choose(prompt, option: 0)
        store.submitPicked(prompt)
        #expect(store.prompts.isEmpty)

        let decision = try #require(hook.decision())
        #expect(decision["behavior"] as? String == "allow")
        let input = try #require(decision["updatedInput"] as? [String: Any])
        #expect(input["answers"] as? [String: String] == ["Which animation?": "Wizard", "Which props?": "Mug, Pan"])
        #expect((input["questions"] as? [Any])?.count == 2)
        #expect(session?.activity.title == tr("Ответ отправлен", "Answer sent"))
    }

    @Test func theClockTicksOnlyWhileClaudeWorks() throws {
        send("UserPromptSubmit", ["prompt": "Fix it"])
        #expect(store.nextTick() == .everySecond)
        send("Stop", ["last_assistant_message": "Done."])
        let end = try #require(session?.turnEnd)
        #expect(store.nextTick() == .at(end.addingTimeInterval(Store.restDuration + 0.05)))
        store.screen(visible: false)
        #expect(store.nextTick() == nil)
    }

    @Test func nothingIsSentWithoutATick() throws {
        let hook = send("PermissionRequest", ["tool_name": "AskUserQuestion", "tool_input": ["questions": [
            ["question": "Which?", "multiSelect": true, "options": [["label": "A"], ["label": "B"]]],
        ]]])
        let prompt = try #require(store.prompt)
        store.submitPicked(prompt)
        #expect(store.prompts.count == 1)
        store.answer(prompt, .askInApp)  // Claude Code's own dialog takes over
        #expect(hook.decision() == nil)
    }

    @Test func allowAlwaysSendsTheRules() throws {
        let rules: [[String: Any]] = [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "make:*"]],
                                       "behavior": "allow", "destination": "localSettings"]]
        send("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "make"]])
        let hook = send("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "make"],
                                              "permission_suggestions": rules])
        let prompt = try #require(store.prompt)
        #expect(prompt.ruleSummary == "Bash(make:*)")
        store.answer(prompt, .allowAlways)

        let decision = try #require(hook.decision())
        #expect(decision["behavior"] as? String == "allow")
        #expect((decision["updatedPermissions"] as? [[String: Any]])?.count == 1)
        #expect(session?.phase == .tool)
        #expect(session?.cue == .excited)
    }

    @Test func denyTellsClaudeWhy() throws {
        let hook = send("PermissionRequest", ["tool_name": "Write", "tool_input": ["file_path": "/tmp/x"]])
        store.answer(try #require(store.prompt), .deny)
        let decision = try #require(hook.decision())
        #expect(decision["behavior"] as? String == "deny")
        #expect(!(decision["message"] as? String ?? "").isEmpty)
        #expect(session?.phase == .thinking)
        #expect(session?.cue == .facepalm)
    }

    @Test func aNewerRequestReplacesTheOlderOne() {
        let first = send("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "one"]])
        send("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "two"]])
        #expect(store.prompts.count == 1)
        #expect(store.prompt?.activity.detail == "two")
        #expect(first.decision() == nil)  // let go: it was answered elsewhere
    }

    @Test func aRequestAnsweredInTheTerminalGoesAway() {
        let hook = send("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "make"]])
        send("PostToolUse", ["tool_name": "Bash"])
        #expect(store.prompts.isEmpty)
        #expect(hook.decision() == nil)
    }

    @Test func aBackgroundTaskKeepsTheTask() {
        send("UserPromptSubmit", ["prompt": "Fix the build"])
        #expect(session?.task == "Fix the build")
        #expect(session?.cue == .idea)
        send("Stop", ["last_assistant_message": "Started it in the background."])
        send("UserPromptSubmit", ["prompt": "<task-notification><status>completed</status><summary>Background command \"Build\" completed</summary></task-notification>"])
        #expect(session?.task == "Fix the build")
        #expect(session?.activity.title == tr("Фоновая задача готова", "Background task done"))
        #expect(session?.phase == .thinking)
    }

    @Test func aReplyEndingInAQuestionWaitsForYou() {
        send("UserPromptSubmit", ["prompt": "Go"])
        send("Stop", ["last_assistant_message": "All done.\n\n```\nnot this?\n```\n**Should I commit?**"])
        #expect(session?.phase == .waiting)
        #expect(session?.activity.detail == "Should I commit?")

        send("UserPromptSubmit", ["prompt": "No"])
        send("Stop", ["last_assistant_message": "Okay, left it."])
        #expect(session?.phase == .done)
        #expect(session?.turnEnd != nil)
    }

    @Test func aFailedToolShowsTheError() {
        send("UserPromptSubmit", ["prompt": "Build it"])
        send("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "make", "description": "Build"]])
        #expect(session?.phase == .tool)
        send("PostToolUseFailure", ["tool_name": "Bash", "error": "Exit code 2\nboom"])
        #expect(session?.phase == .thinking)
        #expect(session?.activity.failed == true)
        #expect(session?.history.last?.failed == true)
        #expect(session?.cue == .facepalm)
    }

    @Test func failuresInARowGetWorse() {
        send("UserPromptSubmit", ["prompt": "Build it"])
        func fail() {
            send("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "make"]])
            send("PostToolUseFailure", ["tool_name": "Bash", "tool_input": ["command": "make"], "error": "Exit code 2"])
        }
        fail()
        #expect(session?.cue == .facepalm)
        fail()
        fail()
        #expect(session?.cue == .despair)
        #expect(session?.failStreak == 3)
        send("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "make"]])
        send("PostToolUse", ["tool_name": "Bash", "tool_input": ["command": "make"]])
        #expect(session?.failStreak == 0)
    }

    @Test func passingTestsAndAPushAreCheered() {
        send("UserPromptSubmit", ["prompt": "Ship it"])
        for (command, cue) in [("swift test", Cue.sparkler), ("git push origin main", .rocket)] {
            send("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": command]])
            send("PostToolUse", ["tool_name": "Bash", "tool_input": ["command": command]])
            #expect(session?.cue == cue, "\(command)")
        }
    }

    @Test func autoModeSayingNoIsAShrug() {
        send("UserPromptSubmit", ["prompt": "Clean up"])
        send("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build"]])
        send("PermissionDenied", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build"], "reason": "[Irreversible]"])
        #expect(session?.cue == .shrug)
    }

    @Test func compactingAndTheRateLimitHaveTheirOwnLooks() {
        send("UserPromptSubmit", ["prompt": "Go on"])
        send("PreCompact")
        #expect(session?.desiredMotion(at: Date()) == .compacting)
        send("PostCompact")
        #expect(session?.desiredMotion(at: Date()) != .compacting)
        send("StopFailure", ["error": "rate_limit", "last_assistant_message": "API Error: Rate limit reached"])
        #expect(session?.desiredMotion(at: Date()) == .limited)
        send("UserPromptSubmit", ["prompt": "Again"])
        #expect(session?.rateLimited == false)
    }

    @Test func aCompactOfYourOwnShowsAndEndsAtRest() {
        send("PreCompact", ["trigger": "manual"])
        #expect(session?.phase == .thinking)
        #expect(session?.desiredMotion(at: Date()) == .compacting)
        send("SessionStart", ["source": "compact"])
        send("PostCompact", ["trigger": "manual"])
        #expect(session?.phase == .done)
        #expect(session?.compactingAlone == false)
    }

    @Test func editsAddUpTheirLines() {
        send("UserPromptSubmit", ["prompt": "Edit"])
        for _ in 0..<2 {
            send("PreToolUse", ["tool_name": "Edit", "tool_input": ["file_path": "/a.swift", "old_string": "a", "new_string": "b\nc"]])
            send("PostToolUse", ["tool_name": "Edit"])
        }
        #expect(session?.linesAdded == 4)
        #expect(session?.linesRemoved == 2)
        #expect(session?.actions == 2)
    }

    @Test func subagentsAreMatchedToTheirTasks() {
        send("UserPromptSubmit", ["prompt": "Look around"])
        send("PreToolUse", ["tool_name": "Task", "tool_input": ["subagent_type": "Explore", "description": "Find the files"]])
        send("PreToolUse", ["tool_name": "Read", "tool_input": ["file_path": "/a/b.swift"], "agent_id": "a1", "agent_type": "Explore"])
        #expect(session?.agents.first?.task == "Find the files")
        #expect(session?.agents.first?.actions == 1)
        #expect(session?.agents.first?.activity?.detail == "b.swift")
        send("SubagentStop", ["agent_id": "a1", "agent_type": "Explore"])
        #expect(session?.agents.first?.finished != nil)
    }

    @Test func aCommitGetsAHopAndADonePlanAMortarboard() {
        send("UserPromptSubmit", ["prompt": "Do the three things"])
        send("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "git commit -m 'One'"]])
        send("PostToolUse", ["tool_name": "Bash", "tool_input": ["command": "git commit -m 'One'"]])
        #expect(session?.cue == .coin)
        let todos: [[String: Any]] = ["One", "Two", "Three"].map { ["content": $0, "status": "completed"] }
        send("PreToolUse", ["tool_name": "TodoWrite", "tool_input": ["todos": todos]])
        send("PostToolUse", ["tool_name": "TodoWrite", "tool_input": ["todos": todos]])
        send("Stop")
        #expect(session?.cue == .graduate)  // every step of the plan done

        send("UserPromptSubmit", ["prompt": "And this"])
        send("Stop")
        #expect(session?.cue != .graduate)  // no plan this time
    }

    @Test func compactingEndsInASneeze() {
        send("UserPromptSubmit", ["prompt": "Go on"])
        send("PreCompact")
        #expect(session?.motion == .compacting)
        send("PostCompact")
        #expect(session?.cue == .sneeze)
    }

    @Test func clawdComesInToSayHi() {
        var seen = Set<Cue>()
        for _ in 0..<60 {
            store.greet()
            if let cue = store.greeting?.cue { seen.insert(cue) }
        }
        #expect(seen.isSubset(of: [.hello, .peekaboo, .peek, .skip]))
        #expect(seen.count > 1)  // not the same way every time
    }

    @Test func theEndOfASessionTakesItAway() {
        send("UserPromptSubmit", ["prompt": "Hi"])
        #expect(session != nil)
        send("SessionEnd")
        #expect(session == nil)
        #expect(store.mode == .hidden)
    }

    @Test func theCardShowsTheBusySession() {
        send("UserPromptSubmit", ["prompt": "One"])
        send("Stop", ["last_assistant_message": "Done."])
        store.handle(["hook_event_name": "UserPromptSubmit", "session_id": "s2", "prompt": "Two"], reply: Hook().reply)
        #expect(store.detailsSession?.id == "s2")
        #expect(store.others(than: "s2").map(\.id) == ["s1"])
    }
}
