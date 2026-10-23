import Darwin
import Foundation

/// Last events, for checking which hooks actually reach the app. Written on a background queue,
/// so no file I/O lands on the main thread, to a file kept open between lines; past 256 KB it keeps
/// its newer half.
enum EventLog {
    private static let formatter = ISO8601DateFormatter()
    private static let queue = DispatchQueue(label: "ClaudeNotch.eventlog", qos: .utility)
    /// Only the app writes it: not the tests, nor the tools built from its code.
    private static let enabled = Bundle.main.bundleURL.pathExtension == "app"
    private static let limit = 256_000
    /// The open log and how big it is: only touched on `queue`.
    private static var handle: FileHandle?
    private static var size = 0

    static func append(_ line: String) {
        guard enabled else { return }
        let date = Date()
        queue.async {
            let data = Data("\(formatter.string(from: date)) \(line)\n".utf8)
            guard let log = openLog() else { return }
            try? log.write(contentsOf: data)
            size += data.count
            if size > limit { keepNewerHalf() }
        }
    }

    /// The log, opened again if it was deleted meanwhile (by hand, say).
    private static func openLog() -> FileHandle? {
        var info = stat()
        if let handle, fstat(handle.fileDescriptor, &info) == 0, info.st_nlink > 0 { return handle }
        try? handle?.close()
        handle = nil
        let fd = open(Paths.eventLog, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        size = fstat(fd, &info) == 0 ? Int(info.st_size) : 0
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        return handle
    }

    /// Cut down to its newer half, from the start of a line, rather than started over empty.
    private static func keepNewerHalf() {
        try? handle?.close()
        handle = nil
        guard let data = FileManager.default.contents(atPath: Paths.eventLog) else { return }
        let tail = data.suffix(limit / 2)
        let start = tail.firstIndex(of: UInt8(ascii: "\n")).map { tail.index(after: $0) } ?? tail.startIndex
        try? Data(tail[start...]).write(to: URL(fileURLWithPath: Paths.eventLog), options: .atomic)
    }
}
