import Foundation

/// Frames `frames` of `sheet`, in that order, played at `fps`.
struct Clip {
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

/// Which frame of which sheet Clawd shows at a given moment, worked out from the session.
struct ClawdAnimator {
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
    /// `mirrored` is how Clawd usually faces in the notch, to the left; not, he faces right.
    /// `offsetY` drops him from above (a parachute); `decals` are props drawn over him. `busy`: he's in
    /// the middle of a reaction or a pastime, which a poke shouldn't cut short.
    struct Frame {
        let sheet: PixelSheet
        let index: Int
        var dozing: TimeInterval?
        var offsetX: CGFloat = 0
        var offsetY: CGFloat = 0
        var rate: Double = 16
        var mirrored = true
        var decals: [Decal] = []
        var busy = false

        init(_ sheet: PixelSheet, _ index: Int, rate: Double = 16, dozing: TimeInterval? = nil, offsetX: CGFloat = 0,
             offsetY: CGFloat = 0, mirrored: Bool = true, decals: [Decal] = []) {
            self.sheet = sheet
            self.index = index
            self.rate = rate
            self.dozing = dozing
            self.offsetX = offsetX
            self.offsetY = offsetY
            self.mirrored = mirrored
            self.decals = decals
        }

        init(_ clip: Clip, at t: TimeInterval) { self.init(clip.sheet, clip.frame(at: t), rate: clip.fps) }

        func markedBusy() -> Frame {
            var frame = self
            frame.busy = true
            return frame
        }
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

    func frame(at date: Date) -> Frame {
        mood(plainFrame(at: date), at: date)
    }

    private func plainFrame(at date: Date) -> Frame {
        let sinceMotion = date.timeIntervalSince(session.motionStart)
        if let cue = session.cue, let reaction = Self.reactions[cue] ?? Self.moodReactions[cue] {
            // Put the laptop away first.
            let putAway = exit(from: session.cueInterrupted)
            let lead = putAway?.duration ?? 0
            let t = date.timeIntervalSince(session.cueStart)
            if let putAway, t < lead { return Frame(putAway, at: t).markedBusy() }
            if t < lead + reaction.duration { return reaction.frame(t - lead).markedBusy() }
            let cueEnd = session.cueStart.addingTimeInterval(lead + reaction.duration)
            if cueEnd > session.motionStart {
                // The reaction took over the start of what Clawd does now: carry on from its end
                // with empty hands (nothing to put away, no hop after confetti).
                return motionFrame(after: nil, t: date.timeIntervalSince(cueEnd), sinceMotion: sinceMotion, at: date)
            }
        }
        return motionFrame(after: session.previousMotion, t: sinceMotion, sinceMotion: sinceMotion, at: date)
    }

    /// `previous`: what Clawd did before (nil = nothing in hand); `t`: time into this motion.
    private func motionFrame(after previous: Motion?, t: TimeInterval, sinceMotion: TimeInterval, at date: Date) -> Frame {
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
            if let impatient = Self.waitingLong(t) { return impatient }
            let cycle = Array(3...16) + Array(repeating: 0, count: 10)  // wave, then a short pause
            return Frame(waving, cycle[Int(t * 12) % cycle.count], rate: 12)
        case .searching:
            guard let looking = Self.searching else { return Frame(laptop, typingLoop.looped(at: t)) }
            if previous != .searching, let putting = Self.hatOn(t) { return putting }
            return looking.frame(t.truncatingRemainder(dividingBy: looking.duration))
        case .compacting:
            guard let box = Self.compacting else { return Frame(laptop, typingLoop.looped(at: t)) }
            if previous != .compacting, let aside = Self.turnAside {
                if t < aside.duration { return Frame(aside, at: t) }
                t -= aside.duration
            }
            return box.frame(t.truncatingRemainder(dividingBy: box.duration))
        case .limited:
            // Also after a reaction (nil): a rate limit often comes while the light bulb is still up.
            if let hourglass = Self.rateLimit {
                if t < hourglass.duration { return hourglass.frame(t) }
                t -= hourglass.duration
            }
            return Store.alive ? life(at: date, restingSince: date.addingTimeInterval(-t)) : idle(t, sinceRest: sinceMotion)
        case .done, .stopped, .failed:
            if previous != nil, let ending = ending(motion) {
                if t < ending.duration { return Frame(ending, at: t) }
                t -= ending.duration
            }
            return Store.alive ? life(at: date, restingSince: date.addingTimeInterval(-t)) : idle(t, sinceRest: sinceMotion)
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
        case .searching, .compacting: return Self.turnBack  // turned aside: back to you
        default: return nil
        }
    }

