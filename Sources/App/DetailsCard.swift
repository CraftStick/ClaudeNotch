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

    /// Rough wrap estimate for the card's ~390 pt text column.
    static func taskLines(_ s: Session) -> Int {
        s.task.isEmpty ? 0 : (s.task.count > 62 ? 2 : 1)
    }

    static func detailLines(_ a: Activity) -> Int {
        a.detail.isEmpty ? 0 : (a.detail.count > (a.monospaced ? 52 : 60) ? 2 : 1)
    }

    static func nowHeight(_ a: Activity) -> CGFloat {
        let lines = 1 + (a.note.isEmpty ? 0 : 1) + detailLines(a)
        return max(30, CGFloat(lines) * line + CGFloat(lines - 1))
    }

    static func agentRows(_ s: Session) -> Int { min(s.agents.count, maxAgentRows) }

    static func height(_ s: Session, others: Int) -> CGFloat {
        var sections: [CGFloat] = []
        func list(_ rows: Int) { if rows > 0 { sections.append(caption + captionGap + CGFloat(rows) * row) } }
        let task = taskLines(s)
        if task > 0 { sections.append(caption + captionGap + CGFloat(task) * line) }
        sections.append(caption + captionGap + nowHeight(DetailsCard.now(s)))
        list(agentRows(s))
        list(min(s.history.count, maxHistoryRows))
        list(min(others, maxOtherRows))
        sections.append(footer)
        return top + bottom + sections.reduce(0, +) + gap * CGFloat(sections.count - 1)
    }

    static let maxHeight: CGFloat = {
        let lists = maxAgentRows + maxHistoryRows + maxOtherRows
        return top + bottom + 5 * (caption + captionGap) + 2 * line + 3 * line + 2
            + CGFloat(lists) * row + footer + 5 * gap
    }()
}

/// What the notch shows while the pointer rests on it: the task, what Claude is doing now, its subagents, what it did just before, and the other sessions.
struct DetailsCard: View {
    let session: Session
    let others: [Session]
    let focus: (String) -> Void

    /// Between tools Claude is thinking; the last tool has already moved to the history.
    static func now(_ s: Session) -> Activity {
        s.phase == .thinking ? .thinking : s.activity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DetailsLayout.gap) {
            let taskLines = DetailsLayout.taskLines(session)
            if taskLines > 0 {
                section("Задача") {
                    Text(session.task)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(taskLines)
                        .frame(height: CGFloat(taskLines) * DetailsLayout.line, alignment: .topLeading)
                }
            }
            section(nowCaption) { NowRow(activity: Self.now(session), phase: session.phase) }
            if !session.agents.isEmpty {
                let running = session.agents.filter { $0.finished == nil }.count
                section(running > 0 ? "Агенты · работают \(running)" : "Агенты") {
                    let shown = session.agents.suffix(DetailsLayout.maxAgentRows)
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, agent in AgentRow(agent: agent) }
                }
            }
            if !session.history.isEmpty {
                section("Перед этим") {
                    let recent = session.history.reversed().prefix(DetailsLayout.maxHistoryRows)
                    ForEach(Array(recent.enumerated()), id: \.offset) { _, a in HistoryRow(activity: a) }
                }
            }
            if !others.isEmpty {
                section("Другие сессии · клик — открыть") {
                    ForEach(others.prefix(DetailsLayout.maxOtherRows), id: \.id) { other in
                        SessionRow(session: other).onTapGesture { focus(other.id) }
                    }
                }
            }
            Text(footer)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.32))
                .lineLimit(1)
                .frame(height: DetailsLayout.footer)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, DetailsLayout.top)
        .padding(.bottom, DetailsLayout.bottom)
    }

    private var nowCaption: String {
        switch session.phase {
        case .thinking, .tool: return "Сейчас"
        case .waiting: return "Ждёт тебя"
        case .done, .stopped, .failed: return "Итог"
        }
    }

    /// Project · actions · lines changed · output tokens · context fill.
    private var footer: String {
        var parts = [session.project]
        if session.actions > 0 {
            parts.append("\(session.actions) " + plural(session.actions, "действие", "действия", "действий"))
        }
        if session.linesAdded + session.linesRemoved > 0 {
            parts.append("+\(session.linesAdded) −\(session.linesRemoved)")
        }
        if session.turnOutputTokens > 0 {
            parts.append(tokens(session.turnOutputTokens) + " ток.")
        }
        if session.contextTokens > 0 {
            let percent = min(100, session.contextTokens * 100 / max(1, session.contextWindow))
            parts.append("контекст \(percent)% из \(tokens(session.contextWindow))")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
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

/// 950 → "950", 12_400 → "12k", 1_000_000 → "1M".
func tokens(_ n: Int) -> String {
    if n >= 1_000_000 { return n % 1_000_000 == 0 ? "\(n / 1_000_000)M" : String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 10_000 { return "\(n / 1000)k" }
    if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
    return "\(n)"
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
        let lines = 1 + (activity.note.isEmpty ? 0 : 1) + detailLines
        HStack(alignment: lines <= 2 ? .center : .top, spacing: 10) {
            IconBadge(symbol: activity.symbol, color: phaseColor(phase))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text(activity.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    DiffText(added: activity.added, removed: activity.removed)
                }
                .frame(height: DetailsLayout.line)
                if !activity.note.isEmpty {
                    Text(activity.note)
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
                        .truncationMode(.middle)
                        .frame(height: CGFloat(detailLines) * DetailsLayout.line, alignment: .topLeading)
                }
            }
        }
        .frame(height: DetailsLayout.nowHeight(activity), alignment: .topLeading)
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
        let type = agent.type.isEmpty ? "агент" : agent.type
        return agent.task.isEmpty ? type : "\(type) · \(agent.task)"
    }

    private var status: String {
        if agent.finished != nil {
            return "готово · \(agent.actions) " + plural(agent.actions, "действие", "действия", "действий")
        }
        guard let a = agent.activity else { return "запускается…" }
        return a.headline
    }
}

private struct HistoryRow: View {
    let activity: Activity

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: activity.symbol)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
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

/// Another session: its state, project and what it is doing; a click opens it.
private struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(phaseColor(session.phase == .tool ? .thinking : session.phase))
                .frame(width: 7, height: 7)
                .frame(width: 13)
            Text(session.project.isEmpty ? "сессия" : session.project)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            Text(status)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.35))
        }
        .frame(height: DetailsLayout.row)
        .contentShape(Rectangle())
    }

    private var status: String {
        switch session.phase {
        case .thinking: return "думает"
        case .tool: return session.activity.headline
        case .waiting: return "ждёт тебя"
        case .done: return "готово"
        case .stopped: return "остановлено"
        case .failed: return "ошибка"
        }
    }
}
