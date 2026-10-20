import Foundation
import Testing
@testable import ClaudeNotch

struct QuestionFormTests {
    static let input: [String: Any] = ["questions": [
        ["question": "Which animation?", "header": "Pick", "multiSelect": false,
         "options": [["label": "Wizard", "description": "Hat and wand\nand more"], ["label": "Chef"]]],
        ["question": "Which props?", "multiSelect": true,
         "options": [["label": "Mug"], ["label": "Book"], ["label": "Pan"]]],
    ]]

    @Test func readsTheQuestions() throws {
        let form = try #require(QuestionForm(Self.input))
        #expect(form.questions.count == 2)
        #expect(form.current.text == "Which animation?")
        #expect(form.current.options.map(\.label) == ["Wizard", "Chef"])
        #expect(form.current.options[0].detail == "Hat and wand")
        #expect(!form.current.multiSelect)
        #expect(form.questions[1].multiSelect)
    }

    @Test func needsAQuestionWithOptions() {
        #expect(QuestionForm([:]) == nil)
        #expect(QuestionForm(["questions": [["question": "Empty?", "options": []]]]) == nil)
        #expect(QuestionForm(["questions": [["question": "", "options": [["label": "A"]]]]]) == nil)
    }

    @Test func keepsFourOptionsWithLabels() throws {
        let options = ["", "A", "B", "C", "D", "E"].map { ["label": $0] }
        let form = try #require(QuestionForm(["questions": [["question": "Q", "options": options]]]))
        #expect(form.current.options.map(\.label) == ["A", "B", "C", "D"])
    }

    @Test func answersOneQuestionAfterAnother() throws {
        var form = try #require(QuestionForm(Self.input))
        let first = form.answer([1])
        #expect(!first)
        #expect(form.step == 1)
        #expect(form.answers == ["Which animation?": "Chef"])
        // Several answers in the order they're listed, whatever order they were picked in.
        let last = form.answer([2, 0])
        #expect(last)
        #expect(form.answers["Which props?"] == "Mug, Pan")
    }
}

struct SessionTests {
    private func session(_ phase: Phase, at now: Date) -> Session {
        var s = Session(id: "s", turnStart: now, lastEvent: now)
        s.phase = phase
        return s
    }

    @Test func clawdFollowsWhatClaudeDoes() {
        let now = Date()
        #expect(session(.waiting, at: now).desiredMotion(at: now) == .waving)
        #expect(session(.done, at: now).desiredMotion(at: now) == .done)
        #expect(session(.thinking, at: now).desiredMotion(at: now) == .typing)
        #expect(session(.thinking, at: now).desiredMotion(at: now + 13) == .pondering)

        var command = session(.tool, at: now)
        command.activity = Describe.tool("Bash", ["command": "make"])
        #expect(command.desiredMotion(at: now + 1) == .typing)
        #expect(command.desiredMotion(at: now + 9) == .desktop)

        var agent = session(.tool, at: now)
        agent.activity = Describe.tool("Task", [:])
        #expect(agent.desiredMotion(at: now) == .running)

        var busy = session(.tool, at: now)
        busy.recentTools = (0..<6).map { now - Double($0) }
        #expect(busy.desiredMotion(at: now) == .running)
        #expect(busy.desiredMotion(at: now + 20) == .typing)
    }

    @Test func quietIsCountedFromFiveMinutes() {
        let now = Date()
        let s = session(.tool, at: now)
        #expect(s.quietMinutes(at: now + 299) == nil)
        #expect(s.quietMinutes(at: now + 360) == 6)
        #expect(session(.waiting, at: now).quietMinutes(at: now + 3600) == nil)
    }

    @Test func soundsComeOnceForEventsTogether() {
        let now = Date()
        var s = session(.tool, at: now)
        let chimes = [now, now + 0.1, now + 1.9, now + 3].map { s.takesChime(at: $0) }
        #expect(chimes == [true, false, false, true])
    }

    @Test func facepalmsAreSpacedOut() {
        let now = Date()
        var s = session(.thinking, at: now)
        s.facepalm(at: now)
        #expect(s.cue == .facepalm && s.cueStart == now)
        s.facepalm(at: now + 10)
        #expect(s.cueStart == now)
        s.facepalm(at: now + 50)
        #expect(s.cueStart == now + 50)
    }

    @Test func historyKeepsTheLastFour() {
        var s = session(.tool, at: Date())
        for i in 1...6 { s.record(Activity(symbol: "", title: "\(i)", detail: "")) }
        #expect(s.history.map(\.title) == ["3", "4", "5", "6"])
    }
}
