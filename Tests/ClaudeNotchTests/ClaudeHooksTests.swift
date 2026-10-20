import Foundation
import Testing
@testable import ClaudeNotch

/// The hooks the app writes into a settings file of its own, in a folder of its own.
struct ClaudeHooksTests {
    private let folder: URL
    private let settings: URL
    private let hook = "/Applications/Claude Notch.app/Contents/MacOS/claude-notch-hook"
    private static let original = """
        {"model": "opus", "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/other/hook"}]}]}}
        """

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("notch-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        settings = folder.appendingPathComponent("settings.json")
        try Data(Self.original.utf8).write(to: settings)
    }

    private func read() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
    }

    private func commands(_ event: String) throws -> [String] {
        let groups = try read()["hooks"].flatMap { ($0 as? [String: Any])?[event] as? [[String: Any]] } ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    @Test func connectsAndDisconnectsLeavingTheRestAlone() throws {
        #expect(ClaudeHooks.state(settings: settings, hook: hook) == .missing)

        try ClaudeHooks.connect(settings: settings, hook: hook)
        #expect(ClaudeHooks.state(settings: settings, hook: hook) == .connected)
        #expect(try read()["model"] as? String == "opus")
        // A path with a space is quoted: Claude Code runs the command through a shell.
        #expect(try commands("PreToolUse") == ["/other/hook", "\"\(hook)\""])
        for event in ClaudeHooks.events.keys {
            #expect(try commands(event).filter { $0.contains("claude-notch-hook") }.count == 1, "\(event)")
        }

        // Again: nothing twice.
        try ClaudeHooks.connect(settings: settings, hook: hook)
        #expect(try commands("Stop").count == 1)

        // The original is saved once, before the first change.
        let backup = try String(contentsOf: URL(fileURLWithPath: settings.path + ".bak-claudenotch"), encoding: .utf8)
        #expect(backup == Self.original)

        try ClaudeHooks.disconnect(settings: settings)
        #expect(ClaudeHooks.state(settings: settings, hook: hook) == .missing)
        #expect(try commands("PreToolUse") == ["/other/hook"])
        #expect(try commands("Stop").isEmpty)
        #expect(try read()["model"] as? String == "opus")
    }

    @Test func anotherCopyOfTheAppIsOutdated() throws {
        try ClaudeHooks.connect(settings: settings, hook: "/Old/ClaudeNotch.app/Contents/MacOS/claude-notch-hook")
        #expect(ClaudeHooks.state(settings: settings, hook: hook) == .outdated)
        try ClaudeHooks.connect(settings: settings, hook: hook)
        #expect(ClaudeHooks.state(settings: settings, hook: hook) == .connected)
    }

    @Test func timeoutsAndMatchersAreSet() throws {
        try ClaudeHooks.connect(settings: settings, hook: hook)
        let hooks = try #require(read()["hooks"] as? [String: [[String: Any]]])
        let permission = try #require(hooks["PermissionRequest"]?.first)
        #expect(permission["matcher"] as? String == "*")
        #expect((permission["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int == 600)
        #expect(hooks["Stop"]?.first?["matcher"] == nil)
    }

    @Test func aBrokenFileIsLeftAlone() throws {
        try Data("{ not json".utf8).write(to: settings)
        #expect(throws: ClaudeHooks.Failure.self) { try ClaudeHooks.connect(settings: settings, hook: hook) }
        #expect(try String(contentsOf: settings, encoding: .utf8) == "{ not json")
    }

    @Test func aSymlinkStaysASymlink() throws {
        let link = folder.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: settings)
        try ClaudeHooks.connect(settings: link, hook: hook)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == settings.path)
        #expect(ClaudeHooks.state(settings: settings, hook: hook) == .connected)
    }

    /// install-hooks.sh writes the same hooks for an install from source.
    @Test func theInstallScriptHasTheSameHooks() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("install-hooks.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"^\s*"(\w+)": \((None|"\*"), (\d+)\),"#, options: .anchorsMatchLines)
        var events: [String: String] = [:]
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let group = { (i: Int) in (text as NSString).substring(with: match.range(at: i)) }
            events[group(1)] = (group(2) == "None" ? "-" : "*") + group(3)
        }
        let ours = ClaudeHooks.events.mapValues { ($0.matcher == nil ? "-" : "*") + String($0.timeout) }
        #expect(events == ours)
    }
}
