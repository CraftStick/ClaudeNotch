import Foundation

func oneLine(_ text: String) -> String {
    let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    return String(line.trimmingCharacters(in: .whitespaces).prefix(200))
}

/// Lines added and removed going from `old` to `new`: everything between the common first and
/// last lines counts as changed. Good enough for the small replacements Edit makes.
func lineDiff(_ old: String, _ new: String) -> (added: Int, removed: Int) {
    /// A final "\n" ends the last line; it doesn't start an empty one.
    func lines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }
    let a = lines(old)
    let b = lines(new)
    var prefix = 0
    while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
        suffix += 1
    }
    return (b.count - prefix - suffix, a.count - prefix - suffix)
}

/// All lines of `text` on one line, for multi-line shell commands.
func flat(_ text: String) -> String {
    let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    return String(lines.filter { !$0.isEmpty }.joined(separator: " ⏎ ").prefix(300))
}

func formatElapsed(_ interval: TimeInterval) -> String {
    let s = max(0, Int(interval))
    if s < 60 { return tr("\(s)с", "\(s)s") }
    if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
    return String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
}

func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let n10 = n % 10, n100 = n % 100
    if n10 == 1 && n100 != 11 { return one }
    if (2...4).contains(n10) && !(12...14).contains(n100) { return few }
    return many
}

/// 950 → "950", 12_400 → "12k", 1_000_000 → "1M".
func tokens(_ n: Int) -> String {
    if n >= 1_000_000 { return n % 1_000_000 == 0 ? "\(n / 1_000_000)M" : String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 10_000 { return "\(n / 1000)k" }
    if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
    return "\(n)"
}
