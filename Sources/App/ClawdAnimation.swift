import AppKit
import SwiftUI

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
        return PixelSheet(name: name, width: width, height: height, palette: palette, frames: frames, anchor: anchor)
    }
}

/// Frames `frames` of `sheet`, in that order, played at `fps`.
private struct Clip {
    let sheet: PixelSheet
    let frames: [Int]
    let fps: Double

    init(sheet: PixelSheet, frames: [Int], fps: Double) {
        self.sheet = sheet
        self.frames = frames
        self.fps = fps
    }

    init(sheet: PixelSheet, frames: ClosedRange<Int>, fps: Double) {
        self.init(sheet: sheet, frames: Array(frames), fps: fps)
    }

    var duration: TimeInterval { Double(frames.count) / fps }

    /// Played once: holds the last frame afterwards.
    func frame(at t: TimeInterval) -> Int { frames[min(frames.count - 1, max(0, Int(t * fps)))] }

    func looped(at t: TimeInterval) -> Int { frames[max(0, Int(t * fps)) % frames.count] }
}

/// Clawd in the notch. With the Claude app's sprites he turns to a laptop and types while Claude
/// works, puts it away and waves while Claude waits for you. After a turn he reacts (a happy hop,
/// a sigh after Esc, dizzy after an error), then idles with the odd fidget and dozes off.
struct ClawdView: View {
    let session: Session

    var body: some View {
        if let laptop = ClawdAssets.laptop, let waving = ClawdAssets.waving {
            ClawdLayer(animator: ClawdAnimator(session: session, laptop: laptop, waving: waving))
                .frame(width: ClawdAnimator.size.width, height: ClawdAnimator.size.height)
        } else {
            DrawnClawdView(phase: session.phase)
        }
    }
}

/// Which frame of which sheet Clawd shows at a given moment, worked out from the session.
private struct ClawdAnimator {
    let session: Session
    let laptop: PixelSheet
    let waving: PixelSheet

    /// Room for the laptop or desk on the left (sheets are mirrored) and for a light bulb or a
    /// happy hop above the head.
    static let size = CGSize(width: 36, height: 32)
    static let feet = CGPoint(x: 24, y: 31)
    /// Idle this long after a turn and Clawd sits down and dozes off.
    private static let sleepAfter: TimeInterval = 3 * 60
    /// At the end of the rest Clawd walks off out of the notch, for this long.
    private static let walkOff: TimeInterval = 4.5

    /// One frame to draw; `dozing` is the time asleep (for the floating "z"s), `offsetX` moves
    /// Clawd while he walks off, `rate` is how often the picture changes from here (redraws/s).
    struct Frame {
        let sheet: PixelSheet
        let index: Int
        var dozing: TimeInterval?
        var offsetX: CGFloat = 0
        var rate: Double = 16

        init(_ sheet: PixelSheet, _ index: Int, rate: Double = 16, dozing: TimeInterval? = nil, offsetX: CGFloat = 0) {
            self.sheet = sheet
            self.index = index
            self.rate = rate
            self.dozing = dozing
            self.offsetX = offsetX
        }

        init(_ clip: Clip, at t: TimeInterval) { self.init(clip.sheet, clip.frame(at: t), rate: clip.fps) }
    }


    /// The happy hop: crouch, jump, hang at the top (3–9), then straight to the landing (13–20). The sheet
    /// brings him down over three slow frames (10–12), which looks like he slides down.
    private static func hop(_ sheet: PixelSheet) -> Clip {
        Clip(sheet: sheet, frames: Array(3...9) + Array(13...20), fps: 14)
    }

    // Laptop: 0–3 standing, 2–16 turn and open the laptop, 17–33 typing loop, 34–42 close it.
    private var openLaptop: Clip { Clip(sheet: laptop, frames: 2...16, fps: 12) }
    private var typingLoop: Clip { Clip(sheet: laptop, frames: 17...33, fps: 12) }
    private var closeLaptop: Clip { Clip(sheet: laptop, frames: 34...42, fps: 16) }
    private var standing: Frame { Frame(laptop, 0, rate: 2) }

