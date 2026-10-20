// claude-notch-hook: Claude Code runs this on every hook event.
// It forwards the JSON payload from stdin to the ClaudeNotch app over a Unix socket,
// then prints whatever the app answers (only permission requests get an answer).
// It always exits 0, so it can never break or block Claude for long.
import Darwin

signal(SIGPIPE, SIG_IGN)
signal(SIGALRM) { _ in _exit(0) }
alarm(2)  // under the 3 s timeout in settings.json: exit cleanly before Claude Code kills us

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
        if haystack[i..<(i + n.count)].elementsEqual(n) { return true }
    }
    return false
}

// A permission request waits for a click in the notch (Claude Code's own timeout is 600 s).
if contains(payload, "\"PermissionRequest\"") { alarm(590) }

/// Tell the app which app runs this session (Terminal, iTerm, VS Code, Claude…), so a click on
/// the notch can bring it to the front: macOS passes the launching app's bundle id down to child
/// processes in __CFBundleIdentifier.
func env(_ name: String) -> String {
    guard let value = getenv(name) else { return "" }
    return String(String(cString: value).unicodeScalars.filter {
        ($0.properties.isAlphabetic && $0.isASCII) || ("0"..."9").contains($0) || "._-".unicodeScalars.contains($0)
    }.prefix(100))
}
/// The terminal tab Claude Code runs in (/dev/ttys003), so a click on the notch can pick out that very tab
/// in Terminal or iTerm: the controlling terminal of this process or of the nearest parent that has one.
/// Empty in the desktop app, which runs Claude Code without a terminal.
func terminalDevice() -> String {
    var pid = getpid()
    for _ in 0..<10 where pid > 1 {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
        let dev = info.kp_eproc.e_tdev
        if dev != -1, let name = devname(dev, S_IFCHR) {  // -1: no terminal
            let tty = String(cString: name)
            if tty.hasPrefix("tty"), tty.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) { return "/dev/" + tty }
        }
        pid = info.kp_eproc.e_ppid
    }
    return ""
}

if let close = payload.lastIndex(of: UInt8(ascii: "}")) {
    let before = payload[..<close].last { ![UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t")].contains($0) }
    let comma = before == UInt8(ascii: "{") ? "" : ","
    // CLAUDE_CODE_ENTRYPOINT tells the terminal ("cli") from the desktop app and IDE extensions,
    // which show their own permission dialog while the hook runs.
    let extra = comma + "\"notch_host\":\"\(env("__CFBundleIdentifier"))\",\"notch_term\":\"\(env("TERM_PROGRAM"))\","
        + "\"notch_entry\":\"\(env("CLAUDE_CODE_ENTRYPOINT"))\",\"notch_tty\":\"\(terminalDevice())\""
    payload.insert(contentsOf: Array(extra.utf8), at: close)
}

guard !payload.isEmpty, let home = getenv("HOME") else { exit(0) }
let path = String(cString: home) + "/Library/Application Support/ClaudeNotch/notch.sock"

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(path.utf8)
guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { exit(0) }
withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }

/// A connection to the app, or nil if it isn't running.
func connectToApp() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if connected == 0 { return fd }
    close(fd)
    return nil
}

/// Starts the app this hook lives in (…/ClaudeNotch.app/Contents/MacOS/claude-notch-hook), in the background.
func launchApp() -> Bool {
    let me = CommandLine.arguments[0]
    let suffix = "/Contents/MacOS/claude-notch-hook"
    guard me.hasSuffix(".app" + suffix) else { return false }
    let app = String(me.dropLast(suffix.count))
    var pid = pid_t()
    let args = ["/usr/bin/open", "-g", app].map { strdup($0) } + [nil]
    defer { args.forEach { free($0) } }
    return posix_spawn(&pid, "/usr/bin/open", nil, nil, args, environ) == 0
}

var app = connectToApp()
// A Claude Code session just opened and the app isn't running (quit, or never started since login):
// bring it along, then hand it this event. Only here: every other event finds it running, or it was
// quit on purpose mid-session and shouldn't come back by itself.
if app == nil, contains(payload, "\"SessionStart\""), launchApp() {
    for _ in 0..<15 where app == nil {  // up to 1.5 s, inside the 2 s alarm
        usleep(100_000)
        app = connectToApp()
    }
}
guard let fd = app else { exit(0) }  // app not running: nothing to do

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
