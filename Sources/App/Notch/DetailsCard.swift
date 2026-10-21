import SwiftUI

/// Fixed row heights, so the notch can size itself to the card before drawing it.
enum DetailsLayout {
    static let caption: CGFloat = 13
    static let captionGap: CGFloat = 4
    static let gap: CGFloat = 10
    static let line: CGFloat = 15
    static let row: CGFloat = 17
    static let footer: CGFloat = 14
    static let top: CGFloat = 4
    static let bottom: CGFloat = 14
    static let maxAgentRows = 3
    static let maxHistoryRows = 3
    static let maxOtherRows = 3
    /// The current step's line and the progress bar under it.
    static let plan: CGFloat = line + 5 + 3
    /// The row of answers to a question, with a little room above it.
    static let options: CGFloat = 21

    /// Rough wrap estimate for the card's ~390 pt text column.
    static func taskLines(_ s: Session) -> Int {
        s.task.isEmpty ? 0 : (s.task.count > 62 ? 2 : 1)
    }

    static func detailLines(_ a: Activity) -> Int {
        a.detail.isEmpty ? 0 : (a.detail.count > (a.monospaced ? 52 : 60) ? 2 : 1)
    }

    static func nowHeight(_ a: Activity) -> CGFloat {
        let lines = 1 + (a.aside.isEmpty ? 0 : 1) + detailLines(a)
        return max(30, CGFloat(lines) * line + CGFloat(lines - 1) + (a.options.isEmpty ? 0 : 1 + options))
    }

    static func agentRows(_ s: Session) -> Int { min(s.agents.count, maxAgentRows) }

    static func height(_ s: Session, others: Int) -> CGFloat {
        var sections: [CGFloat] = []
        // A list's rows sit in the section's stack too, so they're as far apart as the caption is from them.
        func list(_ rows: Int) {
            if rows > 0 { sections.append(caption + captionGap + CGFloat(rows) * row + CGFloat(rows - 1) * captionGap) }
        }
        let task = taskLines(s)
        if task > 0 { sections.append(caption + captionGap + CGFloat(task) * line) }
        sections.append(caption + captionGap + nowHeight(DetailsCard.now(s)))
        if !s.tasks.isEmpty { sections.append(caption + captionGap + plan) }
        list(agentRows(s))
        list(min(s.history.count, maxHistoryRows))
        list(min(others, maxOtherRows))
        sections.append(footer)
        return top + bottom + sections.reduce(0, +) + gap * CGFloat(sections.count - 1)
    }

    /// The tallest card, measured with `height` itself so the two can't drift apart: a two-line
    /// task, a command with a description and a two-line command line (or a question with its
    /// answers under it), and every list full.
    static let maxHeight: CGFloat = {
        var s = Session(id: "", turnStart: .distantPast, lastEvent: .distantPast)
        s.phase = .tool
        s.task = String(repeating: "x", count: 300)
        s.activity = Activity(symbol: "", title: "x", detail: String(repeating: "x", count: 300), monospaced: true, note: "x",
                              options: ["x"])
        s.agents = Array(repeating: SubAgent(id: "", type: "", started: .distantPast), count: maxAgentRows)
        s.history = Array(repeating: Activity(symbol: "", title: "x", detail: ""), count: maxHistoryRows)
        s.tasks.apply("TodoWrite", ["todos": [["content": "x", "status": "pending"]]], useID: nil)
        return height(s, others: maxOtherRows)
    }()
}

/// What the notch shows while the pointer rests on it: the task, what Claude is doing now, its subagents, what it did just before, and the other sessions.
struct DetailsCard: View {
    let session: Session
    let others: [Session]
    /// Another session was clicked: show it in the card.
    let pick: (String) -> Void