    /// One-off reactions: an idea when a task comes in, joy when you allow something,
    /// a facepalm when a tool fails or you say no, confetti and a breakdance after a big task,
    /// a hop and a wave when the app is opened, a parachute and a wave when he moves into the notch.
    /// Made once: Clawd's frame is worked out many times a second, and a session keeps its last cue
    /// long after it has played.
    static let reactions: [Cue: Pastime] = {
        func clip(_ sheet: PixelSheet?, _ frames: ClosedRange<Int>, fps: Double) -> Clip? {
            sheet.map { Clip(sheet: $0, frames: frames, fps: fps) }
        }
        let wave = clip(ClawdAssets.waving, 3...16, fps: 12)
        let all: [Cue: Pastime?] = [
            .hello: Pastime([ClawdAssets.jumping.map(hop), wave].compactMap { $0 }),
            .arrive: Pastime.sequence([parachute, Pastime([wave].compactMap { $0 })]),
            .idea: Pastime([clip(ClawdAssets.lightbulb, 2...44, fps: 14)].compactMap { $0 }),
            .excited: Pastime([clip(ClawdAssets.excited, 2...21, fps: 14)].compactMap { $0 }),
            .facepalm: Pastime([clip(ClawdAssets.facepalm, 2...33, fps: 12)].compactMap { $0 }),
            .celebrate: Pastime([clip(ClawdAssets.confetti, 2...33, fps: 12), clip(ClawdAssets.breakDancing, 2...27, fps: 12)]
                .compactMap { $0 }),
        ]
        return all.compactMapValues { $0 }
    }()

    /// How a turn ended: a happy hop; after Esc he turns to you and blinks, listening (often Esc just
    /// means you want to say something); dizzy after an API error.
    private func ending(_ motion: Motion) -> Clip? {
        switch motion {
        case .done: return ClawdAssets.jumping.map(Self.hop)
        case .stopped: return ClawdAssets.turning.map { Clip(sheet: $0, frames: [0, 0, 0, 4, 0, 0, 0, 0, 0, 4, 0, 0], fps: 6) }
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
            let index = doze.looped(at: asleep - sitDown.duration)
            return Frame(meditating, index, rate: 8, dozing: asleep,
                         decals: [Self.book(on: meditating, index, dropping: asleep - sitDown.duration)])
        }
        let window: TimeInterval = 30
        let n = Int(t / window)
        let intoFidget = t - Double(n) * window - 10  // starts 10 s into each window
        if !Self.fidgets.isEmpty, intoFidget >= 0 {
            let seed = UInt64(bitPattern: Int64(session.motionStart.timeIntervalSinceReferenceDate))
            let fidget = Self.fidgets[Self.pick(n, of: Self.fidgets.count, seed: seed)]
            if intoFidget < fidget.duration { return Frame(fidget, at: intoFidget) }
        }
        // Standing still until the next fidget, or until he sits down or walks off: no look before then.
        let nextFidget = Double(intoFidget < 0 ? n : n + 1) * window + 10 - t
        let next = [nextFidget, Self.sleepAfter - sinceRest, Store.restDuration - Self.walkOff - sinceRest].filter { $0 > 0 }.min()
        return Frame(laptop, 0, rate: 1 / max(next ?? 1, 1.0 / 16))
    }

