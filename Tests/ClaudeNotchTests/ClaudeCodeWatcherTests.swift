import Foundation
import Testing
@testable import ClaudeNotch

/// Claude Code's sessions as real processes that come and go, in a list of their own.
@MainActor
struct ClaudeCodeWatcherTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notch-sessions-\(UUID())").path

    init() throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    /// A session: a process that waits, and its file in the list, as Claude Code writes it.
    private func session(_ id: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        let pid = Int(process.processIdentifier)
        let json: [String: Any] = ["pid": pid, "sessionId": id, "status": "idle", "startedAt": Date().timeIntervalSince1970 * 1000]
        try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: "\(dir)/\(pid).json"))
        return process
    }

    private func wait(until running: Bool, _ watcher: ClaudeCodeWatcher) async throws {
        for _ in 0..<80 where watcher.running != running { try await Task.sleep(for: .milliseconds(100)) }
    }

    @Test func theLastSessionQuittingIsNoticedAndSoIsTheNext() async throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let first = try session("a")
        let watcher = ClaudeCodeWatcher(dir: dir)
        var changes: [Bool] = []
        watcher.onChange = { changes.append($0) }
        watcher.start()
        #expect(watcher.running)

        first.terminate()  // killed: its file stays behind
        try await wait(until: false, watcher)
        #expect(changes == [false])

        let second = try session("b")
        defer { second.terminate() }
        try await wait(until: true, watcher)
        #expect(changes == [false, true])
    }

    @Test func withoutAListItCantTell() {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let empty = ClaudeCodeWatcher(dir: dir)
        empty.start()
        #expect(!empty.running)
        let none = ClaudeCodeWatcher(dir: dir + "/none")
        none.start()
        #expect(none.running)  // stays in sight, as it always did
    }
}
