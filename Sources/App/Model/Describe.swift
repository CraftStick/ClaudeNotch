import Foundation

// MARK: - Formatting

enum Describe {
    /// A command worth a cheer once it went through: a push gets a rocket, a test run a sparkler.
    static func cheer(for command: String) -> Cue? {
        func has(_ pattern: String) -> Bool { command.range(of: pattern, options: .regularExpression) != nil }
        if has(#"(^|[;&|(]\s*|\s)git(\s+-\S+(\s+(?!push\b)[^\s-]\S*)?)*\s+push\b"#) { return .rocket }  // also git -C dir push
        let tests = [#"\bswift\s+test\b"#, #"\b(npm|pnpm|yarn|bun)\s+(run\s+)?test\b"#, #"\bpytest\b"#, #"\bgo\s+test\b"#,
                     #"\bcargo\s+(test|nextest)\b"#, #"\bxcodebuild\b.*\btest\b"#, #"\b(jest|vitest|rspec|phpunit)\b"#,
                     #"\b(mvn|gradle|\./gradlew)\s+test\b"#, #"\bmake\s+(test|check)\b"#, #"\bpython3?\s+-m\s+(pytest|unittest)\b"#]
        return tests.contains(where: has) ? .sparkler : nil
    }

    static func tool(_ name: String, _ input: [String: Any]) -> Activity {
        func str(_ key: String) -> String { input[key] as? String ?? "" }
        func file(_ key: String = "file_path") -> String { (str(key) as NSString).lastPathComponent }

        switch name {
        case "Bash":
            return Activity(symbol: "terminal", title: tr("Выполняет команду", "Running a command"), detail: flat(str("command")),
                            monospaced: true, note: oneLine(str("description")), command: true)
        case "BashOutput":
            return Activity(symbol: "terminal", title: tr("Смотрит вывод команды", "Reading command output"), detail: "")
        case "Read":
            return Activity(symbol: "doc.text", title: tr("Читает файл", "Reading file"), detail: file())
        case "Edit", "MultiEdit":
            let edits = name == "Edit" ? [input] : input["edits"] as? [[String: Any]] ?? []
            let diff = edits.reduce((added: 0, removed: 0)) { sum, edit in
                let d = lineDiff(edit["old_string"] as? String ?? "", edit["new_string"] as? String ?? "")
                return (sum.added + d.added, sum.removed + d.removed)
            }
            return Activity(symbol: "pencil", title: tr("Редактирует", "Editing"), detail: file(), added: diff.added, removed: diff.removed)
        case "Write":
            return Activity(symbol: "doc.badge.plus", title: tr("Пишет файл", "Writing file"), detail: file(),
                            added: lineDiff("", str("content")).added)
        case "NotebookEdit":
            return Activity(symbol: "pencil", title: tr("Редактирует блокнот", "Editing notebook"), detail: file("notebook_path"),
                            added: lineDiff("", str("new_source")).added)
        case "Grep":
            return Activity(symbol: "magnifyingglass", title: tr("Ищет в коде", "Searching code"), detail: oneLine(str("pattern")), monospaced: true,
                            note: str("path").isEmpty ? "" : tr("в ", "in ") + file("path"), search: true)
        case "Glob":
            return Activity(symbol: "folder", title: tr("Ищет файлы", "Finding files"), detail: oneLine(str("pattern")), monospaced: true, search: true)
        case "WebSearch":
            return Activity(symbol: "globe", title: tr("Ищет в интернете", "Searching the web"), detail: oneLine(str("query")), search: true)
        case "WebFetch":
            return Activity(symbol: "globe", title: tr("Читает страницу", "Reading page"), detail: host(str("url")))
        case "Task", "Agent":
            return Activity(symbol: "person.2", title: tr("Запускает агента", "Starting an agent"), detail: oneLine(str("description")),
                            note: str("subagent_type"), agent: true)
        case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet":
            return Activity(symbol: "checklist", title: tr("Обновляет план", "Updating the plan"), detail: "", quiet: true)
        case "Skill":
            return Activity(symbol: "book", title: tr("Читает навык", "Reading a skill"), detail: str("skill"))
        case "ToolSearch":
            return Activity(symbol: "wrench.and.screwdriver", title: tr("Подключает инструменты", "Loading tools"), detail: "", quiet: true)
        default:
            return mcp(name, input)
        }
    }

    /// A prompt in plain words. Claude Code sends some prompts in your place, wrapped in tags: a background
    /// task that finished (`<task-notification>`, which comes back as `notice`), a slash command
    /// (`<command-name>`), reminders. The tags come out, so the notch shows words rather than markup.
    /// Only a prompt that starts with a tag is one of those: one you typed may well mention them.
    static func prompt(_ text: String) -> (text: String, notice: Activity?) {
        func words(_ text: String) -> String { String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(300)) }
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") else { return (words(text), nil) }
        func tag(_ name: String) -> String? {
            guard let open = text.range(of: "<\(name)>"),
                  let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
            return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.contains("<task-notification>") {
            // "Background command "Build the app" completed (exit code 0)": what's in quotes is what it was.
            let summary = tag("summary") ?? ""
            let what = oneLine(summary.range(of: #""(.+)""#, options: .regularExpression)
                .map { String(summary[$0].dropFirst().dropLast()) } ?? summary)
            let title: String
            switch tag("status") {
            case "completed": title = tr("Фоновая задача готова", "Background task done")
            case "failed": title = tr("Фоновая задача не удалась", "Background task failed")
            case "killed", "stopped": title = tr("Фоновая задача остановлена", "Background task stopped")
            default: title = tr("Фоновая задача", "Background task")
            }
            return (what.isEmpty ? title : "\(title) · \(what)", Activity(symbol: "bell.fill", title: title, detail: what, prose: true))
        }
        if let command = tag("command-name") {
            let args = tag("command-args") ?? ""
            return (oneLine(args.isEmpty ? command : "\(command) \(args)"), nil)
        }
        // Reminders go whole; other tags leave their words.
        let plain = text.replacingOccurrences(of: #"<system-reminder>[\s\S]*?</system-reminder>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"</?[A-Za-z][\w-]*(\s[^>]*)?>"#, with: " ", options: .regularExpression)
        return (words(plain), nil)
    }

    /// Tools that stop and wait for the user to answer.
    static func question(_ name: String, _ input: [String: Any]) -> Activity? {
        switch name {
        case "AskUserQuestion":
            // Up to four questions, each with two to four options: the first one, and how many there are.
            let questions = input["questions"] as? [[String: Any]] ?? []
            let first = questions.first ?? [:]
            let options = (first["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }.map(oneLine)
            return Activity(symbol: "questionmark.bubble.fill", title: tr("Задаёт тебе вопрос", "Asking you a question"),
                            detail: oneLine(first["question"] as? String ?? ""),
                            note: questions.count > 1 ? tr("Вопрос 1 из \(questions.count)", "Question 1 of \(questions.count)") : "",
                            prose: true, options: Array(options.filter { !$0.isEmpty }.prefix(4)))
        case "ExitPlanMode":
            return Activity(symbol: "list.bullet.clipboard", title: tr("Ждёт одобрения плана", "Waiting for plan approval"), detail: "")
        default:
            return nil
        }
    }

    static func permissionQuestion(_ tool: String, _ activity: Activity) -> String {
        switch tool {
        case "Bash": return tr("Разрешить команду?", "Allow this command?")
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return tr("Разрешить изменить файл?", "Allow editing this file?")
        case "WebFetch": return tr("Разрешить открыть страницу?", "Allow opening this page?")
        case "WebSearch": return tr("Разрешить поиск в интернете?", "Allow a web search?")
        case "Read", "Grep", "Glob": return tr("Разрешить чтение?", "Allow reading?")
        default: return tr("Разрешить «\(activity.title)»?", "Allow “\(activity.title)”?")
        }
    }

    /// A tool that ran and failed: what didn't work, and the error in one line.
    static func failure(_ name: String, _ tool: Activity, error: String) -> Activity {
        let title: String
        let what: String
        switch name {
        case "Bash":
            title = tr("Команда завершилась с ошибкой", "Command failed")
            what = tool.note.isEmpty ? tool.detail : tool.note
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            title = tr("Не удалось изменить файл", "Couldn't edit the file")
            what = tool.detail
        case "Read":
            title = tr("Не удалось прочитать файл", "Couldn't read the file")
            what = tool.detail
        case "WebFetch":
            title = tr("Страница не открылась", "Couldn't open the page")
            what = tool.detail
        default:
            title = tr("Инструмент вернул ошибку", "The tool returned an error")
            what = tool.headline
        }
        // Cut at the end: the exit code and the start of the message matter most.
        return Activity(symbol: "xmark.octagon.fill", title: title, detail: errorLine(error), monospaced: name == "Bash",
                        note: what, prose: true, failed: true)
    }

    /// A tool error in one line. A command's starts with "Exit code N", then its output: the code and
    /// the first line it printed.
    private static func errorLine(_ error: String) -> String {
        let lines = error.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first else { return "" }
        guard first.hasPrefix("Exit code ") else { return String(first.prefix(200)) }
        let code = tr("Код выхода ", "Exit code ") + first.dropFirst("Exit code ".count)
        return String((lines.count > 1 ? "\(code) · \(lines[1])" : code).prefix(200))
    }

    /// What a StopFailure's `error` kind means, in plain words: short enough for the notch's title line,
    /// with Claude Code's own message under it.
    static func apiError(_ kind: String) -> String {
        switch kind {
        case "rate_limit": return tr("Лимит запросов, попробуй позже", "Rate limited, try again soon")
        case "overloaded": return tr("Claude перегружен, подожди", "Claude is overloaded, wait a bit")
        case "authentication_failed": return tr("Нужно снова войти в Claude", "Signed out: log in again")
        case "oauth_org_not_allowed": return tr("Организация запрещает вход", "Login not allowed by your org")
        case "account_on_hold": return tr("Аккаунт приостановлен", "Your account is on hold")
        case "billing_error": return tr("Проблема с оплатой", "Billing problem")
        case "invalid_request": return tr("API отклонил запрос", "The API rejected the request")
        case "model_not_found": return tr("Эта модель недоступна", "That model isn't available")
        case "server_error": return tr("Сбой API, попробуй ещё раз", "API server error, try again")
        case "max_output_tokens": return tr("Ответ упёрся в лимит длины", "The reply hit the length limit")
        case "cloud_credential_error": return tr("Не подошли облачные ключи", "Cloud credentials failed")
        default: return tr("Ошибка", "Error")
        }
    }

    /// An MCP server's name as the notch shows it; nothing for the long ids some clients give theirs.
    static func server(_ name: String) -> String {
        name.count >= 32 && name.allSatisfy({ $0.isHexDigit || $0 == "-" }) ? "" : pretty(name)
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
        case "update_plan": return Activity(symbol: "checklist", title: tr("Обновляет план", "Updating the plan"), detail: "", quiet: true)
        case "wrap_up": return Activity(symbol: "flag.checkered", title: tr("Подводит итог", "Wrapping up"), detail: "", quiet: true)
        default: break
        }
        if server.localizedCaseInsensitiveContains("browser") || server.localizedCaseInsensitiveContains("chrome") {
            let url = input["url"] as? String
            return Activity(symbol: "safari", title: tr("Браузер", "Browser"), detail: url.map(host) ?? pretty(tool))
        }
        let shown = Self.server(server)
        return Activity(symbol: "puzzlepiece.extension", title: shown.isEmpty ? "MCP" : shown, detail: pretty(tool))
    }

    private static func pretty(_ s: String) -> String { s.replacingOccurrences(of: "_", with: " ") }

    private static func host(_ url: String) -> String { URL(string: url)?.host ?? url }
}