    func frame(at date: Date) -> Frame {
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
            return Frame(laptop, typingLoop.looped(at: t), rate: typingLoop.fps)
        case .pondering:
            guard let sheet = ClawdAssets.thinking else { return Frame(laptop, typingLoop.looped(at: t)) }
            // A speech bubble pops up, he sits down, and dots keep coming in the bubble.
            return play(Clip(sheet: sheet, frames: 2...21, fps: 12), then: Clip(sheet: sheet, frames: 22...36, fps: 8), at: t)
        case .desktop:
            guard let sheet = ClawdAssets.desktop else { return Frame(laptop, typingLoop.looped(at: t)) }
            return play(Clip(sheet: sheet, frames: 2...14, fps: 12), then: Clip(sheet: sheet, frames: 15...75, fps: 12), at: t)
        case .running:
            guard let sheet = ClawdAssets.running else { return Frame(laptop, typingLoop.looped(at: t)) }
            return Frame(sheet, Clip(sheet: sheet, frames: 5...16, fps: 16).looped(at: t), rate: 16)
        case .waving:
            let cycle = Array(3...16) + Array(repeating: 0, count: 10)  // wave, then a short pause
            return Frame(waving, cycle[Int(t * 12) % cycle.count], rate: 12)
        case .done, .stopped, .failed:
            if previous != nil, let ending = ending(motion) {
                if t < ending.duration { return Frame(ending, at: t) }
                t -= ending.duration
            }
            return idle(t, sinceRest: sinceMotion)
        }
    }

    private func play(_ intro: Clip, then loop: Clip, at t: TimeInterval) -> Frame {
        t < intro.duration ? Frame(intro, at: t) : Frame(loop.sheet, loop.looped(at: t - intro.duration), rate: loop.fps)
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
    /// a facepalm when a tool fails or you say no, confetti and a breakdance after a big task,
    /// a hop and a wave when the app is opened.
    private func reaction(_ cue: Cue) -> [Clip] {
        switch cue {
        case .hello:
            return [ClawdAssets.jumping.map(Self.hop),
                    Clip(sheet: waving, frames: 3...16, fps: 12)].compactMap { $0 }
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
        case .done: return ClawdAssets.jumping.map(Self.hop)
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
            return Frame(walking, Clip(sheet: walking, frames: 5...9, fps: 12).looped(at: w), rate: 16, offsetX: -CGFloat(w) * 14)
        }
        if sinceRest >= Self.sleepAfter, let meditating = ClawdAssets.meditating {
            let asleep = sinceRest - Self.sleepAfter
            let sitDown = Clip(sheet: meditating, frames: 2...12, fps: 10)
            if asleep < sitDown.duration { return Frame(sitDown, at: asleep) }
            let doze = Clip(sheet: meditating, frames: 12...48, fps: 6)
            return Frame(meditating, doze.looped(at: asleep - sitDown.duration), rate: 8, dozing: asleep)
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
}

/// Shows `ClawdAnimator`'s frames with Core Animation: each frame swaps a ready picture into a layer.
/// Drawn by SwiftUI instead, every frame (12 a second while Claude works) meant a SwiftUI pass over the
/// whole notch: about 6% of a CPU core, against about 1% this way.
private struct ClawdLayer: NSViewRepresentable {
    let animator: ClawdAnimator

    func makeNSView(context: Context) -> ClawdLayerView { ClawdLayerView(animator: animator) }
    func updateNSView(_ view: ClawdLayerView, context: Context) { view.animator = animator }
}

private final class ClawdLayerView: NSView {
    var animator: ClawdAnimator { didSet { showFrame() } }
    private let sprite = CALayer()
    /// Two "z"s drifting up and fading from beside the head while Clawd dozes, half a cycle apart.
    private let zs = [CALayer(), CALayer()]
    private var timer: Timer?

    init(animator: ClawdAnimator) {
        self.animator = animator
        super.init(frame: NSRect(origin: .zero, size: ClawdAnimator.size))
        // AppKit's own layer, not one set here: AppKit keeps it flipped to match `isFlipped` wherever
        // SwiftUI puts the view. A layer set by hand is flipped relative to its parent, which changes
        // with the notch's state, and frames of different heights then stood at different heights.
        wantsLayer = true
        layerContentsRedrawPolicy = .never  // nothing to draw: the sublayers show the pictures
        guard let root = layer else { return }
        for (layer, glyph) in [(sprite, nil), (zs[0], SpriteImages.smallZ), (zs[1], SpriteImages.bigZ)] {
            layer.magnificationFilter = .nearest  // crisp pixels
            if let glyph {
                layer.contents = glyph
                layer.bounds = CGRect(x: 0, y: 0, width: glyph.width, height: glyph.height)
                layer.anchorPoint = .zero
            }
            root.addSublayer(layer)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }  // top-left origin, like the sprite sheets

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        showFrame()
    }

    /// Shows the frame for now and comes back when the picture changes; stops while out of a window.
    private func showFrame() {
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        let frame = animator.frame(at: Date())
        let sheet = frame.sheet

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.contents = SpriteImages.image(sheet, frame.index)
        // Mirrored, with the sheet's anchor on Clawd's feet.
        let feet = ClawdAnimator.feet
        sprite.frame = CGRect(x: feet.x + sheet.anchor.x - CGFloat(sheet.width) + frame.offsetX,
                              y: feet.y - sheet.anchor.y,
                              width: CGFloat(sheet.width), height: CGFloat(sheet.height))
        for (z, offset) in zip(zs, [0.0, 0.5]) {
            z.isHidden = frame.dozing == nil
            guard let dozing = frame.dozing else { continue }
            let p = (dozing / 2.6 + offset).truncatingRemainder(dividingBy: 1)
            z.position = CGPoint(x: feet.x + 4 + p * 4, y: feet.y - 14 - p * 12)
            z.opacity = Float(0.75 * (1 - p))
        }
        CATransaction.commit()

        let delay = 1 / min(16, max(1, frame.rate))
        let next = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.showFrame() }
        next.tolerance = delay / 10  // lets macOS bundle the wakeup with others
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }
}

/// Sprite frames turned into pictures once, mirrored the way Clawd faces in the notch.
private enum SpriteImages {
    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 300  // a few kilobytes each
        return cache
    }()

    static func image(_ sheet: PixelSheet, _ index: Int) -> CGImage? {
        let key = "\(sheet.name)#\(index)" as NSString
        if let image = cache.object(forKey: key) { return image }
        let pixels = sheet.frames[min(index, sheet.frames.count - 1)]
        let colors = sheet.palette.map { [UInt8($0.r * 255), UInt8($0.g * 255), UInt8($0.b * 255), 255] }
        var rgba = [UInt8](repeating: 0, count: sheet.width * sheet.height * 4)
        for y in 0..<sheet.height {
            for x in 0..<sheet.width {
                let v = pixels[y * sheet.width + x]
                guard v != 255 else { continue }
                let at = (y * sheet.width + sheet.width - 1 - x) * 4
                rgba.replaceSubrange(at..<(at + 4), with: colors[Int(v)])
            }
        }
        guard let image = makeImage(rgba, width: sheet.width, height: sheet.height) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    static let smallZ = glyph(["####", "..#.", ".#..", "####"])
    static let bigZ = glyph(["#####", "...#.", "..#..", ".#...", "#####"])

    private static func glyph(_ rows: [String]) -> CGImage? {
        let width = rows[0].count
        let rgba = rows.flatMap { $0.flatMap { $0 == "#" ? [UInt8](repeating: 255, count: 4) : [0, 0, 0, 0] } }
        return makeImage(rgba, width: width, height: rows.count)
    }

    private static func makeImage(_ rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
