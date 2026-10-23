import Foundation

/// Token counts from one assistant message in a transcript.
struct TranscriptUsage {
    let messageID: String
    /// Tokens in the context after this message (input, cached and output).
    let context: Int
    let output: Int
    /// Read from the end of the file when watching starts, not written during this turn.
    let initial: Bool
}

/// Tails the transcripts of busy sessions. Claude Code sends no hook event for an Esc interrupt,
/// it only appends a "[Request interrupted by user]" message; and hooks carry neither token usage
/// nor what Claude thinks and says between tools, but the assistant messages in the transcript do.
///
/// The files are read on a queue of their own and the callbacks come on the main thread: one line can
/// carry megabytes of tool output, too much to read and search through on the main thread.
final class TranscriptWatcher {
    var onInterrupt: (String) -> Void = { _ in }
    var onUsage: (String, TranscriptUsage) -> Void = { _, _ in }
    /// The gist of a thinking block or a message Claude just wrote, and when it was written.
    var onThought: (String, String, Date) -> Void = { _, _, _ in }
    /// Anything at all was written: the session is alive.
    var onWrite: (String) -> Void = { _ in }
    private let queue = DispatchQueue(label: "ClaudeNotch.transcripts", qos: .utility)
    /// Only touched on `queue`.
    private var watches: [String: Watch] = [:]

    private final class Watch {
        let path: String
        var source: DispatchSourceFileSystemObject?
        var offset: UInt64
        var partialLine = Data()

        init(path: String, offset: UInt64) {
            self.path = path
            self.offset = offset
        }
    }

    private static let interruptMarker = Data("[Request interrupted by user".utf8)
    private static let usageMarker = Data("\"usage\"".utf8)

    func watch(sessionID: String, path: String) {
        queue.async { [weak self] in self?.start(sessionID, path: path) }
    }

    func stop(sessionID: String) {
        queue.async { [weak self] in self?.cancel(sessionID) }
    }

