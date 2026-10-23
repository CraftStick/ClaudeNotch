import Foundation

/// Claude Code's login to your Claude plan, kept in the keychain item "Claude Code-credentials" (or in
/// ~/.claude/.credentials.json without a keychain): `{"claudeAiOauth":{"accessToken":…,"refreshToken":…,
/// "expiresAt":<ms>,…},…}`. Its token lasts hours, and Claude Code renews it only when it runs in a
/// terminal; the Claude app keeps a login of its own. So the token is often stale, and the app renews
/// it the way Claude Code does, then writes the new one back where it found it: renewing hands out a
/// new refresh token and voids the old one, which Claude Code would otherwise be left holding.
/// Read and written with `security`, which made that item and so uses it without asking. Off the main thread.
struct ClaudeLogin {
    static let service = "Claude Code-credentials"
    static let file = NSHomeDirectory() + "/.claude/.credentials.json"
    /// Where Claude Code renews its login, and the id it does it with.
    static let tokenEndpoints = [URL(string: "https://platform.claude.com/v1/oauth/token")!,
                                 URL(string: "https://console.anthropic.com/v1/oauth/token")!]
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// The whole item, kept as it is but for the tokens.
    private var json: [String: Any]
    /// The keychain account it's under; nil: it's the file.
    private let account: String?

    var token: String { oauth["accessToken"] as? String ?? "" }
    private var oauth: [String: Any] { json["claudeAiOauth"] as? [String: Any] ?? [:] }

    /// Expired, or due to in the next minute.
    var expired: Bool {
        guard let expires = (oauth["expiresAt"] as? NSNumber)?.doubleValue else { return false }
        return expires / 1000 < Date().timeIntervalSince1970 + 60
    }

    /// Nil without a Claude subscription (Claude Code signed in with an API key, or not at all).
    static func read() -> ClaudeLogin? {
        if let out = run(["find-generic-password", "-s", service, "-w"]), let login = ClaudeLogin(data: Data(out.utf8), account: account()) {
            return login
        }
        return (try? Data(contentsOf: URL(fileURLWithPath: file))).flatMap { ClaudeLogin(data: $0, account: nil) }
    }

    private init?(data: Data, account: String?) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any], (oauth["accessToken"] as? String)?.isEmpty == false else { return nil }
        self.json = json
        self.account = account
    }

    /// Gets a new token with the refresh token and saves it for Claude Code too. False if it couldn't:
    /// the refresh token has expired as well (Claude Code has to sign in again), or no network.
    mutating func renew() -> Bool {
        guard let refresh = oauth["refreshToken"] as? String, !refresh.isEmpty else { return false }
        let body: [String: Any] = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": Self.clientID]
        for endpoint in Self.tokenEndpoints {
            var request = URLRequest(url: endpoint, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            guard let (status, answer) = Self.load(request) else { continue }
            guard status == 200, let access = answer["access_token"] as? String, !access.isEmpty else {
                EventLog.append("Claude Code login: renewing failed, HTTP \(status)")
                if status == 400 || status == 401 { return false }  // the refresh token is no good: no point asking the other
                continue
            }
            var oauth = self.oauth
            oauth["accessToken"] = access
            if let refresh = answer["refresh_token"] as? String, !refresh.isEmpty { oauth["refreshToken"] = refresh }
            if let seconds = (answer["expires_in"] as? NSNumber)?.doubleValue {
                oauth["expiresAt"] = Int64((Date().timeIntervalSince1970 + seconds) * 1000)
            }
            if let scope = answer["scope"] as? String { oauth["scopes"] = scope.split(separator: " ").map(String.init) }
            json["claudeAiOauth"] = oauth
            let saved = save()
            EventLog.append(saved ? "Claude Code login renewed" : "Claude Code login renewed, but couldn't be saved")
            return true
        }
        return false
    }

    /// Writes the login back where it came from, in the form Claude Code writes it.
    private func save() -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return false }
        guard let account else {
            return (try? data.write(to: URL(fileURLWithPath: Self.file), options: .atomic)) != nil
        }
        // Through `security -i`, so the login goes in on stdin rather than in a command line any
        // process can see; as hex, so no quoting can break it.
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let quotedAccount = "\"" + account.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        let command = "add-generic-password -U -a \(quotedAccount) -s \"\(Self.service)\" -X \(hex)\n"
        // `security -i` reads lines of 4 KB at most; a longer one (MCP servers' logins ride along) goes as arguments.
        let wrote = command.utf8.count < 4000
            ? Self.run(["-i"], input: command)
            : Self.run(["add-generic-password", "-U", "-a", account, "-s", Self.service, "-X", hex])
        guard wrote != nil else { return false }
        return Self.read()?.token == token
    }

    /// The item's account: Claude Code puts your user name there.
    private static func account() -> String? {
        guard let out = run(["find-generic-password", "-s", service]) else { return nil }
        for line in out.split(separator: "\n") where line.contains("\"acct\"<blob>=\"") {
            return line.components(separatedBy: "\"acct\"<blob>=\"").last.map { String($0.dropLast()) }
        }
        return NSUserName()
    }

    /// `security` with `arguments` (and `input` on stdin): what it printed, nil if it failed.
    private static func run(_ arguments: [String], input: String? = nil) -> String? {
        let security = Process()
        security.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        security.arguments = arguments
        let out = Pipe(), inPipe = Pipe()
        security.standardOutput = out
        security.standardError = FileHandle.nullDevice
        if input != nil { security.standardInput = inPipe }
        guard (try? security.run()) != nil else { return nil }
        if let input {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        security.waitUntilExit()
        guard security.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A request's status and JSON, waited for: this runs off the main thread.
    static func load(_ request: URLRequest) -> (Int, [String: Any])? {
        var result: (Int, [String: Any])?
        let done = DispatchSemaphore(value: 0)
        URLSession.uncached.dataTask(with: request) { data, response, _ in
            if let response = response as? HTTPURLResponse {
                result = (response.statusCode, data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:])
            }
            done.signal()
        }.resume()
        done.wait()
        return result
    }
}
