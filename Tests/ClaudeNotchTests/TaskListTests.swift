import Testing
@testable import ClaudeNotch

struct TaskListTests {
    @Test func todoWriteSendsTheWholeList() throws {
        var tasks = TaskList()
        tasks.apply("TodoWrite", ["todos": [
            ["content": "Read the code", "status": "completed"],
            ["content": "Fix the bug", "activeForm": "Fixing the bug", "status": "in_progress"],
            ["content": "Run the tests", "status": "pending"],
        ]], useID: nil)
        #expect(tasks.count == 3)
        #expect(tasks.completed == 1)
        let current = try #require(tasks.current)
        #expect(current.step == 2 && current.title == "Fixing the bug")
        #expect(abs(tasks.fraction - 1.0 / 3) < 0.001)
    }

    @Test func taskCreateGetsItsNumberFromTheAnswer() {
        var tasks = TaskList()
        tasks.apply("TaskCreate", ["subject": "Write tests", "activeForm": "Writing tests"], useID: "u1")
        #expect(tasks.isEmpty)  // not until Claude Code says which number it got
        tasks.finish("TaskCreate", response: "Task #7 created successfully: Write tests", useID: "u1")
        #expect(tasks.count == 1)

        tasks.apply("TaskUpdate", ["taskId": "7", "status": "in_progress"], useID: nil)
        #expect(tasks.current?.title == "Writing tests")
        tasks.apply("TaskUpdate", ["taskId": "7", "status": "completed"], useID: nil)
        #expect(tasks.current == nil)
        tasks.apply("TaskUpdate", ["taskId": "7", "status": "deleted"], useID: nil)
        #expect(tasks.isEmpty)
    }

    @Test func aStructuredAnswerWorksToo() {
        var tasks = TaskList()
        tasks.apply("TaskCreate", ["subject": "One"], useID: "u1")
        tasks.finish("TaskCreate", response: ["task": ["id": "4", "subject": "One"]], useID: "u1")
        tasks.apply("TaskUpdate", ["taskId": 4, "subject": "One, renamed"], useID: nil)
        #expect(tasks.items.map(\.title) == ["One, renamed"])
    }

    @Test func theClaudeAppsPlanMovesStepByStep() {
        var tasks = TaskList()
        let plan = "mcp__ccd_turn__update_plan"
        tasks.apply(plan, ["items": [
            ["content": "Look", "status": "in_progress"],
            ["content": "Fix", "status": "pending"],
            ["content": "Test", "status": "pending"],
        ]], useID: nil)
        tasks.apply(plan, ["advance": true], useID: nil)
        #expect(tasks.items.map(\.status) == ["completed", "in_progress", "pending"])
        tasks.apply(plan, ["done": [2], "start": 3], useID: nil)
        #expect(tasks.items.map(\.status) == ["completed", "completed", "in_progress"])
        tasks.apply("mcp__ccd_turn__wrap_up", [:], useID: nil)
        #expect(tasks.current == nil)
        #expect(tasks.fraction == 1)
    }

    @Test func onlyTaskToolsAreHandled() {
        #expect(TaskList.handles("TodoWrite"))
        #expect(TaskList.handles("mcp__ccd_turn__update_plan"))
        #expect(!TaskList.handles("Bash"))
        #expect(!TaskList.handles("TaskList"))
    }
}