    private func start(_ sessionID: String, path: String) {
        if watches[sessionID]?.path == path { return }
        cancel(sessionID)

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let end = UInt64(max(0, lseek(fd, 0, SEEK_END)))
        let watch = Watch(path: path, offset: end)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.extend, .write, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self, weak watch, weak source] in
            guard let self, let watch, let source else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                self.cancel(sessionID)
            } else {
                self.readAppended(watch, sessionID: sessionID)
            }
        }
        source.setCancelHandler { close(fd) }
        watch.source = source
        watches[sessionID] = watch
        source.resume()

        if let usage = Self.lastUsage(path: path, end: end) {
            onMain { $0.onUsage(sessionID, usage) }
        }
    }

    private func cancel(_ sessionID: String) {
        watches.removeValue(forKey: sessionID)?.source?.cancel()
    }

    private func onMain(_ call: @escaping (TranscriptWatcher) -> Void) {
        DispatchQueue.main.async { [weak self] in
            if let self { call(self) }
        }
    }

    private func readAppended(_ watch: Watch, sessionID: String) {
        guard let handle = FileHandle(forReadingAtPath: watch.path) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: watch.offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return }
        watch.offset += UInt64(data.count)
        onMain { $0.onWrite(sessionID) }

        var buffer = watch.partialLine + data
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer = buffer[(newline + 1)...]
            if line.range(of: Self.interruptMarker) != nil, Self.isInterrupt(line) {
                // On to the lines after it: returning here kept a half line already read as the start of the next.
                onMain { $0.onInterrupt(sessionID) }
                continue
            }
            if line.range(of: Self.usageMarker) != nil, let (message, written) = Self.assistantMessage(line) {
                if let usage = Self.usage(in: message, initial: false) { onMain { $0.onUsage(sessionID, usage) } }
                if let thought = Self.thought(in: message) {
                    let written = written ?? Date()
                    onMain { $0.onThought(sessionID, thought, written) }
                }
            }
        }
        watch.partialLine = Data(buffer)
    }

    /// The last usage in the final 512 KB of the transcript, for the context size right away.
    private static func lastUsage(path: String, end: UInt64) -> TranscriptUsage? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let start = end > 512_000 ? end - 512_000 : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: Int(end - start)) else { return nil }
        var lines = data.split(separator: UInt8(ascii: "\n"))
        if start > 0, !lines.isEmpty { lines.removeFirst() }  // probably cut in half
        for line in lines.reversed() where line.range(of: usageMarker) != nil {
            if let (message, _) = assistantMessage(Data(line)), let usage = usage(in: message, initial: true) { return usage }
        }
        return nil
    }

    private static let timestamps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// The main agent's message in `{"type":"assistant","isSidechain":false,"timestamp":…,"message":{…}}`.
    private static func assistantMessage(_ line: Data) -> ([String: Any], Date?)? {
        guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              entry["type"] as? String == "assistant",
              entry["isSidechain"] as? Bool != true,
              let message = entry["message"] as? [String: Any] else { return nil }
        return (message, (entry["timestamp"] as? String).flatMap(timestamps.date(from:)))
    }

    /// `{"id":…,"usage":{"input_tokens":…,"cache_creation_input_tokens":…,"cache_read_input_tokens":…,"output_tokens":…}}`
    private static func usage(in message: [String: Any], initial: Bool) -> TranscriptUsage? {
        guard let usage = message["usage"] as? [String: Any] else { return nil }
        func n(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        let output = n("output_tokens")
        let context = n("input_tokens") + n("cache_creation_input_tokens") + n("cache_read_input_tokens") + output
        guard context > 0 else { return nil }
        return TranscriptUsage(messageID: message["id"] as? String ?? "", context: context, output: output, initial: initial)
    }

    /// `"content":[{"type":"thinking","thinking":…}]` or `[{"type":"text","text":…}]`, one block per
    /// line as Claude Code writes them. A thinking block is often empty: only some models show it.
    private static func thought(in message: [String: Any]) -> String? {
        let blocks = message["content"] as? [[String: Any]] ?? []
        for block in blocks.reversed() {
            let text: String?
            switch block["type"] as? String {
            case "thinking": text = block["thinking"] as? String
            case "text": text = block["text"] as? String
            default: text = nil
            }
            if let text, let gist = gist(text) { return gist }
        }
        return nil
    }

    /// The first line with words in it, without Markdown marks: a thinking block often starts with
    /// a bold title ("**Planning the fix**"), a message with what Claude is about to do.
    private static func gist(_ text: String) -> String? {
        firstPlainLine(text.split(whereSeparator: \.isNewline))
    }

    /// The last line with words in it, without Markdown marks: how a reply ends, often a question.
    static func lastLine(_ text: String) -> String? {
        firstPlainLine(text.split(whereSeparator: \.isNewline).reversed())
    }

    /// The first of `lines` that is text, skipping code blocks and tables, with Markdown marks removed.
    private static func firstPlainLine<Lines: Sequence>(_ lines: Lines) -> String? where Lines.Element == Substring {
        var inCode = false
        for raw in lines {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inCode.toggle() }
            if inCode || line.hasPrefix("```") || line.hasPrefix("|") { continue }  // code, tables
            for mark in ["**", "__", "`"] { line = line.replacingOccurrences(of: mark, with: "") }
            line = String(line.drop { "#>-*• ".contains($0) })
            if line.contains(where: \.isLetter) { return String(line.prefix(200)) }
        }
        return nil
    }

    // MARK: - The last reply

    /// The text of Claude's last message in the transcript: for when a turn ends.
    static func lastReply(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let start = end > 256_000 ? end - 256_000 : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() where line.range(of: usageMarker) != nil {
            guard let (message, _) = assistantMessage(Data(line)) else { continue }
            let texts = (message["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            if let text = texts.last, !text.isEmpty { return text }
        }
        return nil
    }

    /// Only a user text message counts: the marker can also appear inside tool input or output.
    private static func isInterrupt(_ line: Data) -> Bool {
        guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              entry["type"] as? String == "user",
              let message = entry["message"] as? [String: Any] else { return false }
        if let text = message["content"] as? String {
            return text.hasPrefix("[Request interrupted by user")
        }
        let parts = message["content"] as? [[String: Any]] ?? []
        return parts.contains {
            $0["type"] as? String == "text" && ($0["text"] as? String ?? "").hasPrefix("[Request interrupted by user")
        }
    }

    // MARK: - Sessions already running

    /// A session whose transcript says Claude is in the middle of a turn.
    struct Running {
        let id: String
        let path: String
        let cwd: String
        /// Like CLAUDE_CODE_ENTRYPOINT: "cli" in a terminal, "claude-desktop" in the Claude app…
        let entrypoint: String
        /// The message that started the turn, and when.
        let task: String
        let started: Date?
        /// The tool it's running, if it's waiting on one.
        let tool: (name: String, input: [String: Any])?
    }

    /// Sessions Claude is at work in, for an app started after Claude got going: hooks only tell about
    /// what happens next. Looks at transcripts written to in the last `within` seconds whose last
    /// message isn't a finished answer.
    static func running(within: TimeInterval = 600) -> [Running] {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var found: [Running] = []
        for project in projects {
            let files = (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: keys)) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let modified = try? file.resourceValues(forKeys: Set(keys)).contentModificationDate,
                      Date().timeIntervalSince(modified) < within,
                      let session = runningSession(file) else { continue }
                found.append(session)
            }
        }
        return found
    }

    static func runningSession(_ file: URL) -> Running? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let start = end > 512_000 ? end - 512_000 : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        var lines = data.split(separator: UInt8(ascii: "\n"))
        if start > 0, !lines.isEmpty { lines.removeFirst() }  // probably cut in half

        // From the end: the last message decides whether Claude is still at it, the last prompt is the task.
        var last: [String: Any]?
        var prompt: [String: Any]?
        for line in lines.reversed() {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = entry["type"] as? String, type == "user" || type == "assistant",
                  entry["isSidechain"] as? Bool != true, entry["isMeta"] as? Bool != true else { continue }
            if last == nil { last = entry }
            if type == "user", promptText(entry) != nil { prompt = entry; break }
        }
        guard let last, let message = last["message"] as? [String: Any] else { return nil }
        var tool: (name: String, input: [String: Any])?
        if last["type"] as? String == "assistant" {
            let stop = message["stop_reason"] as? String
            guard stop == nil || stop == "tool_use" else { return nil }  // a finished answer
            let blocks = message["content"] as? [[String: Any]] ?? []
            if let call = blocks.last(where: { $0["type"] as? String == "tool_use" }), let name = call["name"] as? String {
                tool = (name, call["input"] as? [String: Any] ?? [:])
            }
        } else if let text = promptText(last), text.hasPrefix("[Request interrupted by user") {
            return nil  // stopped with Esc
        }
        let id = file.deletingPathExtension().lastPathComponent
        return Running(id: last["sessionId"] as? String ?? id, path: file.path, cwd: last["cwd"] as? String ?? "",
                       entrypoint: last["entrypoint"] as? String ?? "",
                       task: prompt.flatMap(promptText) ?? "",
                       started: (prompt?["timestamp"] as? String).flatMap(timestamps.date(from:)),
                       tool: tool)
    }

    /// The text of a message you typed: a string, or text blocks (not tool results).
    private static func promptText(_ entry: [String: Any]) -> String? {
        guard let message = entry["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text }
        let parts = message["content"] as? [[String: Any]] ?? []
        guard !parts.contains(where: { $0["type"] as? String == "tool_result" }) else { return nil }
        let text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }
}
