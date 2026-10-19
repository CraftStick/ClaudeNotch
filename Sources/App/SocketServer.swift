import Darwin
import Foundation

enum Paths {
    static let home = getenv("HOME").map { String(cString: $0) } ?? NSHomeDirectory()
    static let dir = home + "/Library/Application Support/ClaudeNotch"
    static let socket = dir + "/notch.sock"
    static let eventLog = dir + "/events.log"
}

/// The open connection of one hook call. The hook waits until `send` is called and prints
/// what it receives as its output to Claude Code; `send(nil)` lets it exit with no output.
final class HookReply {
    private var fd: Int32
    private let lock = NSLock()

    init(fd: Int32) { self.fd = fd }

    /// For events that don't come from a hook (the demo).
    static var none: HookReply { HookReply(fd: -1) }

    deinit { send(nil) }

    func send(_ data: Data?) {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
        if let data, !data.isEmpty {
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n <= 0 { break }
                    offset += n
                }
            }
        }
        close(fd)
        fd = -1
    }
}

/// Accepts one hook payload per connection on a Unix socket and hands it to `onMessage`
/// (called on a background thread) together with the connection to answer on.
final class SocketServer {
    let path: String
    let onMessage: (Data, HookReply) -> Void

    init(path: String, onMessage: @escaping (Data, HookReply) -> Void) {
        self.path = path
        self.onMessage = onMessage
    }

    /// True if another ClaudeNotch instance is already listening on `path`.
    static func isAlive(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard var addr = makeAddress(path) else { return false }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    func start() throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var addr = Self.makeAddress(path) else { throw POSIXError(.EINVAL) }
        unlink(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        chmod(path, 0o600)
        guard listen(fd, 32) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        let onMessage = self.onMessage
        let thread = Thread {
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { continue }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 1, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var data = Data()
                while data.count < 8_000_000 {
                    let n = read(client, &chunk, chunk.count)
                    if n <= 0 { break }
                    data.append(chunk, count: n)
                }
                let reply = HookReply(fd: client)
                if data.isEmpty { reply.send(nil) } else { onMessage(data, reply) }
            }
        }
        thread.name = "ClaudeNotch.socket"
        thread.start()
    }

    func stop() {
        unlink(path)
    }

    private static func makeAddress(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        return addr
    }
}
