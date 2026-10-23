import Foundation
import Security

/// What the app can tell you in Telegram, each switched on or off in the settings.
enum TelegramNote: String, CaseIterable {
    case limitReached, limitBack, done, waiting, failed

    var key: String { "telegram.\(rawValue)" }
    var enabled: Bool { UserDefaults.standard.bool(forKey: key) }

    var label: String {
        switch self {
        case .limitReached: return tr("Закончился лимит", "A limit ran out")
        case .limitBack: return tr("Лимит снова доступен", "A limit is back")
        case .done: return tr("Claude закончил задачу", "Claude is done")
        case .waiting: return tr("Claude ждёт тебя", "Claude is waiting for you")
        case .failed: return tr("Ошибка API", "An API error")
        }
    }

    var symbol: String {
        switch self {
        case .limitReached: return "hourglass"
        case .limitBack: return "battery.100.bolt"
        case .done: return "checkmark.circle"
        case .waiting: return "hand.raised"
        case .failed: return "exclamationmark.triangle"
        }
    }

    /// The limits by default; what Claude does only if you ask for it.
    static let defaults: [String: Any] = [limitReached.key: true, limitBack.key: true]
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
        }
    }

    func unlink() {
        call("link", method: "DELETE") { _, _ in }
        set(chat: nil)
    }

    /// Sends `text` if the Mac is linked and `note` is switched on.
    func send(_ note: TelegramNote, _ text: String) {
        guard linked, note.enabled else { return }
        EventLog.append("Telegram \(note.rawValue)")
        post(text)
    }

    func sendTest() {
        post(tr("👋 Это Claude Notch: уведомления работают.", "👋 It's Claude Notch: notifications work."))
    }

    private func post(_ text: String) {
        call("notify", method: "POST", body: ["text": text]) { [weak self] _, status in
            if status == 410 { self?.set(chat: nil) }  // unlinked in Telegram with /stop
        }
    }

    private func set(chat: String?) {
        if chat != nil {
            watch?.invalidate()
            watch = nil
            linking = .idle
        }
        guard chat != self.chat else { return }
        self.chat = chat
        UserDefaults.standard.set(chat, forKey: Self.chatKey)
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