    /// Between tools Claude is thinking; the last tool has already moved to the history. Unless it
    /// failed: that stays until Claude writes its next thought.
    static func now(_ s: Session) -> Activity {
        s.phase == .thinking && !s.activity.failed ? .thinking(about: s.thought) : s.activity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DetailsLayout.gap) {
            let taskLines = DetailsLayout.taskLines(session)
            if taskLines > 0 {
                section(tr("Задача", "Task")) {
                    Text(session.task)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(taskLines)
                        .frame(height: CGFloat(taskLines) * DetailsLayout.line, alignment: .topLeading)
                }
            }
            // Ticks slowly, for "quiet for 6 min".
            TimelineView(.periodic(from: .now, by: 20)) { context in
                section(nowCaption(at: context.date)) { NowRow(activity: Self.now(session), phase: session.phase) }
            }
            if !session.tasks.isEmpty {
                section(planCaption) { PlanRow(tasks: session.tasks) }
            }
            if !session.agents.isEmpty {
                let running = session.agents.filter { $0.finished == nil }.count
                section(running > 0 ? tr("Агенты · работают \(running)", "Agents · \(running) running") : tr("Агенты", "Agents")) {
                    let shown = session.agents.suffix(DetailsLayout.maxAgentRows)
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, agent in AgentRow(agent: agent) }
                }
            }
            if !session.history.isEmpty {
                section(tr("Перед этим", "Before that")) {
                    let recent = session.history.reversed().prefix(DetailsLayout.maxHistoryRows)
                    ForEach(Array(recent.enumerated()), id: \.offset) { _, a in HistoryRow(activity: a) }
                }
            }
            if !others.isEmpty {
                section(tr("Другие сессии", "Other sessions")) {
                    ForEach(others.prefix(DetailsLayout.maxOtherRows), id: \.id) { other in
                        SessionRow(session: other).onTapGesture { pick(other.id) }
                    }
                }
            }
            HStack(spacing: 5) {
                Text(footer)
                    .lineLimit(1)
                if session.contextTokens > 0 {
                    ContextRing(fill: contextFill)
                    Text(tr("\(Int(contextFill * 100))% из ", "\(Int(contextFill * 100))% of ") + tokens(session.contextWindow))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.white.opacity(0.32))
            .frame(height: DetailsLayout.footer)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, DetailsLayout.top)
        .padding(.bottom, DetailsLayout.bottom)
    }

    private var planCaption: String {
        let tasks = session.tasks
        guard let current = tasks.current else { return tr("План · всё сделано", "Plan · all done") }
        return tr("План · шаг \(current.step) из \(tasks.count)", "Plan · step \(current.step) of \(tasks.count)")
    }

    private func nowCaption(at date: Date) -> String {
        switch session.phase {
        case .thinking, .tool:
            guard let minutes = session.quietMinutes(at: date) else { return tr("Сейчас", "Now") }
            return tr("Сейчас · тихо уже \(minutes) мин", "Now · quiet for \(minutes) min")
        case .waiting: return tr("Ждёт тебя", "Waiting for you")
        case .done, .stopped, .failed: return tr("Итог", "Result")
        }
    }

    /// How full the context is, 0…1.
    private var contextFill: Double {
        min(1, Double(session.contextTokens) / Double(max(1, session.contextWindow)))
    }

    /// Project · actions · lines changed · output tokens; the context's ring and fill follow it.
    private var footer: String {
        var parts = [session.project]
        if session.actions > 0 {
            parts.append(actionsText(session.actions))
        }
        if session.linesAdded + session.linesRemoved > 0 {
            parts.append("+\(session.linesAdded) −\(session.linesRemoved)")
        }
        if session.turnOutputTokens > 0 {
            parts.append(tokens(session.turnOutputTokens) + tr(" ток.", " tokens"))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ") + (session.contextTokens > 0 ? " ·" : "")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DetailsLayout.captionGap) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.white.opacity(0.38))
                .frame(height: DetailsLayout.caption)
            content()
        }
    }
}

/// "+12 −3" in green and red, or nothing.
private struct DiffText: View {
    let added: Int
    let removed: Int

    var body: some View {
        if added + removed > 0 {
            HStack(spacing: 3) {
                if added > 0 { Text("+\(added)").foregroundStyle(.green.opacity(0.85)) }
                if removed > 0 { Text("−\(removed)").foregroundStyle(.red.opacity(0.8)) }
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
        }
    }
}

private struct NowRow: View {
    let activity: Activity
    let phase: Phase

