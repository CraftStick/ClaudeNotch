import Foundation

/// The task list Claude keeps for a turn, shown as "step 3 of 5" with a bar. Three tools keep one:
/// Claude Code's TodoWrite (the whole list every time) and TaskCreate/TaskUpdate (one task at a
/// time), and the Claude app's update_plan (a list, then "next", "done" and "start" steps).
struct TaskList: Equatable {
    struct Item: Equatable {
        var title: String
        /// What's under way, in its own words ("Running the tests"), if the tool gave it.
        var active: String?
        /// pending, in_progress or completed.
        var status: String
    }

    private(set) var items: [Item] = []
    /// TaskCreate/TaskUpdate number their tasks ("Task #3 created"): number → index in `items`.
    private var numbers: [String: Int] = [:]
    /// TaskCreate calls still waiting for their number: tool_use_id → task.
    private var creating: [String: Item] = [:]

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }
    var completed: Int { items.filter { $0.status == "completed" }.count }
    var fraction: Double { items.isEmpty ? 0 : Double(completed) / Double(items.count) }

    /// The step under way (1-based) and what it is; nil once everything is done.
    var current: (step: Int, title: String)? {
        if let i = items.firstIndex(where: { $0.status == "in_progress" }) { return (i + 1, items[i].active ?? items[i].title) }
        if let i = items.firstIndex(where: { $0.status != "completed" }) { return (i + 1, items[i].title) }
        return nil
    }

    /// Whether `tool` is one of the task tools.
    static func handles(_ tool: String) -> Bool {
        ["TodoWrite", "TaskCreate", "TaskUpdate"].contains(tool) || tool.hasSuffix("__update_plan") || tool.hasSuffix("__wrap_up")
    }

    /// A task tool about to run, with its input.
    mutating func apply(_ tool: String, _ input: [String: Any], useID: String?) {
        switch tool {
        case "TodoWrite":
            items = (input["todos"] as? [[String: Any]] ?? []).compactMap { t in
                (t["content"] as? String).map { Item(title: $0, active: t["activeForm"] as? String, status: t["status"] as? String ?? "pending") }
            }
            numbers = [:]
        case "TaskCreate":
            if let useID, let subject = input["subject"] as? String {
                creating[useID] = Item(title: subject, active: input["activeForm"] as? String, status: "pending")
            }
        case "TaskUpdate":
            guard let number = (input["taskId"] as? String) ?? (input["taskId"] as? Int).map(String.init),
                  let i = numbers[number] else { return }
            if let status = input["status"] as? String {
                if status == "deleted" {
                    items.remove(at: i)
                    numbers[number] = nil
                    numbers = numbers.mapValues { $0 > i ? $0 - 1 : $0 }
                    return
                }
                items[i].status = status
            }
            if let subject = input["subject"] as? String { items[i].title = subject }
            if let active = input["activeForm"] as? String { items[i].active = active }
        case _ where tool.hasSuffix("__update_plan"):  // the Claude app's own plan tool
            if let list = input["items"] as? [[String: Any]] {
                items = list.compactMap { t in (t["content"] as? String).map { Item(title: $0, status: t["status"] as? String ?? "pending") } }
                numbers = [:]
            }
            if input["advance"] as? Bool == true, let i = items.firstIndex(where: { $0.status == "in_progress" }) {
                items[i].status = "completed"
                if let next = items[(i + 1)...].firstIndex(where: { $0.status == "pending" }) { items[next].status = "in_progress" }
            }
            for step in input["done"] as? [Int] ?? [] where items.indices.contains(step - 1) {
                items[step - 1].status = "completed"
            }
            if let step = input["start"] as? Int, items.indices.contains(step - 1) {
                items[step - 1].status = "in_progress"
            }
        case _ where tool.hasSuffix("__wrap_up"):  // checks the list off
            for i in items.indices { items[i].status = "completed" }
        default:
            break
        }
    }

    /// A task tool that has run: TaskCreate's answer carries the new task's number.
    mutating func finish(_ tool: String, response: Any?, useID: String?) {
        guard tool == "TaskCreate", let useID, let item = creating.removeValue(forKey: useID) else { return }
        let text: String
        if let s = response as? String {
            text = s
        } else if let response, JSONSerialization.isValidJSONObject(response),
                  let data = try? JSONSerialization.data(withJSONObject: response) {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = ""
        }
        // "Task #3 created successfully: …", or a structured answer with the id.
        let patterns = [#"#(\d+)"#, #""(?:id|taskId)"\s*:\s*"?(\d+)"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            numbers[String(text[range])] = items.count
            items.append(item)
            return
        }
    }
}
