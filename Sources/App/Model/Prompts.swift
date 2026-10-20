import Foundation

/// Claude's questions (AskUserQuestion, up to four), answered one after another in the notch. The
/// answers go back to Claude Code as the tool's input, the way its own dialog fills them in.
struct QuestionForm: Equatable {
    struct Option: Equatable {
        let label: String
        let detail: String
    }

    struct Question: Equatable {
        let text: String
        let options: [Option]
        let multiSelect: Bool
    }

    let questions: [Question]
    /// The question shown now.
    var step = 0
    /// Question text → the chosen label (several, comma-separated, where more than one may be picked).
    var answers: [String: String] = [:]
    /// What's ticked so far on a question that takes several answers.
    var picked: Set<Int> = []

    var current: Question { questions[step] }

    init?(_ input: [String: Any]) {
        questions = (input["questions"] as? [[String: Any]] ?? []).compactMap { q in
            guard let text = q["question"] as? String, !text.isEmpty else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> Option? in
                guard let label = o["label"] as? String, !label.isEmpty else { return nil }
                return Option(label: label, detail: oneLine(o["description"] as? String ?? ""))
            }
            return options.isEmpty ? nil : Question(text: text, options: Array(options.prefix(4)), multiSelect: q["multiSelect"] as? Bool ?? false)
        }
        guard !questions.isEmpty else { return nil }
    }

    /// Answers the current question with these options; true once every question has its answer.
    mutating func answer(_ options: [Int]) -> Bool {
        answers[current.text] = options.sorted().map { current.options[$0].label }.joined(separator: ", ")
        picked = []
        guard step + 1 < questions.count else { return true }
        step += 1
        return false
    }
}

/// A PermissionRequest hook that waits for a click in the notch.
struct PermissionPrompt: Identifiable, Equatable {
    let id = UUID()
    let sessionID: String
    /// Set when a subagent asks: parallel subagents share the session id.
    let agentID: String?
    let question: String
    let activity: Activity
    /// Claude Code's `permission_suggestions`: the rules "Allow always" sends back.
    let suggestions: [[String: Any]]
    /// The tool's input, sent back with the answers to a question.
    var input: [String: Any] = [:]
    /// Set when Claude asks you something: its options instead of Allow and Deny.
    var form: QuestionForm?
    let reply: HookReply

    /// What "Allow always" would add, e.g. `Bash(npm run lint:*)`.
    var ruleSummary: String? {
        guard let first = suggestions.first else { return nil }
        if let rule = (first["rules"] as? [[String: Any]])?.first, let tool = rule["toolName"] as? String {
            let content = rule["ruleContent"] as? String ?? ""
            return content.isEmpty ? tool : "\(tool)(\(content))"
        }
        if let mode = first["mode"] as? String { return tr("режим \(mode)", "mode \(mode)") }
        if let dir = (first["directories"] as? [String])?.first { return tr("папка ", "folder ") + (dir as NSString).lastPathComponent }
        return nil
    }

    static func == (a: PermissionPrompt, b: PermissionPrompt) -> Bool { a.id == b.id }
}
