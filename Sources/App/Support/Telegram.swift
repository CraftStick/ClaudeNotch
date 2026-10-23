import Foundation
import Security

/// What the app can tell you in Telegram, each switched on or off in the settings.
enum TelegramNote: String, CaseIterable {
    case limitReached, limitBack, question, done, waiting, failed

    var key: String { "telegram.\(rawValue)" }
    var enabled: Bool { UserDefaults.standard.bool(forKey: key) }

    var label: String {
        switch self {
        case .limitReached: return tr("Закончился лимит", "A limit ran out")
        case .limitBack: return tr("Лимит снова доступен", "A limit is back")
        case .question: return tr("Вопросы Claude с кнопками ответа", "Claude's questions, with buttons to answer")
        case .done: return tr("Claude закончил задачу", "Claude is done")
        case .waiting: return tr("Claude ждёт тебя", "Claude is waiting for you")
        case .failed: return tr("Ошибка API", "An API error")
        }
    }

    var symbol: String {
        switch self {
        case .limitReached: return "hourglass"
        case .limitBack: return "battery.100.bolt"
        case .question: return "questionmark.bubble"
        case .done: return "checkmark.circle"
        case .waiting: return "hand.raised"
        case .failed: return "exclamationmark.triangle"
        }
    }

    /// The limits and questions by default; what else Claude does only if you ask for it.
    static let defaults: [String: Any] = [limitReached.key: true, limitBack.key: true, question.key: true]
}

/// The emoji in the messages: Telegram's animated ones, each with the plain one it shows where it can't.
enum TelegramEmoji {
    static let limit = animated("5278778882848220741", "📊")
    static let back = animated("5318983530540212017", "🟢")
    static let done = animated("5222021113369893480", "✅")
    static let waiting = animated("5222237691390762213", "⏱️")
    static let failed = animated("5276240711795107620", "⚠️")
    static let hello = animated("5222459157084411333", "👋")
    static let question = "❓"

    private static func animated(_ id: String, _ plain: String) -> String {
        "<tg-emoji emoji-id=\"\(id)\">\(plain)</tg-emoji>"
    }
}

/// Text as it reads in Telegram's HTML.
func escapeHTML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
}

/// Notifications in Telegram, through Claude Notch's bot (Server/ in the repository). The Mac has a
/// random secret of its own; the bot hands it a one-time code, you send the code to the bot, and the
/// Mac's messages go to your chat from then on. Used on the main thread.
final class Telegram: ObservableObject {
    enum Linking: Equatable {
        case idle, asking
        case code(String, link: URL, bot: String, expires: Date)
        case failed
    }

    static let server = URL(string: "https://claude-notch-bot.workersse.workers.dev")!
    private static let secretKey = "telegramSecret"
    private static let chatKey = "telegramChat"

    /// Who the Mac is linked to ("@name"), nil while it isn't.
    @Published private(set) var chat: String? = UserDefaults.standard.string(forKey: chatKey)
    /// The Mac was just linked: what's true now (a limit that ran out) can be told.
    var onLinked: () -> Void = {}
    @Published private(set) var linking = Linking.idle
    private var watch: Timer?

    var linked: Bool { chat != nil }

    /// Asks the bot for a code to send it, then watches for the chat it gets sent from.
    func requestCode() {
        linking = .asking
        call("code", method: "POST") { [weak self] json, _ in
            guard let self else { return }
            guard let code = json?["code"] as? String, let link = (json?["link"] as? String).flatMap(URL.init(string:)),
                  let expires = (json?["expires"] as? NSNumber)?.doubleValue else {
                self.linking = .failed
                return
            }
            self.linking = .code(code, link: link, bot: json?["bot"] as? String ?? "", expires: Date(timeIntervalSince1970: expires))
            self.watchForLink(until: Date(timeIntervalSince1970: expires))
        }
    }

    /// Looks every few seconds until the code is used or has expired.
    private func watchForLink(until end: Date) {
        watch?.invalidate()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            guard Date() < end, case .code = self.linking else {
                timer.invalidate()
                if case .code = self.linking { self.linking = .idle }
                return
            }
            self.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
    }

