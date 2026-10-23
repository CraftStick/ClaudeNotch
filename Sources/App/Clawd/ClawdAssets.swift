import AppKit

/// A pixel animation: `frames[i][y * width + x]` is a palette index, 255 = transparent.
struct PixelSheet {
    let name: String
    let width: Int
    let height: Int
    let palette: [(r: Double, g: Double, b: Double)]
    let frames: [[UInt8]]
    /// Where the feet are: the point that stays put when switching sheets.
    let anchor: CGPoint
}

/// Clawd's own animations, read at launch from the Claude desktop app installed on this Mac:
/// its "Clawd Quest" easter egg keeps them as pixel maps in a JS bundle inside app.asar.
/// None of Anthropic's artwork ships with this project; without Claude.app (or if the
/// format changes) the hand-drawn `DrawnClawdView` is used instead.
enum ClawdAssets {
    // Each with the frame count the clips below expect; a sheet that changed shape is skipped.
    static let laptop = sheet("Laptop", frames: 43)
    static let waving = sheet("Waving", frames: 17)
    static let jumping = sheet("JumpingHappy", frames: 21)
    static let lookingAround = sheet("LookingAround", frames: 31)
    static let swaying = sheet("Swaying", frames: 49)
    static let dancing = sheet("DancingHappy", frames: 39)
    static let hula = sheet("Hula", frames: 54)
    static let meditating = sheet("Meditating", frames: 60)
    static let disappointed = sheet("Disappointed", frames: 43)
    static let dizzy = sheet("Dizzy", frames: 41)
    static let lightbulb = sheet("Lightbulb", frames: 45)
    static let thinking = sheet("Thinking", frames: 37)
    static let desktop = sheet("Desktop", frames: 88)
    static let running = sheet("Running", frames: 17)
    static let walking = sheet("Walking", frames: 10)
    static let excited = sheet("Excited", frames: 22)
    static let facepalm = sheet("Facepalm", frames: 34)
    static let confetti = sheet("Confetti", frames: 34)
    static let breakDancing = sheet("BreakDancing", frames: 28)
    static let pointing = sheet("Pointing", frames: 43)
    static let turning = sheet("Turning", frames: 29)
    static let spark = sheet("Spark", frames: 73)

    private static func sheet(_ name: String, frames: Int) -> PixelSheet? {
        sheets[name].flatMap { $0.frames.count >= frames ? $0 : nil }
    }

    /// Every sheet in the bundle, by name. Read once, whichever thread asks first.
    private static let sheets: [String: PixelSheet] = {
        guard let source = engineSource() else {
            EventLog.append("Clawd sprites: Claude.app not found, using the drawn Clawd")
            return [:]
        }
        let result = parse(source)
        EventLog.append("Clawd sprites from Claude.app: " + result.map { "\($0.key) (\($0.value.frames.count))" }.sorted().joined(separator: ", "))
        return result
    }()

    // MARK: - app.asar

    private static func engineSource() -> String? {
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop")
            ?? URL(fileURLWithPath: "/Applications/Claude.app")
        guard let handle = try? FileHandle(forReadingFrom: app.appendingPathComponent("Contents/Resources/app.asar")) else { return nil }
        defer { try? handle.close() }

        // Layout: a 16-byte prefix, the JSON index, then the files' contents.
        guard let prefix = try? handle.read(upToCount: 16).map(Array.init), prefix.count == 16 else { return nil }
        func u32(_ at: Int) -> Int {
            Int(prefix[at]) | Int(prefix[at + 1]) << 8 | Int(prefix[at + 2]) << 16 | Int(prefix[at + 3]) << 24
        }
        let headerSize = u32(4), jsonLength = u32(12)
        guard jsonLength > 0, jsonLength < 64_000_000,
              let json = try? handle.read(upToCount: jsonLength),
              let index = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let entry = findEngine(in: index),
              (try? handle.seek(toOffset: UInt64(8 + headerSize + entry.offset))) != nil,
              let data = try? handle.read(upToCount: entry.size) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The bundle is named clawdQuestEngine-<hash>.js; its folder may move between versions.
    private static func findEngine(in node: [String: Any]) -> (offset: Int, size: Int)? {
        guard let files = node["files"] as? [String: Any] else { return nil }
        for (name, value) in files {
            guard let child = value as? [String: Any] else { continue }
            if child["files"] != nil {
                if let hit = findEngine(in: child) { return hit }
            } else if name.hasPrefix("clawdQuestEngine-"), name.hasSuffix(".js"),
                      let size = child["size"] as? Int,
                      let offset = (child["offset"] as? String).flatMap({ Int($0) }) ?? child["offset"] as? Int,
                      offset >= 0, size >= 0 {
                return (offset, size)
            }
        }
        return nil
    }

    // MARK: - Sprite data

    /// Every `Name:{cat:"…",w:W,h:H,fps:F,palette:["#rrggbb",…],base:"<pixels>",deltas:<frames>,a0:[x,y,w,h]…}`
    /// in the bundle, found in one pass: one search per name took ten times as long. The first sheet of
    /// a name that reads well counts.
    static func parse(_ source: String) -> [String: PixelSheet] {
        let pattern = #"[{,](\w+):\{cat:"\w+",w:(\d+),h:(\d+),fps:\d+,palette:\[([^\]]*)\],base:"([^"]*)",deltas:"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        var sheets: [String: PixelSheet] = [:]
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let sheet = readSheet(match, in: source), sheets[sheet.name] == nil else { continue }
            sheets[sheet.name] = sheet
        }
        return sheets
    }

