import Testing
@testable import ClaudeNotch

struct TextTests {
    @Test func lineDiffCountsWhatChangedBetweenTheCommonEnds() {
        func diff(_ old: String, _ new: String) -> [Int] {
            let d = lineDiff(old, new)
            return [d.added, d.removed]
        }
        #expect(diff("a\nb\nc\n", "a\nB\nc\n") == [1, 1])
        #expect(diff("", "x\ny\n") == [2, 0])
        #expect(diff("a\nb", "a\nb") == [0, 0])
        #expect(diff("a\nb\nc", "a\nc") == [0, 1])
        #expect(diff("x", "") == [0, 1])
        #expect(diff("a\n", "a\nb\n") == [1, 0])
    }

    @Test func oneLineTakesTheFirstLineTrimmedAndShort() {
        #expect(oneLine("  first  \nsecond") == "first")
        #expect(oneLine("") == "")
        #expect(oneLine(String(repeating: "x", count: 500)).count == 200)
    }

    @Test func flatPutsACommandOnOneLine() {
        #expect(flat("cd x\n\n   make  \n") == "cd x ⏎ make")
        #expect(flat(String(repeating: "y", count: 400)).count == 300)
    }

    @Test func pluralFollowsRussianRules() {
        let forms = [1: "a", 2: "b", 4: "b", 5: "c", 11: "c", 12: "c", 14: "c", 21: "a", 22: "b", 25: "c", 101: "a", 111: "c", 112: "c"]
        for (n, form) in forms {
            #expect(plural(n, "a", "b", "c") == form, "n = \(n)")
        }
    }

    @Test func tokensAreShort() {
        #expect(tokens(950) == "950")
        #expect(tokens(1234) == "1.2k")
        #expect(tokens(12_400) == "12k")
        #expect(tokens(1_000_000) == "1M")
        #expect(tokens(1_500_000) == "1.5M")
    }

    @Test func elapsedTimeReadsLikeAClock() {
        #expect(formatElapsed(5) == tr("5с", "5s"))
        #expect(formatElapsed(-3) == tr("0с", "0s"))
        #expect(formatElapsed(65) == "1:05")
        #expect(formatElapsed(3725) == "1:02:05")
    }

    @Test func actionsAreCounted() {
        #expect(actionsText(1) == tr("1 действие", "1 action"))
        #expect(actionsText(3) == tr("3 действия", "3 actions"))
        #expect(actionsText(5) == tr("5 действий", "5 actions"))
    }

    @Test func appsAreKnownByBundleIDOrTerminal() {
        #expect(AppFocus.host(bundleID: "com.example.editor", termProgram: "iTerm.app") == "com.example.editor")
        #expect(AppFocus.host(bundleID: "", termProgram: "iTerm.app") == "com.googlecode.iterm2")
        #expect(AppFocus.host(bundleID: "", termProgram: "Apple_Terminal") == "com.apple.Terminal")
        #expect(AppFocus.host(bundleID: "", termProgram: "something") == nil)
    }
}
