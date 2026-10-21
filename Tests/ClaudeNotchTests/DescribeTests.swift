import Testing
@testable import ClaudeNotch

struct DescribeTests {
    // MARK: - Cheers

    @Test func testsAndPushesAreToldApart() {
        for command in ["swift test", "cd app && npm test", "npm run test -- --watch=false", "pytest -q", "go test ./...",
                        "cargo test", "python3 -m pytest", "make check"] {
            #expect(Describe.cheer(for: command) == .sparkler, "\(command)")
        }
        for command in ["git push", "git push -u origin main", "cd x && git push --force-with-lease", "git -C repo push"] {
            #expect(Describe.cheer(for: command) == .rocket, "\(command)")
        }
        for command in ["git status", "swift build", "ls test", "echo 'git pushed'", "cat latest.txt", "gh pr create"] {
            #expect(Describe.cheer(for: command) == nil, "\(command)")
        }
    }

    // MARK: - Prompts

    @Test func aTypedPromptIsShownAsTyped() {
        let said = Describe.prompt("  fix\n the   bug ")
        #expect(said.text == "fix the bug")
        #expect(said.notice == nil)
    }

    @Test func aTypedPromptMayMentionTags() {
        let text = "Why does <task-notification> show up, and what is <command-name>?"
        let said = Describe.prompt(text)
        #expect(said.text == text)
        #expect(said.notice == nil)
    }

    @Test func aFinishedBackgroundTaskIsANotice() throws {
        let said = Describe.prompt("""
            <task-notification>
            <task-id>b1</task-id>
            <status>completed</status>
            <summary>Background command "Build the app" completed (exit code 0)</summary>
            </task-notification>
            """)
        let notice = try #require(said.notice)
        #expect(notice.title == tr("Фоновая задача готова", "Background task done"))
        #expect(notice.detail == "Build the app")
        #expect(said.text == notice.title + " · Build the app")
    }

    @Test func aFailedBackgroundTaskSaysSo() {
        let said = Describe.prompt("<task-notification><status>failed</status><summary>It broke</summary></task-notification>")
        #expect(said.notice?.title == tr("Фоновая задача не удалась", "Background task failed"))
        #expect(said.notice?.detail == "It broke")
    }

    @Test func aSlashCommandIsShownAsTyped() {
        let said = Describe.prompt("<command-message>compact</command-message>\n<command-name>/compact</command-name>\n<command-args>keep it short</command-args>")
        #expect(said.text == "/compact keep it short")
        #expect(said.notice == nil)
    }

    @Test func remindersGoAndTagsLeaveTheirWords() {
        #expect(Describe.prompt("<system-reminder>secret\nstuff</system-reminder>\nFix <b>it</b>").text == "Fix it")
    }

    // MARK: - Tools

    @Test func aCommandShowsWhatItDoes() {
        let a = Describe.tool("Bash", ["command": "swift build\nswift test", "description": "Build and test"])
        #expect(a.detail == "swift build ⏎ swift test")
        #expect(a.note == "Build and test")
        #expect(a.command && a.monospaced)
        #expect(a.headline == "Build and test")
    }

    @Test func editsCountTheirLines() {
        let edit = Describe.tool("Edit", ["file_path": "/a/b/Store.swift", "old_string": "a\nb", "new_string": "a\nc\nd"])
        #expect(edit.detail == "Store.swift")
        #expect(edit.added == 2 && edit.removed == 1)

        let multi = Describe.tool("MultiEdit", ["file_path": "/x/y.swift", "edits": [
            ["old_string": "a", "new_string": "b"],
            ["old_string": "c\nd", "new_string": ""],
        ]])
        #expect(multi.added == 1 && multi.removed == 3)

        let write = Describe.tool("Write", ["file_path": "/x/new.txt", "content": "1\n2\n3\n"])
        #expect(write.added == 3 && write.removed == 0)
    }

    @Test func bookkeepingIsQuiet() {
        #expect(Describe.tool("TodoWrite", [:]).quiet)
        #expect(Describe.tool("ToolSearch", [:]).quiet)
        #expect(Describe.tool("mcp__ccd_turn__update_plan", [:]).quiet)
        #expect(!Describe.tool("Read", ["file_path": "/a"]).quiet)
    }

    @Test func mcpToolsShowTheirServer() {
        let issue = Describe.tool("mcp__github__create_issue", [:])
        #expect(issue.title == "github")
        #expect(issue.detail == "create issue")

        let browser = Describe.tool("mcp__Claude_Browser__navigate", ["url": "https://example.com/page"])
        #expect(browser.detail == "example.com")

        #expect(Describe.server("0123456789abcdef0123456789abcdef-0000") == "")
        #expect(Describe.server("my_server") == "my server")
    }

    @Test func aQuestionShowsItsFirstQuestionAndOptions() throws {
        let a = try #require(Describe.question("AskUserQuestion", ["questions": [
            ["question": "Which one?", "options": [["label": "A"], ["label": "B"]]],
            ["question": "And then?", "options": [["label": "C"]]],
        ]]))
        #expect(a.detail == "Which one?")
        #expect(a.options == ["A", "B"])
        #expect(a.note == tr("Вопрос 1 из 2", "Question 1 of 2"))
        #expect(Describe.question("Bash", [:]) == nil)
    }

    @Test func aFailedCommandShowsItsExitCodeAndFirstLine() {
        let tool = Describe.tool("Bash", ["command": "make", "description": "Build"])
        let failure = Describe.failure("Bash", tool, error: "Exit code 2\nfatal: bad thing\nmore")
        #expect(failure.detail == tr("Код выхода ", "Exit code ") + "2 · fatal: bad thing")
        #expect(failure.note == "Build")
        #expect(failure.failed)
    }

    @Test func apiErrorsHaveWords() {
        #expect(Describe.apiError("rate_limit") == tr("Лимит запросов, попробуй позже", "Rate limited, try again soon"))
        #expect(Describe.apiError("something new") == tr("Ошибка", "Error"))
    }
}
