import Foundation

/// Claude's questions in Telegram, its options as buttons: a press answers in the notch, as a click there
/// would. A question goes out once it has waited `delay` unanswered (at the Mac you'd have answered it by
/// then); the next of several goes out as soon as one is answered. A message whose question is answered,
/// there or at the Mac, or gone, says so and loses its buttons. Used on the main thread.
final class TelegramQuestions {
    static let delay: TimeInterval = 20

    private struct Sent {
        let prompt: UUID
        let step: Int
        /// Ties the buttons' data to this message: "<token>:<option>", "<token>:send".
        let token: String
        let text: String
        var messageID: Int?
        var picked: Set<Int> = []
        /// The answer given in Telegram, for the message once it's closed.
        var answer: String?
    }

    private let store: Store
    private let telegram: Telegram
    private var sent: [Sent] = []
    private var waiting: Set<UUID> = []
    private var poll: Timer?

    init(store: Store, telegram: Telegram) {
        self.store = store
        self.telegram = telegram
    }

    /// Questions go to Telegram: it's linked, and they're switched on.
    var active: Bool { telegram.linked && TelegramNote.question.enabled }

    /// The prompts changed: a new question waits its turn, answered ones are told.
    func update() {
        let prompts = store.prompts
        for i in sent.indices.reversed() {
            guard let prompt = prompts.first(where: { $0.id == sent[i].prompt }), let form = prompt.form else {
                let done = sent.remove(at: i)
                close(done, answer: done.answer)
                continue
            }
            if form.step != sent[i].step {  // answered: on to the next question
                let done = sent.remove(at: i)
                close(done, answer: done.answer ?? form.answers[form.questions[done.step].text])
                send(prompt)
            } else if form.picked != sent[i].picked, let id = sent[i].messageID {
                sent[i].picked = form.picked
                telegram.edit(id, sent[i].text, buttons: Self.buttons(form, token: sent[i].token))
            }
        }
        guard active else { return }
        for prompt in prompts where prompt.form != nil && !waiting.contains(prompt.id) && !sent.contains(where: { $0.prompt == prompt.id }) {
            waiting.insert(prompt.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay) { [weak self] in
                guard let self else { return }
                self.waiting.remove(prompt.id)
                guard self.active, let now = self.store.prompts.first(where: { $0.id == prompt.id }), now.form?.step == prompt.form?.step else { return }
                self.send(now)
            }
        }
    }

    private func send(_ prompt: PermissionPrompt) {
        guard active, let form = prompt.form else { return }
        let session = store.sessions[prompt.sessionID]
        var head = "\(TelegramEmoji.question) " + tr("Claude спрашивает", "Claude asks")
        if let project = session?.project, !project.isEmpty { head += " · " + escapeHTML(project) }
        if form.questions.count > 1 { head += " · \(form.step + 1)/\(form.questions.count)" }
        let q = form.current
        var lines = [head, "", "<b>\(escapeHTML(q.text))</b>"]
        let described = q.options.filter { !$0.detail.isEmpty }
        if !described.isEmpty {
            lines.append("")
            lines += described.map { "• <b>\(escapeHTML($0.label))</b> — \(escapeHTML($0.detail))" }
        }
        if q.multiSelect { lines += ["", tr("Можно выбрать несколько, потом «Отправить».", "Pick any, then Send.")] }
        let text = lines.joined(separator: "\n")
        let token = Self.token()
        sent.append(Sent(prompt: prompt.id, step: form.step, token: token, text: text))
        EventLog.append("Telegram question")
        telegram.ask(text, buttons: Self.buttons(form, token: token)) { [weak self] id in
            guard let self, let i = self.sent.firstIndex(where: { $0.token == token }) else {
                if let id { self?.telegram.edit(id, text + "\n\n" + tr("Уже не ждёт ответа.", "No longer waiting for an answer.")) }
                return
            }
            self.sent[i].messageID = id
            self.syncPolling()
        }
    }

    /// The question's message without its buttons, with what became of it.
    private func close(_ done: Sent, answer: String?) {
        syncPolling()
        guard let id = done.messageID else { return }
        let outcome = answer.map { "✅ " + escapeHTML($0) } ?? tr("Уже не ждёт ответа: ответили на Mac или вопрос закрыт.",
                                                                 "No longer waiting: answered at the Mac, or the question closed.")
        telegram.edit(id, done.text + "\n\n" + outcome)
    }

    /// One button per option, ticked where several may be picked, then Send.
    private static func buttons(_ form: QuestionForm, token: String) -> [[Telegram.Button]] {
        let q = form.current
        var rows = q.options.enumerated().map { i, option in
            [Telegram.Button(text: q.multiSelect ? (form.picked.contains(i) ? "☑️ " : "◻️ ") + option.label : option.label, data: "\(token):\(i)")]
        }
        if q.multiSelect { rows.append([Telegram.Button(text: tr("Отправить", "Send"), data: "\(token):send")]) }
        return rows
    }

    // MARK: - Presses

    /// Looks for presses every two seconds while a question is out.
    private func syncPolling() {
        let wanted = sent.contains { $0.messageID != nil }
        guard wanted != (poll != nil) else { return }
        poll?.invalidate()
        poll = nil
        guard wanted else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.telegram.pressed { self?.apply($0) }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private func apply(_ presses: [String]) {
        for data in presses {
            let parts = data.split(separator: ":").map(String.init)
            guard parts.count == 2, let i = sent.firstIndex(where: { $0.token == parts[0] }),
                  let prompt = store.prompts.first(where: { $0.id == sent[i].prompt }), let form = prompt.form,
                  form.step == sent[i].step else { continue }
            EventLog.append("Answered from Telegram")
            if parts[1] == "send" {
                guard !form.picked.isEmpty else { continue }
                sent[i].answer = form.picked.sorted().map { form.current.options[$0].label }.joined(separator: ", ")
                store.submitPicked(prompt)
            } else if let option = Int(parts[1]), form.current.options.indices.contains(option) {
                if !form.current.multiSelect { sent[i].answer = form.current.options[option].label }
                store.choose(prompt, option: option)
            }
        }
    }

    private static func token() -> String {
        String((0..<8).map { _ in "abcdefghijkmnpqrstuvwxyz23456789".randomElement()! })
    }
}
