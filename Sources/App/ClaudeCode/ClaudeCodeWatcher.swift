import Foundation

/// Whether Claude Code runs on the Mac, in a terminal, an editor or the Claude app: any process in its
/// list of sessions (`SessionRegistry`). Nothing is polled: the list's folder is watched for sessions
/// that come and go, and each process for its exit. When the last one quits the app goes out of sight,
/// menu bar icon and all, until the next one starts.
final class ClaudeCodeWatcher {
    /// True too while it can't be told: there's no list (Claude Code has never run, or is from before it
    /// kept one), and the app stays in sight as it always did.
    private(set) var running = true
    var onChange: (Bool) -> Void = { _ in }
    private let dir: String
    private var folder: DispatchSourceFileSystemObject?
    private var exits: [pid_t: DispatchSourceProcess] = [:]
    private var lookWork: DispatchWorkItem?
    /// When the last one was first found gone.
    private var lastGone: Date?
    /// A session the Claude app restarts is gone for a moment: the app goes only once none has run for this long.
    private static let grace: TimeInterval = 2

    init(dir: String = SessionRegistry.dir) {
        self.dir = dir
    }

    func start() {
        watchFolder()
        running = look()
        EventLog.append(running ? "Claude Code is running" : "Claude Code isn't running")
    }

    /// A hook event came in. Most often nothing to do; Claude Code starting before its list has a folder
    /// to watch, or before the folder told of it, is found now.
    func seen() {
        if folder == nil || !running { lookSoon() }
    }

    private func watchFolder() {
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {  // the folder itself went
                source.cancel()
                self.folder = nil
            }
            self.lookSoon()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        folder = source
    }

    /// Sessions come and go in bursts (a file and its key, one quitting as another starts): one look after
    /// them, a moment later.
    private func lookSoon(after delay: TimeInterval = 0.5) {
        lookWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.lookAgain() }
        lookWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func lookAgain() {
        lookWork = nil
        if folder == nil { watchFolder() }
        let now = look()
        if now { lastGone = nil }
        guard now != running else { return }
        if !now {
            let since = lastGone ?? Date()
            lastGone = since
            let left = Self.grace - Date().timeIntervalSince(since)
            guard left <= 0 else { return lookSoon(after: left) }
        }
        running = now
        EventLog.append(now ? "Claude Code is running" : "Claude Code quit")
        onChange(now)
    }

    /// Whether any session's process runs; each that does is watched for its exit.
    private func look() -> Bool {
        guard let pids = SessionRegistry.running(in: dir) else { return true }
        for pid in pids where exits[pid] == nil {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in
                self?.exits.removeValue(forKey: pid)?.cancel()
                self?.lookSoon()
            }
            source.resume()
            exits[pid] = source
        }
        for (pid, source) in exits where !pids.contains(pid) {
            source.cancel()
            exits[pid] = nil
        }
        return !pids.isEmpty
    }
}
