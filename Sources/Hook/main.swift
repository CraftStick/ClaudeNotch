// claude-notch-hook: Claude Code runs this on every hook event.
// It forwards the JSON payload from stdin to the ClaudeNotch app over a Unix socket,
// then prints whatever the app answers (only permission requests get an answer).
// It always exits 0, so it can never break or block Claude for long.
import Darwin

signal(SIGPIPE, SIG_IGN)
signal(SIGALRM) { _ in _exit(0) }
alarm(3)

var payload = [UInt8]()
var chunk = [UInt8](repeating: 0, count: 65536)
while true {
    let n = read(0, &chunk, chunk.count)
    if n <= 0 { break }
    payload.append(contentsOf: chunk[0..<n])
}

func contains(_ haystack: [UInt8], _ needle: String) -> Bool {
    let n = Array(needle.utf8)
    guard !n.isEmpty, haystack.count >= n.count else { return false }
    for i in 0...(haystack.count - n.count) where haystack[i] == n[0] {
        if Array(haystack[i..<(i + n.count)]) == n { return true }
    }
    return false
}

// A permission request waits for a click in the notch (Claude Code's own timeout is 600 s).
if contains(payload, "\"PermissionRequest\"") { alarm(590) }

guard !payload.isEmpty, let home = getenv("HOME") else { exit(0) }
let path = String(cString: home) + "/Library/Application Support/ClaudeNotch/notch.sock"

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(path.utf8)
guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { exit(0) }
withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }

let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else { exit(0) }  // app not running: nothing to do

var offset = 0
while offset < payload.count {
    let n = payload[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    if n <= 0 { break }
    offset += n
}
shutdown(fd, SHUT_WR)

var answer = [UInt8]()
while true {
    let n = read(fd, &chunk, chunk.count)
    if n <= 0 { break }
    answer.append(contentsOf: chunk[0..<n])
}
close(fd)
if !answer.isEmpty { _ = answer.withUnsafeBytes { write(1, $0.baseAddress, $0.count) } }
exit(0)
