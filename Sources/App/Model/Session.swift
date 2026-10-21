import Foundation

enum Phase: Equatable {
    case thinking, tool, waiting, done, stopped, failed

    var isActive: Bool { self == .thinking || self == .tool || self == .waiting }
}

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
    /// A search (code, files, the web): Clawd puts on his deerstalker.
    var search = false
    /// `detail` is a sentence (a prompt, a thought): cut it at the end, not in the middle like a path.
    var prose = false
    /// Why Claude runs this tool, in its own words: what it wrote around the call. Only for tools
    /// without a note of their own.
    var reason = ""
    /// The tool failed or was turned down: its icon goes red.
    var failed = false
    /// The answers Claude offers to its question.
    var options: [String] = []

    /// The line under the title in the card: the tool's own note, or else Claude's reason.
    var aside: String { note.isEmpty ? reason : note }

    static var thinking: Activity { thinking(about: "") }

    static var compacting: Activity {
        Activity(symbol: "archivebox", title: tr("Сжимает контекст", "Compacting context"), detail: "")
    }

    static func thinking(about thought: String) -> Activity {
        Activity(symbol: "sparkle", title: tr("Думает…", "Thinking…"), detail: thought, prose: true)
    }

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
    /// resting after a turn that ended in one of three ways. Packing papers into a box while the
    /// context is compacted; by an hourglass after a turn that hit the rate limit.
    /// Peering through a magnifying glass in a deerstalker while Claude searches.
    case typing, pondering, desktop, running, waving, done, stopped, failed, compacting, limited, searching
}

/// A one-off reaction Clawd plays over whatever he is doing: an idea when a task comes in,
/// joy when you allow something, a facepalm when a tool fails or you say no,
/// confetti after a big task, a hop and a wave when the app is opened, a parachute when he
/// moves into the notch for good. Head in his hands after failures in a row, a shrug when auto mode
/// turns something down, a sparkler when tests pass, a rocket after a push.
enum Cue: Hashable { case idea, excited, facepalm, celebrate, hello, arrive, despair, shrug, sparkler, rocket }

