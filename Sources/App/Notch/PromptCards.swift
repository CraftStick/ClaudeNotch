import SwiftUI

struct PermissionCard: View {
    let prompt: PermissionPrompt
    let waiting: Int
    let answer: (Store.Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconBadge(symbol: "hand.raised.fill", color: .yellow)
                TitleAndDetail(title: prompt.question, activity: prompt.activity)
                Spacer(minLength: 8)
                if waiting > 0 {
                    Text(tr("ещё \(waiting)", "+\(waiting) more"))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            HStack(spacing: 8) {
                Button(tr("В приложении", "In app")) { answer(.askInApp) }
                    .buttonStyle(NotchButtonStyle(kind: .plain))
                Spacer(minLength: 6)
                Button { answer(.deny) } label: { ShortcutLabel(title: tr("Запретить", "Deny"), key: "⌃⌥⌘N") }
                    .buttonStyle(NotchButtonStyle(kind: .secondary))
                if prompt.ruleSummary != nil {
                    Button(tr("Всегда", "Always")) { answer(.allowAlways) }
                        .buttonStyle(NotchButtonStyle(kind: .secondary))
                }
                Button { answer(.allow) } label: { ShortcutLabel(title: tr("Разрешить", "Allow"), key: "⌃⌥⌘Y") }
                    .buttonStyle(NotchButtonStyle(kind: .primary))
            }
            Text(prompt.ruleSummary.map { tr("«Всегда» добавит правило ", "“Always” adds the rule ") + $0 } ?? " ")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.38))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(height: 12)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }
}

/// A question Claude asks you: its options as buttons (⌃⌥⌘1…4), one question at a time. Where it
/// takes several answers they tick, and Done sends them. An answer of your own is typed in Claude Code.
struct QuestionCard: View {
    let form: QuestionForm
    let waiting: Int
    let choose: (Int) -> Void
    let submit: () -> Void
    let handBack: () -> Void

    private static let header: CGFloat = 36
    private static let row: CGFloat = 26
    private static let rowGap: CGFloat = 5
    private static let footer: CGFloat = 26
    private static let gap: CGFloat = 8

    static func height(_ form: QuestionForm) -> CGFloat {
        let rows = CGFloat(form.current.options.count)
        return 4 + header + gap + rows * row + (rows - 1) * rowGap + gap + footer + 10
    }

    static let maxHeight: CGFloat = 4 + header + gap + 4 * row + 3 * rowGap + gap + footer + 10

    var body: some View {
        let question = form.current
        VStack(alignment: .leading, spacing: Self.gap) {
            HStack(alignment: .top, spacing: 10) {
                IconBadge(symbol: "questionmark.bubble.fill", color: .yellow)
                Text(question.text)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                if form.questions.count > 1 {
                    Text(tr("\(form.step + 1) из \(form.questions.count)", "\(form.step + 1) of \(form.questions.count)"))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(height: 30)
                }
            }
            .frame(height: Self.header, alignment: .top)
            VStack(spacing: Self.rowGap) {
                ForEach(question.options.indices, id: \.self) { i in
                    Button { choose(i) } label: {
                        OptionLabel(option: question.options[i], number: i + 1,
                                    tick: question.multiSelect ? form.picked.contains(i) : nil)
                    }
                    .buttonStyle(OptionButtonStyle(picked: form.picked.contains(i)))
                }
            }
            HStack(spacing: 8) {
                Button(tr("Ответить в приложении", "Answer in app"), action: handBack)
                    .buttonStyle(NotchButtonStyle(kind: .plain))
                Spacer(minLength: 6)
                if waiting > 0 {
                    Text(tr("ещё \(waiting)", "+\(waiting) more"))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
                if question.multiSelect {
                    Button(action: submit) { ShortcutLabel(title: tr("Готово", "Done"), key: "⌃⌥⌘Y") }
                        .buttonStyle(NotchButtonStyle(kind: .primary))
                        .disabled(form.picked.isEmpty)
                        .opacity(form.picked.isEmpty ? 0.4 : 1)
                }
            }
            .frame(height: Self.footer)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .animation(.easeInOut(duration: 0.2), value: form.step)
    }
}

/// One answer: a tick where several can be picked, its label, what it means, and its shortcut.
private struct OptionLabel: View {
    let option: QuestionForm.Option
    let number: Int
    let tick: Bool?

    var body: some View {
        HStack(spacing: 8) {
            if let tick {
                Image(systemName: tick ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tick ? claudeOrange : .white.opacity(0.5))
            }
            Text(option.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .layoutPriority(1)
            if !option.detail.isEmpty {
                Text(option.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            Text("⌃⌥⌘\(number)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 11)
        .frame(height: 26)
        .help(option.detail)
    }
}

private struct OptionButtonStyle: ButtonStyle {
    let picked: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(picked ? claudeOrange.opacity(0.3) : Color.white.opacity(configuration.isPressed ? 0.2 : 0.1)))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ShortcutLabel: View {
    let title: String
    let key: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Text(key)
                .font(.system(size: 10, weight: .medium))
                .opacity(0.45)
        }
    }
}

private struct NotchButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, plain }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: kind == .plain ? .regular : .semibold))
            .foregroundStyle(kind == .primary ? Color.black : Color.white.opacity(kind == .plain ? 0.5 : 0.9))
            .padding(.horizontal, kind == .plain ? 2 : 11)
            .frame(height: 26)
            .background(Capsule().fill(kind == .primary ? Color.white : Color.white.opacity(kind == .secondary ? 0.14 : 0)))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
