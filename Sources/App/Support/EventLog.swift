import Foundation

/// Last events, for checking which hooks actually reach the app. Written on a background queue,
/// so no file I/O lands on the main thread.
enum EventLog {
    private static let formatter = ISO8601DateFormatter()
    private static let queue = DispatchQueue(label: "ClaudeNotch.eventlog", qos: .utility)
    /// Only the app writes it: not the tests, nor the tools built from its code.
    private static let enabled = Bundle.main.bundleURL.pathExtension == "app"

    static func append(_ line: String) {
        guard enabled else { return }
        let date = Date()
        queue.async {
            let path = Paths.eventLog
            let data = Data("\(formatter.string(from: date)) \(line)\n".utf8)
            if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size > 256_000 {
                try? FileManager.default.removeItem(atPath: path)
            }
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
    }
}