    private static let fidgets: [Clip] = [
        ClawdAssets.lookingAround.map { Clip(sheet: $0, frames: 4...30, fps: 12) },
        ClawdAssets.swaying.map { Clip(sheet: $0, frames: 4...48, fps: 12) },
        ClawdAssets.dancing.map { Clip(sheet: $0, frames: 4...38, fps: 12) },
        ClawdAssets.hula.map { Clip(sheet: $0, frames: 6...53, fps: 12) },
    ].compactMap { $0 }

    /// Which of `count` the `n`th fidget of a rest is: in no set order, and never the same twice in a row.
    /// `seed` is when the rest began, so it stays the same however often he's drawn.
    static func pick(_ n: Int, of count: Int, seed: UInt64) -> Int {
        guard count > 1 else { return 0 }
        var random = SeededRandom(seed: seed)
        var pick = Int.random(in: 0..<count, using: &random)
        for _ in 0..<max(0, n) { pick = (pick + Int.random(in: 1..<count, using: &random)) % count }
        return pick
    }

    // MARK: - Living in the notch

    /// Something Clawd does on his own: how long it takes, and what he shows `t` seconds in.
    struct Pastime {
        let duration: TimeInterval
        let frame: (TimeInterval) -> Frame

        init(duration: TimeInterval, frame: @escaping (TimeInterval) -> Frame) {
            self.duration = duration
            self.frame = frame
        }

        /// Clips played one after another; nil without any.
        init?(_ clips: [Clip]) {
            guard let last = clips.last else { return nil }
            duration = clips.reduce(0) { $0 + $1.duration }
            frame = { t in
                var t = t
                for clip in clips.dropLast() {
                    if t < clip.duration { return Frame(clip, at: t) }
                    t -= clip.duration
                }
                return Frame(last, at: t)
            }
        }

        /// The ones there are, one after another; nil without any.
        static func sequence(_ parts: [Pastime?]) -> Pastime? {
            let parts = parts.compactMap { $0 }
            guard let last = parts.last else { return nil }
            return Pastime(duration: parts.reduce(0) { $0 + $1.duration }) { t in
                var t = t
                for part in parts.dropLast() {
                    if t < part.duration { return part.frame(t) }
                    t -= part.duration
                }
                return last.frame(t)
            }
        }
    }

    /// Floats down into the notch from above the screen under a parachute, lands and lets it go.
    private static let parachute: Pastime? = {
        guard let sheet = ClawdAssets.jumping else { return nil }
        let fall: TimeInterval = 3.2
        let land = Clip(sheet: sheet, frames: 13...20, fps: 14)
        let canopy = Decal(Props.parachute, -1, -10)
        return Pastime(duration: fall + land.duration) { t in
            guard t < fall else { return Frame(land, at: t - fall) }
            let p = t / fall
            let eased = 1 - (1 - p) * (1 - p)  // slows down before touching down
            // From out of sight above the screen to his feet on the ground: in this frame he's 10 px up in the air.
            let drop: Double = -26 + 36 * eased
            let sway: Double = sin(t * 2.6) * 2 * (1 - p)
            return Frame(sheet, 8, offsetX: CGFloat(sway.rounded()), offsetY: CGFloat(drop.rounded()), decals: [canopy])
        }
    }()

