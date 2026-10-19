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
/// it only appends a "[Request interrupted by user]" message; and hooks don't carry token usage,
/// but every assistant message in the transcript does.
final class TranscriptWatcher {
    var onInterrupt: (String) -> Void = { _ in }
    var onUsage: (String, TranscriptUsage) -> Void = { _, _ in }
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
        if watches[sessionID]?.path == path { return }
        stop(sessionID: sessionID)

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let end = UInt64(max(0, lseek(fd, 0, SEEK_END)))
        let watch = Watch(path: path, offset: end)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.extend, .write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self, weak watch, weak source] in
            guard let self, let watch, let source else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                self.stop(sessionID: sessionID)
            } else {
                self.readAppended(watch, sessionID: sessionID)
            }
        }
        source.setCancelHandler { close(fd) }
        watch.source = source
        watches[sessionID] = watch
        source.resume()

        if let usage = Self.lastUsage(path: path, end: end) {
            onUsage(sessionID, usage)
        }
    }

    func stop(sessionID: String) {
        watches.removeValue(forKey: sessionID)?.source?.cancel()
    }

    private func readAppended(_ watch: Watch, sessionID: String) {
        guard let handle = FileHandle(forReadingAtPath: watch.path) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: watch.offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return }
        watch.offset += UInt64(data.count)

        var buffer = watch.partialLine + data
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer = buffer[(newline + 1)...]
            if line.range(of: Self.interruptMarker) != nil, Self.isInterrupt(line) {
                onInterrupt(sessionID)
                return
            }
            if line.range(of: Self.usageMarker) != nil, let usage = Self.usage(in: line, initial: false) {
                onUsage(sessionID, usage)
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
            if let usage = usage(in: Data(line), initial: true) { return usage }
        }
        return nil
    }

    /// `{"type":"assistant","isSidechain":false,"message":{"id":…,"usage":{"input_tokens":…,
    /// "cache_creation_input_tokens":…,"cache_read_input_tokens":…,"output_tokens":…}}}`
    private static func usage(in line: Data, initial: Bool) -> TranscriptUsage? {
        guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              entry["type"] as? String == "assistant",
              entry["isSidechain"] as? Bool != true,
              let message = entry["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return nil }
        func n(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        let output = n("output_tokens")
        let context = n("input_tokens") + n("cache_creation_input_tokens") + n("cache_read_input_tokens") + output
        guard context > 0 else { return nil }
        return TranscriptUsage(messageID: message["id"] as? String ?? "", context: context, output: output, initial: initial)
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
}
