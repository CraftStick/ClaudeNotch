import Foundation

/// Tails the transcripts of busy sessions to notice an Esc interrupt: Claude Code sends
/// no hook event for it, it only appends a "[Request interrupted by user]" message.
final class TranscriptWatcher {
    var onInterrupt: (String) -> Void = { _ in }
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

    private static let marker = Data("[Request interrupted by user".utf8)

    func watch(sessionID: String, path: String) {
        if watches[sessionID]?.path == path { return }
        stop(sessionID: sessionID)

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let watch = Watch(path: path, offset: UInt64(max(0, lseek(fd, 0, SEEK_END))))
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
            let line = buffer[buffer.startIndex..<newline]
            buffer = buffer[(newline + 1)...]
            if line.range(of: Self.marker) != nil, Self.isInterrupt(Data(line)) {
                onInterrupt(sessionID)
                return
            }
        }
        watch.partialLine = Data(buffer)
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
