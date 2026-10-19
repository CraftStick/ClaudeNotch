import AppKit
import SwiftUI

/// A pixel animation: `frames[i][y * width + x]` is a palette index, 255 = transparent.
struct PixelSheet {
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

    private static let names = ["Laptop", "Waving", "JumpingHappy", "LookingAround", "Swaying", "DancingHappy",
                                "Hula", "Meditating", "Disappointed", "Dizzy", "Lightbulb", "Thinking", "Desktop",
                                "Running", "Walking", "Excited", "Facepalm", "Confetti", "BreakDancing"]

    private static func sheet(_ name: String, frames: Int) -> PixelSheet? {
        sheets[name].flatMap { $0.frames.count >= frames ? $0 : nil }
    }

    private static let sheets: [String: PixelSheet] = {
        guard let source = engineSource() else {
            EventLog.append("Clawd sprites: Claude.app not found, using the drawn Clawd")
            return [:]
        }
        var result: [String: PixelSheet] = [:]
        for name in names {
            result[name] = parse(name, in: source)
        }
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
                      let offset = (child["offset"] as? String).flatMap({ Int($0) }) ?? child["offset"] as? Int {
                return (offset, size)
            }
        }
        return nil
    }

    // MARK: - Sprite data

    /// `Name:{cat:"…",w:W,h:H,fps:F,palette:["#rrggbb",…],base:"<pixels>",deltas:<frames>,a0:[x,y,w,h]…}`
    /// Pixels are base-36 palette indices ("." = transparent); each delta lists `<index><value>`
    /// changes from the previous frame. Deltas are either an array of strings or one string
    /// split on "(".
    private static func parse(_ name: String, in source: String) -> PixelSheet? {
        let pattern = "[{,]" + name + #":\{cat:"\w+",w:(\d+),h:(\d+),fps:\d+,palette:\[([^\]]*)\],base:"([^"]*)",deltas:"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let matchRange = Range(match.range, in: source) else { return nil }
        func group(_ i: Int) -> String { Range(match.range(at: i), in: source).map { String(source[$0]) } ?? "" }
        guard let width = Int(group(1)), let height = Int(group(2)) else { return nil }

        let palette: [(r: Double, g: Double, b: Double)] = group(3).components(separatedBy: "\"").compactMap { hex in
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
        if let a0 = try? NSRegularExpression(pattern: #"a0:\[(\d+),(\d+),(\d+),(\d+)\]"#),
           let m = a0.firstMatch(in: String(rest.prefix(300)), range: NSRange(location: 0, length: min(300, rest.utf16.count))) {
            let text = String(rest.prefix(300)) as NSString
            let v = (1...4).map { Int(text.substring(with: m.range(at: $0))) ?? 0 }
            if v[2] > 0 { anchor = CGPoint(x: CGFloat(v[0]) + CGFloat(v[2]) / 2, y: CGFloat(v[1] + v[3])) }
        }

        func value(_ c: Character) -> UInt8? { c == "." ? 255 : Int(String(c), radix: 36).map(UInt8.init) }
        var pixels = group(4).compactMap(value)
        guard pixels.count == width * height else { return nil }
        var frames = [pixels]
        for delta in deltas {
            for token in delta.split(separator: ",") {
                guard let last = token.last, let v = value(last),
                      let index = Int(token.dropLast(), radix: 36), index < pixels.count else { return nil }
                pixels[index] = v
            }
            frames.append(pixels)
        }
        guard frames.allSatisfy({ $0.allSatisfy { $0 == 255 || Int($0) < palette.count } }) else { return nil }
        return PixelSheet(width: width, height: height, palette: palette, frames: frames, anchor: anchor)
    }
}

/// Frames `frames` of `sheet`, played at `fps`.
private struct Clip {
    let sheet: PixelSheet
    let frames: ClosedRange<Int>
    let fps: Double

    var duration: TimeInterval { Double(frames.count) / fps }

    /// Played once: holds the last frame afterwards.
    func frame(at t: TimeInterval) -> Int { frames.lowerBound + min(frames.count - 1, Int(t * fps)) }

    func looped(at t: TimeInterval) -> Int { frames.lowerBound + Int(t * fps) % frames.count }
}

/// Clawd in the notch. With the Claude app's sprites he turns to a laptop and types while Claude
/// works, puts it away and waves while Claude waits for you. After a turn he reacts (a happy hop,
/// a sigh after Esc, dizzy after an error), then idles with the odd fidget and dozes off.
struct ClawdView: View {
    let session: Session

    var body: some View {
        if let laptop = ClawdAssets.laptop, let waving = ClawdAssets.waving {
            SheetClawdView(session: session, laptop: laptop, waving: waving)
        } else {
            DrawnClawdView(phase: session.phase)
        }
    }
}


private struct SheetClawdView: View {
    let session: Session
    let laptop: PixelSheet
    let waving: PixelSheet

    /// Room for the laptop or desk on the left (sheets are mirrored) and for a light bulb or a
    /// happy hop above the head.
    private static let size = CGSize(width: 36, height: 32)
    private static let feet = CGPoint(x: 24, y: 31)
    /// Idle this long after a turn and Clawd sits down and dozes off.
    private static let sleepAfter: TimeInterval = 3 * 60
    /// At the end of the rest Clawd walks off out of the notch, for this long.
    private static let walkOff: TimeInterval = 4.5

    /// One frame to draw; `dozing` is the time asleep (for the floating "z"s), `offsetX` moves
    /// Clawd while he walks off.
    private struct Frame {
        let sheet: PixelSheet
        let index: Int
        var dozing: TimeInterval?
        var offsetX: CGFloat = 0

        init(_ sheet: PixelSheet, _ index: Int, dozing: TimeInterval? = nil, offsetX: CGFloat = 0) {
            self.sheet = sheet
            self.index = index
            self.dozing = dozing
            self.offsetX = offsetX
        }

        init(_ clip: Clip, at t: TimeInterval) { self.init(clip.sheet, clip.frame(at: t)) }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 16)) { context in
            let frame = frame(at: context.date)
            Canvas { ctx, _ in draw(frame, in: ctx) }
                .frame(width: Self.size.width, height: Self.size.height)
                .offset(x: frame.offsetX)
        }
    }

    // Laptop: 0–3 standing, 2–16 turn and open the laptop, 17–33 typing loop, 34–42 close it.
    private var openLaptop: Clip { Clip(sheet: laptop, frames: 2...16, fps: 12) }
    private var typingLoop: Clip { Clip(sheet: laptop, frames: 17...33, fps: 12) }
    private var closeLaptop: Clip { Clip(sheet: laptop, frames: 34...42, fps: 16) }
    private var standing: Frame { Frame(laptop, 0) }

    private func frame(at date: Date) -> Frame {
        let sinceMotion = date.timeIntervalSince(session.motionStart)
        if let cue = session.cue {
            let lead = exit(from: session.cueInterrupted)  // put the laptop away first
            let clips = [lead].compactMap { $0 } + reaction(cue)
            var t = date.timeIntervalSince(session.cueStart)
            let total = clips.reduce(0) { $0 + $1.duration }
            if t < total {
                for clip in clips {
                    if t < clip.duration { return Frame(clip, at: t) }
                    t -= clip.duration
                }
            }
            let cueEnd = session.cueStart.addingTimeInterval(total)
            if cueEnd > session.motionStart {
                // The reaction took over the start of what Clawd does now: carry on from its end
                // with empty hands (nothing to put away, no hop after confetti).
                return motionFrame(after: nil, t: date.timeIntervalSince(cueEnd), sinceMotion: sinceMotion)
            }
        }
        return motionFrame(after: session.previousMotion, t: sinceMotion, sinceMotion: sinceMotion)
    }

    /// `previous`: what Clawd did before (nil = nothing in hand); `t`: time into this motion.
    private func motionFrame(after previous: Motion?, t: TimeInterval, sinceMotion: TimeInterval) -> Frame {
        let motion = session.motion
        var t = max(0, t)
        if let previous, previous != motion, let exit = exit(from: previous) {
            if t < exit.duration { return Frame(exit, at: t) }
            t -= exit.duration
        }
        switch motion {
        case .typing:
            if previous != .typing {
                if t < openLaptop.duration { return Frame(openLaptop, at: t) }
                t -= openLaptop.duration
            }
            return Frame(laptop, typingLoop.looped(at: t))
        case .pondering:
            guard let sheet = ClawdAssets.thinking else { return Frame(laptop, typingLoop.looped(at: t)) }
            // A speech bubble pops up, he sits down, and dots keep coming in the bubble.
            return play(Clip(sheet: sheet, frames: 2...21, fps: 12), then: Clip(sheet: sheet, frames: 22...36, fps: 8), at: t)
        case .desktop:
            guard let sheet = ClawdAssets.desktop else { return Frame(laptop, typingLoop.looped(at: t)) }
            return play(Clip(sheet: sheet, frames: 2...14, fps: 12), then: Clip(sheet: sheet, frames: 15...75, fps: 12), at: t)
        case .running:
            guard let sheet = ClawdAssets.running else { return Frame(laptop, typingLoop.looped(at: t)) }
            return Frame(sheet, Clip(sheet: sheet, frames: 5...16, fps: 16).looped(at: t))
        case .waving:
            let cycle = Array(3...16) + Array(repeating: 0, count: 10)  // wave, then a short pause
            return Frame(waving, cycle[Int(t * 12) % cycle.count])
        case .done, .stopped, .failed:
            if previous != nil, let ending = ending(motion) {
                if t < ending.duration { return Frame(ending, at: t) }
                t -= ending.duration
            }
            return idle(t, sinceRest: sinceMotion)
        }
    }

    private func play(_ intro: Clip, then loop: Clip, at t: TimeInterval) -> Frame {
        t < intro.duration ? Frame(intro, at: t) : Frame(loop.sheet, loop.looped(at: t - intro.duration))
    }

    /// Putting away what Clawd holds before doing something else.
    private func exit(from motion: Motion) -> Clip? {
        switch motion {
        case .typing: return closeLaptop
        case .desktop: return ClawdAssets.desktop.map { Clip(sheet: $0, frames: 76...87, fps: 16) }
        default: return nil
        }
    }

    /// One-off reactions: an idea when a task comes in, joy when you allow something,
    /// a facepalm when a tool fails or you say no, confetti and a breakdance after a big task.
    private func reaction(_ cue: Cue) -> [Clip] {
        switch cue {
        case .idea: return [ClawdAssets.lightbulb.map { Clip(sheet: $0, frames: 2...44, fps: 14) }].compactMap { $0 }
        case .excited: return [ClawdAssets.excited.map { Clip(sheet: $0, frames: 2...21, fps: 14) }].compactMap { $0 }
        case .facepalm: return [ClawdAssets.facepalm.map { Clip(sheet: $0, frames: 2...33, fps: 12) }].compactMap { $0 }
        case .celebrate:
            return [ClawdAssets.confetti.map { Clip(sheet: $0, frames: 2...33, fps: 12) },
                    ClawdAssets.breakDancing.map { Clip(sheet: $0, frames: 2...27, fps: 12) }].compactMap { $0 }
        }
    }

    /// How a turn ended: a happy hop, a sigh after Esc, dizzy after an API error.
    private func ending(_ motion: Motion) -> Clip? {
        switch motion {
        case .done: return ClawdAssets.jumping.map { Clip(sheet: $0, frames: 3...20, fps: 14) }
        case .stopped: return ClawdAssets.disappointed.map { Clip(sheet: $0, frames: 2...42, fps: 12) }
        case .failed: return ClawdAssets.dizzy.map { Clip(sheet: $0, frames: 0...40, fps: 12) }
        default: return nil
        }
    }

    /// Mostly standing still; every 30 s a little fidget; after `sleepAfter` sits down and dozes;
    /// at the very end of the rest wakes up and walks off out of the notch.
    private func idle(_ t: TimeInterval, sinceRest: TimeInterval) -> Frame {
        let leaveAt = Store.restDuration - Self.walkOff
        if sinceRest >= leaveAt, let walking = ClawdAssets.walking {
            let w = sinceRest - leaveAt
            return Frame(walking, Clip(sheet: walking, frames: 5...9, fps: 12).looped(at: w), offsetX: -CGFloat(w) * 14)
        }
        if sinceRest >= Self.sleepAfter, let meditating = ClawdAssets.meditating {
            let asleep = sinceRest - Self.sleepAfter
            let sitDown = Clip(sheet: meditating, frames: 2...12, fps: 10)
            if asleep < sitDown.duration { return Frame(sitDown, at: asleep) }
            let doze = Clip(sheet: meditating, frames: 12...48, fps: 6)
            return Frame(meditating, doze.looped(at: asleep - sitDown.duration), dozing: asleep)
        }
        let fidgets: [Clip] = [
            ClawdAssets.lookingAround.map { Clip(sheet: $0, frames: 4...30, fps: 12) },
            ClawdAssets.swaying.map { Clip(sheet: $0, frames: 4...48, fps: 12) },
            ClawdAssets.lookingAround.map { Clip(sheet: $0, frames: 4...30, fps: 12) },
            ClawdAssets.dancing.map { Clip(sheet: $0, frames: 4...38, fps: 12) },
            ClawdAssets.hula.map { Clip(sheet: $0, frames: 6...53, fps: 12) },
        ].compactMap { $0 }
        let window: TimeInterval = 30
        let n = Int(t / window)
        let intoFidget = t - Double(n) * window - 10  // starts 10 s into each window
        if !fidgets.isEmpty, intoFidget >= 0 {
            let fidget = fidgets[n % fidgets.count]
            if intoFidget < fidget.duration { return Frame(fidget, at: intoFidget) }
        }
        return standing
    }

    private func draw(_ frame: Frame, in ctx: GraphicsContext) {
        let sheet = frame.sheet
        let pixels = sheet.frames[min(frame.index, sheet.frames.count - 1)]
        var paths = [Path](repeating: Path(), count: sheet.palette.count)
        let dy = Self.feet.y - sheet.anchor.y
        for y in 0..<sheet.height {
            for x in 0..<sheet.width {
                let v = pixels[y * sheet.width + x]
                guard v != 255 else { continue }
                let mirroredX = Self.feet.x - (CGFloat(x) - sheet.anchor.x) - 1
                paths[Int(v)].addRect(CGRect(x: mirroredX, y: CGFloat(y) + dy, width: 1, height: 1))
            }
        }
        for (i, path) in paths.enumerated() {
            let c = sheet.palette[i]
            ctx.fill(path, with: .color(Color(red: c.r, green: c.g, blue: c.b)))
        }
        if let dozing = frame.dozing { drawZs(dozing, in: ctx) }
    }

    /// Two "z"s drifting up and fading from beside the head, half a cycle apart.
    private func drawZs(_ t: TimeInterval, in ctx: GraphicsContext) {
        let small = ["####", "..#.", ".#..", "####"]
        let big = ["#####", "...#.", "..#..", ".#...", "#####"]
        for (offset, glyph) in [(0.0, small), (0.5, big)] {
            let p = (t / 2.6 + offset).truncatingRemainder(dividingBy: 1)
            let x = Self.feet.x + 4 + CGFloat(p * 4)
            let y = Self.feet.y - 14 - CGFloat(p * 12)
            var path = Path()
            for (row, line) in glyph.enumerated() {
                for (column, char) in line.enumerated() where char == "#" {
                    path.addRect(CGRect(x: x + CGFloat(column), y: y + CGFloat(row), width: 1, height: 1))
                }
            }
            ctx.fill(path, with: .color(.white.opacity(0.75 * (1 - p))))
        }
    }
}