    /// Pixels are base-36 palette indices ("." = transparent); each delta lists `<index><value>`
    /// changes from the previous frame. Deltas are either an array of strings or one string
    /// split on "(".
    private static func readSheet(_ match: NSTextCheckingResult, in source: String) -> PixelSheet? {
        guard let matchRange = Range(match.range, in: source) else { return nil }
        func group(_ i: Int) -> String { Range(match.range(at: i), in: source).map { String(source[$0]) } ?? "" }
        let name = group(1)
        guard let width = Int(group(2)), let height = Int(group(3)) else { return nil }

        let palette: [(r: Double, g: Double, b: Double)] = group(4).components(separatedBy: "\"").compactMap { hex in
            guard hex.hasPrefix("#"), hex.count == 7, let v = Int(hex.dropFirst(), radix: 16) else { return nil }
            return (Double(v >> 16 & 0xff) / 255, Double(v >> 8 & 0xff) / 255, Double(v & 0xff) / 255)
        }

        var rest = source[matchRange.upperBound...]
        let deltas: [String]
        if rest.first == "\"" {
            rest = rest.dropFirst()
            guard let close = rest.firstIndex(of: "\"") else { return nil }
            deltas = rest[..<close].components(separatedBy: "(")
            rest = rest[close...]
        } else if rest.first == "[", let close = rest.firstIndex(of: "]") {
            // ["…","…"]: the quoted parts are every other piece between quotes.
            let pieces = rest[rest.index(after: rest.startIndex)..<close].components(separatedBy: "\"")
            deltas = stride(from: 1, to: pieces.count, by: 2).map { pieces[$0] }
            rest = rest[close...]
        } else {
            return nil
        }

        var anchor = CGPoint(x: CGFloat(width) / 2, y: CGFloat(height))
        let after = String(rest.prefix(300)) as NSString
        if let a0 = try? NSRegularExpression(pattern: #"a0:\[(\d+),(\d+),(\d+),(\d+)\]"#),
           let m = a0.firstMatch(in: after as String, range: NSRange(location: 0, length: after.length)) {
            let v = (1...4).map { Int(after.substring(with: m.range(at: $0))) ?? 0 }
            if v[2] > 0 { anchor = CGPoint(x: CGFloat(v[0]) + CGFloat(v[2]) / 2, y: CGFloat(v[1] + v[3])) }
        }

        func value(_ c: Character) -> UInt8? { c == "." ? 255 : Int(String(c), radix: 36).map(UInt8.init) }
        var pixels = group(5).compactMap(value)
        guard pixels.count == width * height else { return nil }
        var frames = [pixels]
        for delta in deltas {
            for token in delta.split(separator: ",") {
                guard let last = token.last, let v = value(last),
                      let index = Int(token.dropLast(), radix: 36), pixels.indices.contains(index) else { return nil }
                pixels[index] = v
            }
            frames.append(pixels)
        }
        guard frames.allSatisfy({ $0.allSatisfy { $0 == 255 || Int($0) < palette.count } }) else { return nil }
        return PixelSheet(name: name, width: width, height: height, palette: palette, frames: frames, anchor: anchor)
    }
}