    /// Whether the Mac is still linked, and to whom: when the settings open, and while a code waits.
    func refresh() {
        call("status", method: "GET") { [weak self] json, _ in
            guard let self, let json, let linked = json["linked"] as? Bool else { return }
            self.set(chat: linked ? (json["name"] as? String ?? "Telegram") : nil)
            guard linked else { return }
            // What to send is switched in the chat's Features too: the bot's list wins. A Mac it hasn't
            // heard from yet tells it its own.
            if let enabled = json["prefs"] as? [String] {
                for note in TelegramNote.allCases where note.enabled != enabled.contains(note.rawValue) {
                    UserDefaults.standard.set(enabled.contains(note.rawValue), forKey: note.key)
                }
            } else {
                self.syncPrefs()
            }
        }
    }

    /// Tells the bot what to send, after a switch in the settings.
    func syncPrefs() {
        guard linked else { return }
        call("prefs", method: "POST", body: ["enabled": TelegramNote.allCases.filter(\.enabled).map(\.rawValue)]) { _, _ in }
    }

    /// Looks again every quarter of an hour while linked, for what was switched in the chat.
    func watchPrefs() {
        let timer = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
            if self?.linked == true { self?.refresh() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
    }

    func unlink() {
        call("link", method: "DELETE") { _, _ in }
        set(chat: nil)
    }

    /// Sends `text`, Telegram's HTML (`escapeHTML` the rest), if the Mac is linked. Whether `note` is
    /// switched on the bot decides: it's switched in the chat too, and the settings here may be behind.
    func send(_ note: TelegramNote, _ text: String) {
        guard linked else { return }
        EventLog.append("Telegram \(note.rawValue)")
        post(text, kind: note)
    }

    func sendTest() {
        post("\(TelegramEmoji.hello) " + tr("Это Claude Notch: уведомления работают.", "It's Claude Notch: notifications work."))
    }

    /// A button under a message: what it says, and what comes back when it's pressed.
    struct Button {
        let text: String
        let data: String
    }

    /// Sends `text` with rows of `buttons` under it; `sent` gets the message's id, to edit it later.
    func ask(_ text: String, buttons: [[Button]], sent: @escaping (Int?) -> Void) {
        guard linked else { return sent(nil) }
        post(text, kind: .question, buttons: buttons, sent: sent)
    }

    /// Changes a message sent before; no buttons takes them away.
    func edit(_ messageID: Int, _ text: String, buttons: [[Button]] = []) {
        call("edit", method: "POST", body: ["message_id": messageID, "text": text, "html": true, "buttons": Self.rows(buttons)]) { _, _ in }
    }

    /// The buttons pressed since the last look, as their data.
    func pressed(_ done: @escaping ([String]) -> Void) {
        call("answers", method: "GET") { json, _ in done(json?["answers"] as? [String] ?? []) }
    }

    /// `kind`: the bot drops the message if that's been switched off in the chat since we last looked.
    private func post(_ text: String, kind: TelegramNote? = nil, buttons: [[Button]] = [], sent: @escaping (Int?) -> Void = { _ in }) {
        var body: [String: Any] = ["text": text, "html": true]
        if let kind { body["kind"] = kind.rawValue }
        if !buttons.isEmpty { body["buttons"] = Self.rows(buttons) }
        call("notify", method: "POST", body: body) { [weak self] json, status in
            if status == 410 { self?.set(chat: nil) }  // unlinked in Telegram with /stop
            sent((json?["message_id"] as? NSNumber)?.intValue)
        }
    }

    private static func rows(_ buttons: [[Button]]) -> [[[String: String]]] {
        buttons.map { $0.map { ["text": $0.text, "data": $0.data] } }
    }

    private func set(chat: String?) {
        if chat != nil {
            watch?.invalidate()
            watch = nil
            linking = .idle
        }
        guard chat != self.chat else { return }
        let linkedNow = self.chat == nil && chat != nil
        self.chat = chat
        UserDefaults.standard.set(chat, forKey: Self.chatKey)
        if linkedNow { onLinked() }
    }

    /// The Mac's own secret, made the first time it's needed.
    private static var secret: String {
        if let secret = UserDefaults.standard.string(forKey: secretKey) { return secret }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let secret = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        UserDefaults.standard.set(secret, forKey: secretKey)
        return secret
    }

    private func call(_ route: String, method: String, body: [String: Any]? = nil,
                      done: @escaping ([String: Any]?, Int) -> Void) {
        var request = URLRequest(url: Self.server.appendingPathComponent("v1/\(route)"), timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("Bearer \(Self.secret)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let json = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async { done(status == 200 ? json : nil, status) }
        }.resume()
    }
}