    /// What Clawd gets up to when he lives in the notch for good. None of it is what he does at work
    /// or when Claude needs you, so it can't be taken for news: when he thinks here he stays on his
    /// feet, where at work he sits down to.
    static let pastimes: [Pastime] = {
        func clip(_ sheet: PixelSheet?, _ frames: ClosedRange<Int>, fps: Double = 12) -> Clip? {
            sheet.map { Clip(sheet: $0, frames: frames, fps: fps) }
        }
        func pastime(_ clips: Clip?...) -> Pastime? { Pastime(clips.compactMap { $0 }) }
        let dance = clip(ClawdAssets.dancing, 4...38)
        let hop = ClawdAssets.jumping.map(Self.hop)
        // The whole routine (shuffle, windmill, headspin, a pose) where the sheet has it, else the shuffle.
        let breakdance = ClawdAssets.breakDancing.flatMap { sheet in
            pastime(Clip(sheet: sheet, frames: sheet.frames.count >= 149 ? 2...148 : 2...27, fps: 12))
        }
        // Stands thinking with a hand on his chin while the dots in a bubble come and go.
        let think = ClawdAssets.thinking.flatMap { sheet in
            pastime(Clip(sheet: sheet, frames: 2...19, fps: 10), Clip(sheet: sheet, frames: 8...19, fps: 10),
                    Clip(sheet: sheet, frames: [3], fps: 4))
        }

        // Sits down, dozes off for a little while under an open book and gets back up.
        let nap = ClawdAssets.meditating.map { sheet in
            let sitDown = Clip(sheet: sheet, frames: 2...12, fps: 10)
            let doze = Clip(sheet: sheet, frames: 12...44, fps: 6)
            let wakeUp = Clip(sheet: sheet, frames: 45...59, fps: 10)
            let asleep = 4 * doze.duration
            return Pastime(duration: sitDown.duration + asleep + wakeUp.duration) { t in
                if t < sitDown.duration { return Frame(sitDown, at: t) }
                let dozing = t - sitDown.duration
                if dozing < asleep {
                    let index = doze.looped(at: dozing)
                    return Frame(sheet, index, rate: 8, dozing: dozing, decals: [book(on: sheet, index, dropping: dozing)])
                }
                // The book stays on until he's back on his feet.
                let index = wakeUp.frame(at: dozing - asleep)
                return Frame(sheet, index, rate: wakeUp.fps, decals: index < 54 ? [book(on: sheet, index, dropping: .infinity)] : [])
            }
        }

        // Off to the left out of the notch, a few seconds out of sight, and back: walking in facing
        // right, or floating down under a parachute.
        let speed: CGFloat = 14  // as when he walks off at the end of a rest
        let walk: TimeInterval = 4.5  // far enough to be out of sight
        let gone = -CGFloat(walk) * speed
        let walkOff = ClawdAssets.walking.map { sheet in
            let turn = Clip(sheet: sheet, frames: 2...4, fps: 12)
            let step = Clip(sheet: sheet, frames: 5...24, fps: 12)
            return Pastime(duration: turn.duration + walk) { t in
                guard t >= turn.duration else { return Frame(turn, at: t) }
                return Frame(sheet, step.looped(at: t - turn.duration), offsetX: -CGFloat(t - turn.duration) * speed)
            }
        }
        func away(_ seconds: TimeInterval) -> Pastime? {
            ClawdAssets.walking.map { sheet in Pastime(duration: seconds) { _ in Frame(sheet, 0, rate: 2, offsetX: gone) } }
        }
        let walkBack = ClawdAssets.walking.map { sheet in
            let step = Clip(sheet: sheet, frames: 5...24, fps: 12)
            let face = Clip(sheet: sheet, frames: 25...27, fps: 12)
            return Pastime(duration: walk + face.duration) { t in
                guard t >= walk else { return Frame(sheet, step.looped(at: t), offsetX: gone + CGFloat(t) * speed, mirrored: false) }
                return Frame(face, at: t - walk)
            }
        }
        let stroll = walkOff == nil || walkBack == nil ? nil : Pastime.sequence([walkOff, away(5), walkBack])
        let skydive = walkOff == nil || parachute == nil ? nil : Pastime.sequence([walkOff, away(3), parachute])

        // Props from ClawdProps.swift, over his own frames. Nothing turns up out of thin air: he takes a prop
        // out from behind his back, and puts it back there when he's done. All of them are placed on the
        // Pointing sheet: 0 stands (his head's top row at y 5, his body x 4–19 down to y 16, arms at x 0–3
        // and 20–23, y 9–12, cut away while a hand is behind his back), 6 raises his arms, 7–14 hold them up
        // (hands' top row at y 0), 15 brings them down to his head (y 1), 16 squashes him as they come down
        // to his sides, 17–18 turn him and 24 holds out his near arm.
        // His arms as far out as `left` and `right` pixels (4 being all of each): the rest is behind his back.
        func arms(left: Int = 4, right: Int = 4) -> [Decal] {
            [Decal(Props.arm, -min(4, max(0, left)), 9, .cut), Decal(Props.arm, 20 + min(4, max(0, right)), 9, .cut)]
        }
        func lerp(_ from: Int, _ to: Int, _ p: Double) -> Int { from + Int((Double(to - from) * min(1, max(0, p))).rounded()) }
        func smooth(_ p: Double) -> Double { let p = min(1, max(0, p)); return p * p * (3 - 2 * p) }
        func moved(_ decals: [Decal], _ dx: Int, _ dy: Int) -> [Decal] { decals.map { $0.moved(dx, dy) } }

        // Where his near hand holds things, just past its end at its top row: at his side (0), squashed
        // while turning (17), turned (18) and with the arm out (24).
        let grip: [Int: (x: Int, y: Int)] = [0: (24, 9), 17: (23, 12), 18: (25, 8), 24: (27, 8)]

        // A hat or headphones: he puts both hands behind his back, lifts it up from there over his head, which
        // hides it until it's past, raises his arms to take it and puts it on; and the other way round, back
        // behind his back. `y` is its top row: `tucked` behind his back, `raising` in his hands as they go
        // up (6), `overhead` held up (7–14), `lowering` as they come down (15), and `worn` while he stands.
        // What's wider than him is `folded` while it's behind him, or it would show.
        func headgear(_ sheet: PixelSheet, _ art: PixelArt, x: Int, folded: (art: PixelArt, x: Int)? = nil, tucked: Int,
                      raising: Int, overhead: Int, lowering: Int, worn: Int) -> (take: Pastime, putBack: Pastime) {
            func at(_ y: Int, _ layer: Decal.Layer = .front) -> [Decal] { [Decal(art, x, y, layer)] }
            let behind = folded ?? (art, x)
            func behindHim(arms out: Int, lifted p: Double) -> Frame {
                Frame(sheet, 0, rate: 16, decals: arms(left: out, right: out)
                    + [Decal(behind.art, behind.x, lerp(tucked, raising + 2, smooth(p)), .behind)])
            }
            let putOn = [
                Pastime(duration: 0.08) { _ in Frame(sheet, 6, rate: 12, decals: at(raising)) },
                Pastime(duration: 0.3) { t in Frame(sheet, 7 + min(7, Int(t * 12)), rate: 12, decals: at(overhead)) },
                Pastime(duration: 0.12) { _ in Frame(sheet, 15, rate: 12, decals: at(lowering)) },
                Pastime(duration: 0.12) { _ in Frame(sheet, 16, rate: 12, decals: at(worn + 1)) },
            ]
            let take = Pastime.sequence([
                Pastime(duration: 0.2) { t in behindHim(arms: lerp(4, 0, t / 0.2), lifted: 0) },
                Pastime(duration: 0.15) { _ in behindHim(arms: 0, lifted: 0) },
                Pastime(duration: 0.45) { t in behindHim(arms: 0, lifted: t / 0.45) },
            ] + putOn)!
            let putBack = Pastime.sequence(putOn.reversed() + [
                Pastime(duration: 0.45) { t in behindHim(arms: 0, lifted: 1 - t / 0.45) },
                Pastime(duration: 0.1) { _ in behindHim(arms: 0, lifted: 0) },
                Pastime(duration: 0.2) { t in behindHim(arms: lerp(0, 4, t / 0.2), lifted: 0) },
            ])!
            return (take, putBack)
        }

        // Something he holds in his near hand, `held` placed as if the hand's grip were at (0, 0): he puts the
        // hand behind his back and brings it out holding it, his arm coming out as it slides out from behind
        // him; and later puts it back there. `wearing` stays on him meanwhile.
        func handHeld(_ sheet: PixelSheet, _ held: [Decal], wearing: [Decal] = []) -> (take: Pastime, putBack: Pastime) {
            let side = grip[0]!
            let atSide = moved(held, side.x, side.y)
            // Behind him, all of it within his body.
            let dx = 6 - (atSide.map(\.x).min() ?? 0), dy = max(0, 7 - (atSide.map(\.y).min() ?? 0))
            func emptyHand(out: Int) -> Frame { Frame(sheet, 0, rate: 16, decals: wearing + arms(right: out)) }
            func sliding(_ p: Double) -> Frame {
                let ox = lerp(dx, 0, smooth(p)), oy = lerp(dy, 0, smooth(p))
                // The arm reaches as far as the hand holding it.
                return Frame(sheet, 0, rate: 16, decals: wearing + arms(right: side.x + ox - 20)
                    + moved(atSide, ox, oy).map { $0.on(.behind) })
            }
            let holding = Pastime(duration: 0.12) { _ in Frame(sheet, 0, rate: 12, decals: wearing + atSide) }
            let take = Pastime.sequence([
                Pastime(duration: 0.2) { t in emptyHand(out: lerp(4, 0, t / 0.2)) },
                Pastime(duration: 0.15) { _ in sliding(0) },
                Pastime(duration: 0.45) { t in sliding(t / 0.45) },
                holding,
            ])!
            let putBack = Pastime.sequence([
                holding,
                Pastime(duration: 0.45) { t in sliding(1 - t / 0.45) },
                Pastime(duration: 0.1) { _ in sliding(0) },
                Pastime(duration: 0.2) { t in emptyHand(out: lerp(0, 4, t / 0.2)) },
            ])!
            return (take, putBack)
        }

        // Turning to hold out his near arm with `held` in his hand (placed as for `handHeld`), `act` giving
        // what he holds out for `seconds`, and turning back. The hat sits a pixel lower while he's squashed.
        func holdOut(_ sheet: PixelSheet, _ held: [Decal], hat: Decal, seconds: TimeInterval,
                     _ act: @escaping (TimeInterval) -> [Decal]) -> Pastime {
            func frame(_ index: Int, rate: Double = 12, _ decals: [Decal]? = nil) -> Frame {
                let hand = grip[index]!
                return Frame(sheet, index, rate: rate, decals: [hat.moved(0, index == 17 ? 1 : 0)] + (decals ?? moved(held, hand.x, hand.y)))
            }
            return Pastime.sequence([
                Pastime(duration: 0.08) { _ in frame(17) },
                Pastime(duration: 0.08) { _ in frame(18) },
                Pastime(duration: seconds) { t in frame(24, rate: 16, act(t)) },
                Pastime(duration: 0.08) { _ in frame(18) },
                Pastime(duration: 0.08) { _ in frame(17) },
            ])!
        }

        // Three wisps rising from (x, y) and fading.
        func steam(_ t: TimeInterval, x: Int, y: Int) -> [Decal] {
            (0..<3).map { i in
                let p = (t / 1.5 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let rise = Int(p * 6)
                return Decal(p < 0.6 ? Props.steam : Props.steamFading, x + i % 2 + rise / 2 % 2, y - rise)
            }
        }

        // A mug of coffee from behind his back: he turns aside with it, like at the laptop, steam curls up
        // from it, and twice he takes a sip, eyes shut in a smile; then turns back to put it away. Turned
        // (Turning 8) his hand is at x 22, y 5–8; a row lower as he starts to turn (4), a row higher once
        // round (5).
        let coffee = ClawdAssets.pointing.flatMap { sheet in ClawdAssets.turning.map { turning in
            let (take, putBack) = handHeld(sheet, [Decal(Props.mug, 0, -1)])
            func turn(_ frames: [Int]) -> Pastime {
                Pastime(duration: Double(frames.count) / 12) { t in
                    let index = frames[min(frames.count - 1, Int(t * 12))]
                    let mug = index == 4 ? Decal(Props.mug, 24, 5) : Decal(Props.mug, 23, 3)
                    return Frame(turning, index, rate: 12, decals: [mug])
                }
            }
            let drinking = Pastime(duration: 8) { t in
                let sip = (1.6..<3.0).contains(t) || (5.0..<6.4).contains(t)
                let decals = sip
                    ? [Decal(Props.mug, 22, 2), Decal(Props.happyEyesTurned, 8, 3)] + steam(t, x: 25, y: 1)
                    : [Decal(Props.mug, 23, 4)] + steam(t, x: 26, y: 3)
                return Frame(turning, 8, rate: 12, decals: decals)
            }
            return Pastime.sequence([take, turn([4, 5]), drinking, turn([5, 4]), putBack])!
        } }

        let music = ClawdAssets.pointing.map { sheet in
            let phones = Props.headphones
            let (take, putBack) = headgear(sheet, phones, x: 1, folded: (Props.headphonesFolded, 5), tucked: 7, raising: 0, overhead: -1, lowering: -1, worn: 3)
            let listening = Pastime(duration: 9) { t in
                var decals = [Decal(phones, 1, 3), Decal(Props.closedEyes, 5, 7)]
                for i in 0..<2 {
                    let p = (t / 1.8 + Double(i) / 2).truncatingRemainder(dividingBy: 1)
                    decals.append(Decal(Props.note, 24 + 5 * i + Int(p * 2), 1 - Int(p * 9)))
                }
                let nod = t.truncatingRemainder(dividingBy: 0.5) < 0.16
                return Frame(sheet, 0, rate: 12, offsetY: nod ? 1 : 0, decals: decals)
            }
            return Pastime.sequence([take, listening, putBack])!
        }

        // A wizard's hat, then a wand, from behind his back: he holds the wand up, sparkles fly off its star,
        // and he winks.
        let wizard = ClawdAssets.pointing.map { sheet in
            let hat = Props.wizardHat, worn = Decal(hat, 2, -5)
            let (hatOn, hatOff) = headgear(sheet, hat, x: 2, folded: (Props.wizardHatTucked, 2), tucked: 6, raising: 2 - hat.height, overhead: -hat.height,
                                           lowering: 1 - hat.height, worn: worn.y)
            let wand = [Decal(Props.wand, 0, -4), Decal(Props.star, 3, -7)]
            let (wandOut, wandAway) = handHeld(sheet, wand, wearing: [worn])
            let spots = [(34, 0), (33, 4), (29, -2), (35, 3), (32, -3), (36, 1)]
            let magic = holdOut(sheet, wand, hat: worn, seconds: 4) { u in
                var decals = moved(wand, grip[24]!.x, grip[24]!.y)
                for (i, spot) in spots.enumerated() {
                    let phase = (u * 3 + Double(i) * 0.5).truncatingRemainder(dividingBy: 3)
                    if phase < 0.5 {
                        decals.append(Decal(Props.bigSparkle, spot.0 - 1, spot.1 - 1))
                    } else if phase < 1.2 {
                        decals.append(Decal(Props.sparkle, spot.0, spot.1))
                    }
                }
                if (2.0..<2.8).contains(u) { decals.append(Decal(Props.wink, 18, 7)) }
                return decals
            }
            return Pastime.sequence([hatOn, wandOut, magic, wandAway, hatOff])!
        }

        // A chef's hat, then a frying pan with a pancake in it, from behind his back: he tosses the pancake, it
        // turns over in the air and lands.
        let chef = ClawdAssets.pointing.map { sheet in
            let hat = Props.chefHat, worn = Decal(hat, 4, -4)
            let (hatOn, hatOff) = headgear(sheet, hat, x: 4, tucked: 6, raising: 2 - hat.height, overhead: -hat.height,
                                           lowering: 1 - hat.height, worn: worn.y)
            let pan = [Decal(Props.pan, 0, 0), Decal(Props.pancakeFlat, 5, -1)]
            let (panOut, panAway) = handHeld(sheet, pan, wearing: [worn])
            let cooking = holdOut(sheet, pan, hat: worn, seconds: 3.9) { u in
                guard u >= 0.3 else { return moved(pan, grip[24]!.x, grip[24]!.y) }  // a moment to get a grip
                let toss = (u - 0.3).truncatingRemainder(dividingBy: 1.2)
                var decals = [Decal(Props.pan, 27, toss < 0.12 ? 7 : 8)]  // the pan jerks up to throw
                if toss < 0.8 {
                    let p = toss / 0.8
                    let height = Int(4 * p * (1 - p) * 7)
                    decals.append(Int(p * 4) % 2 == 0 ? Decal(Props.pancakeFlat, 32, 7 - height)
                                                      : Decal(Props.pancakeEdge, 33, 6 - height))
                } else {
                    decals.append(Decal(Props.pancakeFlat, 32, 7))
                }
                return decals
            }
            return Pastime.sequence([hatOn, panOut, cooking, panAway, hatOff])!
        }

        return [pastime(clip(ClawdAssets.lookingAround, 4...30)), pastime(clip(ClawdAssets.swaying, 4...48)),
                pastime(dance), pastime(dance, dance), pastime(clip(ClawdAssets.hula, 6...53)), pastime(hop, hop),
                pastime(clip(ClawdAssets.excited, 2...21, fps: 14)), breakdance, think, nap, stroll, skydive,
                coffee, music, wizard, chef]
            .compactMap { $0 }
    }()

    /// The open book over Clawd's head while he dozes, rising and falling as he breathes: it drops onto
    /// his head in the first moments (`dropping`, time since it started to).
    private static func book(on sheet: PixelSheet, _ index: Int, dropping: TimeInterval) -> Decal {
        let pixels = sheet.frames[min(index, sheet.frames.count - 1)]
        let head = pixels.firstIndex { $0 != 255 }.map { $0 / sheet.width } ?? 0
        // From 4 px up, in a quarter of a second. (`dropping` may be infinite, which Int can't hold.)
        let fall = dropping < 0.25 ? 4 - Int(dropping * 16) : 0
        return Decal(Props.book, 2, head - Props.book.height + 1 - fall)
    }

    /// Pastimes are laid out over each stretch this long of the clock.
    private static let lifeStretch: TimeInterval = 10 * 60

    /// When Clawd lives in the notch for good: a pause of a few seconds, a pastime, another pause…
    /// Worked out from the clock, so he carries on unbroken from one session's rest to the next, or
    /// to the notch with nothing else in it. A pastime already under way when he came to rest
    /// (`restingSince`) is sat out: he'd show up in the middle of it.
    private func life(at date: Date, restingSince: Date) -> Frame {
        let now = date.timeIntervalSinceReferenceDate
        let stretch = (now / Self.lifeStretch).rounded(.down)
        var random = SeededRandom(seed: UInt64(stretch))
        var start = stretch * Self.lifeStretch
        let end = start + Self.lifeStretch
        var last = -1
        while !Self.pastimes.isEmpty {
            start += Double.random(in: 3...8, using: &random)
            // Never the same twice in a row.
            var pick = Int.random(in: 0..<Self.pastimes.count, using: &random)
            if pick == last { pick = (pick + 1) % Self.pastimes.count }
            last = pick
            let pastime = Self.pastimes[pick]
            guard start + pastime.duration <= end else { break }
            if now < start { return standing(until: start, now) }
            if now < start + pastime.duration {
                return start >= restingSince.timeIntervalSinceReferenceDate
                    ? pastime.frame(now - start).markedBusy() : standing(until: start + pastime.duration, now)
            }
            start += pastime.duration
        }
        return standing(until: end, now)
    }

    /// Standing still until `until`, in seconds of the clock as `now` is: the next look comes right
    /// then, so a pastime starts on time rather than up to half a second into it.
    private func standing(until: TimeInterval, _ now: TimeInterval) -> Frame {
        Frame(laptop, 0, rate: 1 / max(until - now, 1.0 / 16))
    }
}

/// The same seed gives the same numbers: each stretch of the clock always plays out the same way.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    /// SplitMix64.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