struct Session: Equatable {
    let id: String
    var project = ""
    var cwd = ""
    /// Bundle id of the app the session runs in (Terminal, VS Code, Claude…), for click-to-focus.
    var host: String?
    /// The terminal tab's device (/dev/ttys003): a click picks out that very tab in Terminal or iTerm.
    var tty: String?
    /// CLAUDE_CODE_ENTRYPOINT: "cli" in a terminal, something else in the desktop app or an IDE.
    var entrypoint = ""
    var transcriptPath: String?
    /// Not working until an event says so: a session first seen through, say, a manual /compact
    /// mustn't show Clawd at work.
    var phase = Phase.done
    /// The main agent's tool between PreToolUse and PostToolUse, for the history: the shown
    /// activity changes meanwhile (e.g. to "Waiting for permission").
    var currentTool: Activity?
    /// Clawd's current and previous motion, so the notch can play the change between them.
    private(set) var motion = Motion.done
    private(set) var previousMotion = Motion.done
    private(set) var motionStart = Date()
    /// A one-off reaction, and what Clawd was doing when it started (to put the laptop away first).
    private(set) var cue: Cue?
    private(set) var cueStart = Date.distantPast
    private(set) var cueInterrupted = Motion.done
    var lastFacepalm = Date.distantPast
    /// Tools that failed in a row, this turn.
    var failStreak = 0
    /// The turn ended at the rate limit.
    var rateLimited = false
    /// A /compact you ran between turns: when it's done, the session is done again rather than at work.
    var compactingAlone = false
    /// When the session last made a sound: a question comes as PreToolUse and PermissionRequest at
    /// once, and should sound once.
    var lastChime = Date.distantPast
    /// When the last few tools started, to notice a burst of them.
    var recentTools: [Date] = []
    var activity = Activity.thinking
    /// The message that started this turn.
    var task = ""
    /// Claude's task list for this turn.
    var tasks = TaskList()
    /// What Claude is thinking about: the gist of its thinking or of what it wrote, and when it wrote
    /// it. The next tool takes it as its reason.
    var thought = ""
    var thoughtWritten = Date.distantPast
    /// When the shown failure (a tool that failed or was turned down) happened.
    var failedAt = Date.distantPast
    /// Finished actions of this turn, oldest first (the last few only).
    var history: [Activity] = []
    var agents: [SubAgent] = []
    /// Task/Agent calls whose subagent hasn't announced itself yet: (type, description).
    var pendingAgents: [[String]] = []
    var turnStart: Date
    var turnEnd: Date?
    var lastEvent: Date
    /// When the transcript last grew: Claude at work between hook events, e.g. on a long reply.
    var lastWrite = Date.distantPast
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
        case .failed: return rateLimited ? .limited : .failed
        case .tool where activity == .compacting, .thinking where activity == .compacting: return .compacting
        case .tool where activity.search:
            return activity.agent ? .running : .searching
        case .tool:
            if activity.agent || isBusy(at: now) { return .running }
            return activity.command && quiet > 8 ? .desktop : .typing
        case .thinking:
            // Between two searches he keeps his hat on, rather than back to the laptop for a moment.
            if motion == .searching, now.timeIntervalSince(lastEvent) < 3 { return .searching }
            if isBusy(at: now) { return .running }
            return quiet > 12 ? .pondering : .typing
        }
    }

    /// Six or more tools in the last 12 seconds.
    private func isBusy(at now: Date) -> Bool {
        recentTools.filter { now.timeIntervalSince($0) < 12 }.count >= 6
    }

    /// Minutes without a sign of life while Claude should be at work: it hung, or a command runs long.
    /// Nil under five minutes, and while it waits for you, which is quiet by design.
    func quietMinutes(at now: Date) -> Int? {
        guard phase == .thinking || phase == .tool else { return nil }
        let quiet = now.timeIntervalSince(max(lastEvent, lastWrite))
        return quiet >= 300 ? Int(quiet / 60) : nil
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

    /// A facepalm for something that went wrong, unless there was one in the last 45 seconds: not
    /// for every failing grep.
    mutating func facepalm(at now: Date) {
        guard now.timeIntervalSince(lastFacepalm) > 45 else { return }
        play(.facepalm, at: now)
        lastFacepalm = now
    }

    /// Another tool failed: a facepalm, and at the third in a row (the sixth…) his head in his hands,
    /// which isn't held back like the facepalm: it says this keeps going wrong.
    mutating func toolFailed(at now: Date) {
        failStreak += 1
        if failStreak % 3 == 0 {
            play(.despair, at: now)
            lastFacepalm = now
        } else {
            facepalm(at: now)
        }
    }

    /// Whether a sound now isn't one too many: none within two seconds of the last.
    mutating func takesChime(at now: Date) -> Bool {
        guard now.timeIntervalSince(lastChime) > 2 else { return false }
        lastChime = now
        return true
    }

    /// A finished action for the history, which keeps the last few.
    mutating func record(_ action: Activity) {
        history = Array((history + [action]).suffix(4))
    }

    /// Not a Claude Code session: Clawd saying hi when the app is opened.
    var isGreeting: Bool { id == Store.greetingID }

    /// The desktop app and IDE extensions show their own permission dialog while the hook runs;
    /// in a terminal the usual prompt may only come once the hook is done.
    var dialogRunsInParallel: Bool { !entrypoint.isEmpty && entrypoint != "cli" }

    mutating func startTurn(at date: Date) {
        turnStart = date
        turnEnd = nil
        actions = 0
        history = []
        currentTool = nil
        thought = ""
        tasks = TaskList()
        linesAdded = 0
        linesRemoved = 0
        turnOutputTokens = 0
        failStreak = 0
        rateLimited = false
        compactingAlone = false
        agents.removeAll { $0.finished != nil }
    }
}