    var body: some View {
        let detailLines = DetailsLayout.detailLines(activity)
        // Up to two lines fit beside the icon: center them on it. Longer text starts at its top.
        let lines = 1 + (activity.aside.isEmpty ? 0 : 1) + detailLines
        HStack(alignment: lines <= 2 && activity.options.isEmpty ? .center : .top, spacing: 10) {
            IconBadge(symbol: activity.symbol, color: activity.failed ? .red : phaseColor(phase))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text(activity.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    DiffText(added: activity.added, removed: activity.removed)
                }
                .frame(height: DetailsLayout.line)
                if !activity.aside.isEmpty {
                    Text(activity.aside)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .frame(height: DetailsLayout.line)
                }
                if detailLines > 0 {
                    Text(activity.detail)
                        .font(activity.monospaced ? .system(size: 11.5, design: .monospaced) : .system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(detailLines)
                        .truncationMode(activity.prose ? .tail : .middle)
                        .frame(height: CGFloat(detailLines) * DetailsLayout.line, alignment: .topLeading)
                }
                if !activity.options.isEmpty {
                    OptionsRow(options: activity.options)
                }
            }
        }
        .frame(height: DetailsLayout.nowHeight(activity), alignment: .topLeading)
    }
}

/// The answers Claude offers, as it lists them. You pick one where Claude Code asks.
private struct OptionsRow: View {
    let options: [String]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Text(option)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .frame(height: 18)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
            }
        }
        .frame(height: DetailsLayout.options, alignment: .bottom)
    }
}

/// The step under way and a bar for how much of the list is done.
private struct PlanRow: View {
    let tasks: TaskList

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(tasks.current?.title ?? tasks.items.last?.title ?? "")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: DetailsLayout.line)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(claudeOrange).frame(width: geometry.size.width * tasks.fraction)
                }
            }
            .frame(height: 3)
        }
    }
}

private struct AgentRow: View {
    let agent: SubAgent

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: agent.finished == nil ? "person.2.fill" : "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(agent.finished == nil ? claudeOrange : Color.green.opacity(0.8))
                .frame(width: 13)
            Text(name)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
            Text(status)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(formatElapsed((agent.finished ?? context.date).timeIntervalSince(agent.started)))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(height: DetailsLayout.row)
    }

    private var name: String {
        let type = agent.type.isEmpty ? tr("агент", "agent") : agent.type
        return agent.task.isEmpty ? type : "\(type) · \(agent.task)"
    }

    private var status: String {
        if agent.finished != nil {
            return tr("готово", "done") + " · " + actionsText(agent.actions)
        }
        guard let a = agent.activity else { return tr("запускается…", "starting…") }
        return a.headline
    }
}

private struct HistoryRow: View {
    let activity: Activity

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: activity.failed ? "xmark.octagon.fill" : activity.symbol)
                .font(.system(size: 10))
                .foregroundStyle(activity.failed ? Color.red.opacity(0.85) : .white.opacity(0.45))
                .frame(width: 13)
            Text(activity.headline)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.middle)
            DiffText(added: activity.added, removed: activity.removed)
        }
        .frame(height: DetailsLayout.row)
    }
}

/// Another session: its state, project and what it is doing; a click shows it in the card.
private struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(phaseColor(session.phase == .tool ? .thinking : session.phase))
                .frame(width: 7, height: 7)
                .frame(width: 13)
            Text(session.project.isEmpty ? tr("сессия", "session") : session.project)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            Text(status)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
        }
        .frame(height: DetailsLayout.row)
        .contentShape(Rectangle())
    }

    private var status: String {
        if let minutes = session.quietMinutes(at: Date()) { return tr("тихо уже \(minutes) мин", "quiet for \(minutes) min") }
        switch session.phase {
        case .thinking: return session.thought.isEmpty ? tr("думает", "thinking") : session.thought
        case .tool: return session.activity.headline
        case .waiting: return tr("ждёт тебя", "waiting for you")
        case .done: return tr("готово", "done")
        case .stopped: return tr("остановлено", "stopped")
        case .failed: return tr("ошибка", "error")
        }
    }
}

/// How full the context is, as a ring like the Claude app's: blue, orange once it's nearly full.
struct ContextRing: View {
    let fill: Double

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.16), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.03, fill))
                .stroke(fill < 0.8 ? Color(red: 0.24, green: 0.52, blue: 0.96) : Color(red: 0.85, green: 0.47, blue: 0.34),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 10, height: 10)
    }
}
