import Foundation
import Testing
@testable import ClaudeNotch

struct TranscriptTests {
    private static func file(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notch-\(UUID().uuidString).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    private static let prompt = #"{"type":"user","sessionId":"abc","cwd":"/tmp/p","entrypoint":"cli","timestamp":"2026-10-20T10:00:00.000Z","message":{"role":"user","content":"Fix the build"}}"#
    private static let toolCall = #"{"type":"assistant","sessionId":"abc","cwd":"/tmp/p","entrypoint":"cli","message":{"id":"m1","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash","input":{"command":"make"}}],"usage":{"input_tokens":10,"cache_read_input_tokens":1000,"output_tokens":5}}}"#
    private static let answer = #"{"type":"assistant","sessionId":"abc","cwd":"/tmp/p","message":{"id":"m2","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}],"usage":{"input_tokens":1,"output_tokens":2}}}"#
    private static let interrupt = #"{"type":"user","sessionId":"abc","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#

    @Test func theLastLineOfAReplyIsItsLastSentence() {
        #expect(TranscriptWatcher.lastLine("Done.\n\n```\ncode?\n```\n**Should I commit?**") == "Should I commit?")
        #expect(TranscriptWatcher.lastLine("Steps:\n- one\n- two") == "two")
        #expect(TranscriptWatcher.lastLine("Intro\n| a | b |\n|---|---|") == "Intro")
        #expect(TranscriptWatcher.lastLine("```\nonly code\n```") == nil)
    }

    @Test func aSessionMidToolIsRunning() throws {
        let url = try Self.file([Self.prompt, Self.toolCall])
        defer { try? FileManager.default.removeItem(at: url) }
        let running = try #require(TranscriptWatcher.runningSession(url))
        #expect(running.id == "abc")
        #expect(running.cwd == "/tmp/p")
        #expect(running.entrypoint == "cli")
        #expect(running.task == "Fix the build")
        #expect(running.tool?.name == "Bash")
        #expect(running.started != nil)
    }

    @Test func aFinishedOrStoppedSessionIsNot() throws {
        for lines in [[Self.prompt, Self.toolCall, Self.answer], [Self.prompt, Self.interrupt]] {
            let url = try Self.file(lines)
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(TranscriptWatcher.runningSession(url) == nil)
        }
    }

    @Test func theLastReplyIsFoundAtTheEnd() throws {
        let url = try Self.file([Self.prompt, Self.toolCall, Self.answer])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(TranscriptWatcher.lastReply(path: url.path) == "Done.")
    }

    /// Watching starts with the context size there is, and Esc shows up as an interrupt. The file is read
    /// on the watcher's own queue; what it finds comes on the main thread.
    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func aWatchedTranscriptReportsUsageAndEsc() async throws {
        let url = try Self.file([Self.prompt, Self.toolCall])
        defer { try? FileManager.default.removeItem(at: url) }
        let watcher = TranscriptWatcher()
        var usage: TranscriptUsage?
        var stopped: String?
        watcher.onUsage = { _, found in usage = found }
        watcher.onInterrupt = { id in
            #expect(Thread.isMainThread)
            stopped = id
        }
        watcher.watch(sessionID: "s1", path: url.path)
        // Appended until the watcher, which starts on its own queue, sees it.
        for _ in 0..<50 where stopped == nil {
            try await Task.sleep(nanoseconds: 200_000_000)
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            handle.write(Data((Self.interrupt + "\n").utf8))
            try handle.close()
        }
        watcher.stop(sessionID: "s1")
        #expect(stopped == "s1")
        #expect(usage?.initial == true)
        #expect(usage?.context == 1015)
        #expect(usage?.messageID == "m1")
    }
}
