import Combine
import Foundation
import Testing
@testable import ClaudeNotch

/// Telegram as the questions see it: what was sent and changed, and the look for presses that's out.
private final class FakeTelegram: QuestionChannel {
    var linked = true
    private(set) var asked: [(text: String, buttons: [[Telegram.Button]])] = []
    private(set) var edits: [(id: Int, text: String, buttons: [[Telegram.Button]])] = []
    /// Answers the look for presses with what was pressed.
    private(set) var look: (([String]) -> Void)?

    func ask(_ text: String, buttons: [[Telegram.Button]], sent: @escaping (Int?) -> Void) {
        asked.append((text, buttons))
        sent(asked.count)  // message ids 1, 2…
    }

    func edit(_ messageID: Int, _ text: String, buttons: [[Telegram.Button]]) {
        edits.append((messageID, text, buttons))
    }

    func pressed(tokens: [String], wait: Int, _ done: @escaping ([String]) -> Void) {
        look = done
    }
}

/// Claude's questions through the store and on to Telegram, as the app wires them: the questions hear of
/// every change to the prompts, once it's made.
@MainActor
struct TelegramQuestionsTests {
    private let store = Store()
    private let telegram = FakeTelegram()
    private let questions: TelegramQuestions
    private let observer: AnyCancellable

    init() {
        UserDefaults.standard.set(true, forKey: TelegramNote.question.key)
        let questions = TelegramQuestions(store: store, telegram: telegram, delay: 0.3)
        self.questions = questions
        observer = store.$prompts.sink { _ in DispatchQueue.main.async { questions.update() } }
    }

    private func ask() -> Hook {
        let hook = Hook()
        store.handle(["hook_event_name": "PermissionRequest", "session_id": "s1", "cwd": "/tmp/notch-project",
                      "tool_name": "AskUserQuestion", "tool_input": StoreTests.questions], reply: hook.reply)
        return hook
    }

    private func wait(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @Test func theNextQuestionWaitsItsTurnAfterAnAnswerAtTheMac() async throws {
        _ = ask()
        try await wait(0.05)
        let prompt = try #require(store.prompt)
        store.choose(prompt, option: 0)  // the first one answered at the Mac before it went out
        try await wait(0.4)
        #expect(telegram.asked.isEmpty)
        try await wait(0.4)
        #expect(telegram.asked.count == 1)
        #expect(telegram.asked.first?.text.contains("Which props?") == true)
    }

    @Test func aPressInTelegramAnswersAndTheNextGoesAtOnce() async throws {
        let hook = ask()
        try await wait(0.45)
        let first = try #require(telegram.asked.first)
        #expect(first.text.contains("Which animation?"))
        #expect(first.buttons.map { $0.map(\.text) } == [["Wizard"], ["Chef"]])

        let look = try #require(telegram.look)
        let chef = try #require(first.buttons[1].first?.data)
        look([chef])
        try await wait(0.05)
        #expect(telegram.edits.first?.id == 1)
        #expect(telegram.edits.first?.text.hasSuffix("Chef") == true)
        #expect(telegram.edits.first?.buttons.isEmpty == true)
        #expect(telegram.asked.count == 2)
        #expect(telegram.asked.last?.buttons.map { $0.map(\.text) }
                == [["◻️ Mug"], ["◻️ Book"], ["◻️ Pan"], [tr("Отправить", "Send")]])

        // The last one answered at the Mac: its message says so, without buttons.
        let prompt = try #require(store.prompt)
        store.choose(prompt, option: 2)
        store.submitPicked(prompt)
        try await wait(0.05)
        #expect(telegram.edits.last?.id == 2)
        #expect(telegram.edits.last?.buttons.isEmpty == true)
        let input = try #require(hook.decision()?["updatedInput"] as? [String: Any])
        #expect(input["answers"] as? [String: String] == ["Which animation?": "Chef", "Which props?": "Pan"])
    }
}
