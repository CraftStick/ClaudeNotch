import Foundation

extension URLSession {
    /// For every request the app makes: nothing goes to disk. URLSession.shared keeps a cache in
    /// ~/Library/Caches/<bundle id> with each request's headers, which would put the Claude Code login
    /// and the Telegram secret there in plain text.
    static let uncached: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
}
