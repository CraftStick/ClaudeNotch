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
        /// At night: no nightcap on him in this frame (he's putting things away before he puts it on), or one
        /// all the same (he's closing the laptop before he takes it off).
        var hatless = false
        var capped = false

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

        func night(hatless: Bool = false, capped: Bool = false) -> Frame {
            var frame = self
            frame.hatless = frame.hatless || hatless
            frame.capped = frame.capped || capped
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
            // Put the laptop away first (the hat, or the box, back behind him before that).
            let interrupted = session.cueInterrupted
            let away = interrupted == .searching ? Self.hatOff : interrupted == .compacting ? Self.boxAway : interrupted == .cooking ? Self.potAway
                : session.motion != interrupted ? restInterrupted(interrupted, at: session.cueStart) ?? handedOver(at: session.cueStart) : nil
            let putAway = exit(from: interrupted)
            // At night the nightcap goes on as work starts, after he's put away what he had; and comes off
            // as it ends, after he's closed the laptop.
            let (capOn, capOff) = nightcap(from: interrupted, to: session.motion, at: session.cueStart)
            let t = date.timeIntervalSince(session.cueStart)
            var lead = 0.0
            for (part, tag) in [(away, 0), (putAway.map { clip in Pastime(duration: clip.duration) { Frame(clip, at: $0) } }, 0),
                                (capOff, 1), (capOn, 1)] {
                guard let part else { continue }
                if t < lead + part.duration {
                    let frame = part.frame(t - lead).markedBusy()
                    return tag == 1 ? frame : frame.night(hatless: capOn != nil, capped: capOff != nil)
                }
                lead += part.duration
            }
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
        // What he had beside him or on his head goes back behind him before he turns back to you; and what
        // he had in his hands or on him when his rest was cut short.
        let putAway = previous == motion ? nil : previous == .compacting ? Self.boxAway : previous == .searching ? Self.hatOff
            : previous == .cooking ? Self.potAway
            : t < 6 ? previous.flatMap { restInterrupted($0, at: session.motionStart) } ?? handedOver(at: session.motionStart)
            : nil  // (none takes that long)
        let (capOn, capOff) = previous.map { nightcap(from: $0, to: motion, at: session.motionStart) } ?? (nil, nil)
        if let putAway {
            if t < putAway.duration { return putAway.frame(t).night(hatless: capOn != nil, capped: capOff != nil) }
            t -= putAway.duration
        }
        if let previous, previous != motion, let exit = exit(from: previous) {
            if t < exit.duration { return Frame(exit, at: t).night(hatless: capOn != nil, capped: capOff != nil) }
            t -= exit.duration
        }
        for part in [capOff, capOn] {
            guard let part else { continue }
            if t < part.duration { return part.frame(t) }
            t -= part.duration
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
            if previous != .compacting, let aside = Self.turnAside, let out = Self.boxOut {
                if t < aside.duration { return Frame(aside, at: t) }
                t -= aside.duration
                if t < out.duration { return out.frame(t) }
                t -= out.duration
            }
            return box.frame(t.truncatingRemainder(dividingBy: box.duration))
        case .cooking:
            guard let stirring = Self.cooking else { return Frame(laptop, typingLoop.looped(at: t)) }
            if previous != .cooking, let aside = Self.turnAside, let out = Self.potOut {
                if t < aside.duration { return Frame(aside, at: t) }
                t -= aside.duration
                if t < out.duration { return out.frame(t) }
                t -= out.duration
            }
            return stirring.frame(t.truncatingRemainder(dividingBy: stirring.duration))
        case .limited:
            // Also after a reaction (nil): a rate limit often comes while the light bulb is still up.
            if let hourglass = Self.rateLimit {
                if t < hourglass.duration { return hourglass.frame(t) }
                t -= hourglass.duration
            }
            return Store.alive ? life(at: date, restingSince: date.addingTimeInterval(-t)) : idle(t, sinceRest: sinceMotion, at: date)
        case .done, .stopped, .failed:
            if previous != nil, let ending = ending(motion) {
                if t < ending.duration { return Frame(ending, at: t) }
                t -= ending.duration
            }
            return Store.alive ? life(at: date, restingSince: date.addingTimeInterval(-t)) : idle(t, sinceRest: sinceMotion, at: date)
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
        case .searching, .compacting, .cooking: return Self.turnBack  // turned aside: back to you
        // Sitting with a thought bubble: the bubble shrinks away as he gets up and turns back to you.
        case .pondering: return ClawdAssets.thinking.map { Clip(sheet: $0, frames: [21, 20, 3, 0], fps: 10) }
        // Sat down after waiting five minutes for you: up again. Waving before that: nothing to undo.
        case .waving where session.previousMotion == .waving && session.motionStart.timeIntervalSince(session.previousMotionStart) >= 300:
            return ClawdAssets.meditating.map { Clip(sheet: $0, frames: [46, 7, 6, 5, 4, 3], fps: 8) }
        default: return nil
        }
    }

    /// One-off reactions: an idea when a task comes in, joy when you allow something,
    /// a facepalm when a tool fails or you say no, confetti and a breakdance after a big task,
    /// coming in with a wave when the app is opened (a hop, up through the floor, a peek round the edge or
    /// skipping in), a parachute and a wave when he moves into the notch.
    /// Made once: Clawd's frame is worked out many times a second, and a session keeps its last cue
    /// long after it has played.
    static let reactions: [Cue: Pastime] = {
        func clip(_ sheet: PixelSheet?, _ frames: ClosedRange<Int>, fps: Double) -> Clip? {
            sheet.map { Clip(sheet: $0, frames: frames, fps: fps) }
        }
        let wave = clip(ClawdAssets.waving, 3...16, fps: 12)
        let all: [Cue: Pastime?] = [
            .hello: Pastime([ClawdAssets.jumping.map(hop), wave].compactMap { $0 }),
            .peekaboo: Pastime.sequence([peekaboo, Pastime([wave].compactMap { $0 })]),
            .peek: Pastime.sequence([peek, Pastime([wave].compactMap { $0 })]),
            .skip: Pastime.sequence([skip, Pastime([wave].compactMap { $0 })]),
            // Poked too often: his head spins, stars in his eyes.
            .dizzy: Pastime([clip(ClawdAssets.dizzy, 0...40, fps: 12)].compactMap { $0 }),
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

    /// Mostly standing still (breathing, blinking); every 30 s a little fidget; after `sleepAfter` reads a little,
    /// yawns and dozes under his book; at the very end of the rest gets up, puts the book away and walks off out
    /// of the notch.
    private func idle(_ t: TimeInterval, sinceRest: TimeInterval, at date: Date, restStart: Date? = nil) -> Frame {
        let leaveAt = Store.restDuration - Self.walkOff
        if sinceRest >= leaveAt, let walking = ClawdAssets.walking {
            let w = sinceRest - leaveAt
            return Frame(walking, Clip(sheet: walking, frames: 5...9, fps: 12).looped(at: w), rate: 16, offsetX: -CGFloat(w) * 14)
        }
        if sinceRest >= Self.sleepAfter, let start = Self.napStart, let end = Self.napEnd {
            let asleep = sinceRest - Self.sleepAfter
            let wakeAt = leaveAt - Self.sleepAfter - end.duration
            if asleep >= wakeAt { return end.frame(asleep - wakeAt) }
            if asleep < start.duration { return start.frame(asleep) }
            if let frame = Self.napping(asleep - start.duration) { return frame }
        }
        let window: TimeInterval = 30
        let n = Int(t / window)
        let intoFidget = t - Double(n) * window - 10  // starts 10 s into each window
        if !Self.fidgets.isEmpty, intoFidget >= 0 {
            let seed = UInt64(bitPattern: Int64((restStart ?? session.motionStart).timeIntervalSinceReferenceDate))
            let fidget = Self.fidgets[Self.pick(n, of: Self.fidgets.count, seed: seed)]
            if intoFidget < fidget.duration { return fidget.frame(intoFidget) }
        }
        // Standing still until the next fidget, or until he sits down or walks off: no look before then.
        let nextFidget = Double(intoFidget < 0 ? n : n + 1) * window + 10 - t
        let next = [nextFidget, Self.sleepAfter - sinceRest, Store.restDuration - Self.walkOff - sinceRest].filter { $0 > 0 }.min()
        let now = date.timeIntervalSinceReferenceDate
        return Self.alive(laptop, now, until: now + (next ?? 1))
    }

    private static let fidgets: [Pastime] = [
        ClawdAssets.lookingAround.flatMap { Pastime([Clip(sheet: $0, frames: 4...30, fps: 12)]) },
        ClawdAssets.swaying.flatMap { Pastime([Clip(sheet: $0, frames: 4...48, fps: 12)]) },
        ClawdAssets.dancing.flatMap { Pastime([Clip(sheet: $0, frames: 4...38, fps: 12)]) },
        hula,
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

        // Reads a little, yawns, sits down and dozes off for a while under the book on his head, gets back up
        // and puts it away.
        let nap = Pastime.sequence([napStart, napping(0).map { _ in
            Pastime(duration: 4 * Clip(sheet: ClawdAssets.meditating!, frames: 12...44, fps: 6).duration) { t in napping(t)! }
        }, napEnd])

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
        // Or back up through the floor, peeking in round the edge first, or skipping.
        let popUp = walkOff == nil || peekaboo == nil ? nil : Pastime.sequence([walkOff, away(3), peekaboo])
        let peekIn = walkOff == nil || peek == nil ? nil : Pastime.sequence([walkOff, away(2), peek])
        let skipIn = walkOff == nil || skip == nil ? nil : Pastime.sequence([walkOff, away(3), skip])

        // Props come out from behind his back and go back there: see "Props in his hands" below.


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
                pastime(dance), pastime(dance, dance), hula, pastime(hop, hop),
                pastime(clip(ClawdAssets.excited, 2...21, fps: 14)), breakdance, think, nap, stroll, skydive,
                popUp, peekIn, skipIn, coffee, music, wizard, chef]
            .compactMap { $0 }
    }()

    // MARK: - The nightcap

    /// The motions he wears his nightcap in at night: at work, waiting for you, not under a deerstalker.
    static let cappedMotions: Set<Motion> = [.typing, .pondering, .desktop, .running, .waving, .compacting, .cooking]

    /// At night, going from `previous` to `motion` at `date`: putting the nightcap on as work starts after a
    /// rest, or taking it off as it ends.
    private func nightcap(from previous: Motion, to motion: Motion, at date: Date) -> (on: Pastime?, off: Pastime?) {
        guard Calendar.current.component(.hour, from: date) < 6, previous != motion else { return (nil, nil) }
        // Off for a rest, a rate limit, or the deerstalker; on again after them.
        let bare: Set<Motion> = [.done, .stopped, .failed, .limited, .searching]
        if bare.contains(previous), Self.cappedMotions.contains(motion) { return (Self.nightcapOnAndOff?.on, nil) }
        if Self.cappedMotions.contains(previous), bare.contains(motion) { return (nil, Self.nightcapOnAndOff?.off) }
        return (nil, nil)
    }

    /// From behind his back, over his head and on; and off again, back there.
    static let nightcapOnAndOff: (on: Pastime, off: Pastime)? = ClawdAssets.pointing.map { sheet in
        let cap = Props.nightcap
        let (on, off) = headgear(sheet, cap, x: 4, tucked: 16 - cap.height, raising: 2 - cap.height, overhead: -cap.height,
                                 lowering: 1 - cap.height, worn: 6 - cap.height)
        return (on, off)
    }

    // MARK: - Cut short

    /// What he puts away when work cuts his rest short at `date`: whatever he had in his hands or on him
    /// then. Nil when `motion` isn't a rest, or he had nothing.
    private func restInterrupted(_ motion: Motion, at date: Date) -> Pastime? {
        guard [.done, .stopped, .failed].contains(motion), session.previousMotion == motion else { return nil }
        let start = session.previousMotionStart
        var t = max(0, date.timeIntervalSince(start))
        let sinceRest = t
        if let ending = ending(motion) {
            if t < ending.duration { return nil }  // the hop after a turn: nothing in hand
            t -= ending.duration
        }
        let frame = Store.alive ? life(at: date, restingSince: date.addingTimeInterval(-t))
                                : idle(t, sinceRest: sinceRest, at: date, restStart: start)
        return Self.putAway(after: frame)
    }

    /// What the Clawd this session's work took the notch from puts away, when work starts at `date`.
    private func handedOver(at date: Date) -> Pastime? {
        guard let handOff = session.handOff, abs(date.timeIntervalSince(handOff.at)) < 2 else { return nil }
        return Self.putAway(after: ClawdAnimator(session: handOff.from, laptop: laptop, waving: waving).frame(at: handOff.at))
    }

    /// Props he holds, wears or reads, as opposed to how he looks (eyes, a blush, sweat) or what floats by.
    private static let carried: Set<String> = [
        "mug", "teaMug", "wand", "wizardHat", "wizardHatTucked", "chefHat", "headphones", "headphonesFolded", "pan",
        "pancakeFlat", "pancakeEdge", "book", "bookClosed", "bookOpening", "bookFront", "broom", "grassSkirt",
        "grassSkirtFolded", "deerstalker", "magnifier", "gradCap", "gradCapTucked", "gradCapEdge", "gradCapUnder", "diploma",
    ]

    /// Putting away what's in `frame`: up from under his book and the book off over his head, the grass
    /// skirt off over his head, or anything else back behind his back.
    static func putAway(after frame: Frame) -> Pastime? {
        if frame.sheet.name == ClawdAssets.meditating?.name, frame.decals.contains(where: { $0.art == Props.book }) { return napEnd }
        if frame.sheet.name == ClawdAssets.hula?.name || frame.decals.contains(where: { $0.art.name == "grassSkirt" }) {
            return skirtOnAndOff?.off
        }
        let held = frame.decals.filter { carried.contains($0.art.name) }
        guard !held.isEmpty else { return nil }
        // Standing, his arms go behind his back with it; in any other pose it just slides in behind him.
        let pointing = frame.sheet.name == ClawdAssets.pointing?.name
        let sheet = pointing ? ClawdAssets.pointing! : frame.sheet, index = pointing ? 0 : frame.index
        let middle = sheet.width / 2
        return Pastime.sequence([
            Pastime(duration: 0.45) { t in
                let p = smooth(t / 0.45)
                let decals = held.map { d in
                    Decal(d.art, lerp(d.x, middle - d.art.width / 2, p), lerp(d.y, max(d.y, 6), p), p < 0.3 ? d.layer : .behind)
                }
                return Frame(sheet, index, rate: 16, decals: (pointing ? arms(left: lerp(4, 0, p), right: lerp(4, 0, p)) : []) + decals)
            },
            pointing ? Pastime(duration: 0.2) { t in Frame(sheet, 0, rate: 16, decals: arms(left: lerp(0, 4, t / 0.2), right: lerp(0, 4, t / 0.2))) } : nil,
        ])
    }

    // MARK: - Props in his hands

    // Props from ClawdProps.swift, over his own frames. Nothing turns up out of thin air: he takes a prop
    // out from behind his back, and puts it back there when he's done. All of them are placed on the
    // Pointing sheet: 0 stands (his head's top row at y 5, his body x 4–19 down to y 16, arms at x 0–3
    // and 20–23, y 9–12, cut away while a hand is behind his back), 6 raises his arms, 7–14 hold them up
    // (hands' top row at y 0), 15 brings them down to his head (y 1), 16 squashes him as they come down
    // to his sides, 17–18 turn him and 24 holds out his near arm.
    // His arms as far out as `left` and `right` pixels (4 being all of each): the rest is behind his back.
    static func arms(left: Int = 4, right: Int = 4) -> [Decal] {
        [Decal(Props.arm, -min(4, max(0, left)), 9, .cut), Decal(Props.arm, 20 + min(4, max(0, right)), 9, .cut)]
    }
    static func lerp(_ from: Int, _ to: Int, _ p: Double) -> Int { from + Int((Double(to - from) * min(1, max(0, p))).rounded()) }
    static func smooth(_ p: Double) -> Double { let p = min(1, max(0, p)); return p * p * (3 - 2 * p) }
    static func moved(_ decals: [Decal], _ dx: Int, _ dy: Int) -> [Decal] { decals.map { $0.moved(dx, dy) } }

    // Where his near hand holds things, just past its end at its top row: at his side (0), squashed
    // while turning (17), turned (18) and with the arm out (24).
    static let grip: [Int: (x: Int, y: Int)] = [0: (24, 9), 17: (23, 12), 18: (25, 8), 24: (27, 8)]

    // A hat or headphones: he puts both hands behind his back, lifts it up from there over his head, which
    // hides it until it's past, raises his arms to take it and puts it on; and the other way round, back
    // behind his back. `y` is its top row: `tucked` behind his back, `raising` in his hands as they go
    // up (6), `overhead` held up (7–14), `lowering` as they come down (15), and `worn` while he stands.
    // What's wider than him is `folded` while it's behind him, or it would show.
    static func headgear(_ sheet: PixelSheet, _ art: PixelArt, x: Int, folded: (art: PixelArt, x: Int)? = nil, tucked: Int,
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
    static func handHeld(_ sheet: PixelSheet, _ held: [Decal], wearing: [Decal] = []) -> (take: Pastime, putBack: Pastime) {
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
    // what he holds out for `seconds`, and turning back. The hat, if he wears one, sits a pixel lower while he's
    // squashed.
    static func holdOut(_ sheet: PixelSheet, _ held: [Decal], hat: Decal?, seconds: TimeInterval,
                 _ act: @escaping (TimeInterval) -> [Decal]) -> Pastime {
        func frame(_ index: Int, rate: Double = 12, _ decals: [Decal]? = nil) -> Frame {
            let hand = grip[index]!
            return Frame(sheet, index, rate: rate, decals: [hat?.moved(0, index == 17 ? 1 : 0)].compactMap { $0 } + (decals ?? moved(held, hand.x, hand.y)))
        }
        return Pastime.sequence([
            Pastime(duration: 0.08) { _ in frame(17) },
            Pastime(duration: 0.08) { _ in frame(18) },
            Pastime(duration: seconds) { t in frame(24, rate: 16, act(t)) },
            Pastime(duration: 0.08) { _ in frame(18) },
            Pastime(duration: 0.08) { _ in frame(17) },
        ])!
    }

    // MARK: - A nap with a book

    /// Before a nap: he takes a book out from behind his back, opens it in front of him in both hands (you
    /// see its cover) and reads, his eyes going along the lines; yawns; lifts it over his head, opens it on his head and sits
    /// down under it.
    static let napStart: Pastime? = ClawdAssets.pointing.flatMap { sheet in ClawdAssets.meditating.map { meditating in
        let side = grip[0]!
        let (bookOut, _) = handHeld(sheet, [Decal(Props.bookClosed, 0, -2)])
        // From his hand at his side to in front of him, then open in both hands.
        let toFront = Pastime(duration: 0.35) { t in
            let p = smooth(t / 0.35)
            return Frame(sheet, 0, rate: 16, decals: arms(right: lerp(4, 0, p))
                + [Decal(Props.bookClosed, lerp(side.x, 9, p), lerp(side.y - 2, 10, p))])
        }
        // Opened in both hands, its two halves spreading.
        let opening = Pastime(duration: 0.4) { t in
            let book = t < 0.15 ? Decal(Props.bookClosed, 9, 10) : t < 0.3 ? Decal(Props.bookOpening, 6, 10) : Decal(Props.bookFront, 3, 10)
            return Frame(sheet, 0, rate: 12, decals: arms(left: 0, right: 0) + [book, Decal(Props.eyesDown, 6, 7)])
        }
        func holding(_ eyes: PixelArt?, bookY: Int = 10) -> [Decal] {
            arms(left: 0, right: 0) + [Decal(Props.bookFront, 3, bookY)] + (eyes.map { [Decal($0, 5, 7)] } ?? [])
        }
        // Along a line from its start to its end, and back to the start of the next: four lines.
        let reading = Pastime(duration: 4.8) { t in
            let line = t.truncatingRemainder(dividingBy: 1.2)
            let eyes = line < 0.5 ? Props.eyesReadingStart : line < 0.9 ? Props.eyesDown : Props.eyesReadingEnd
            return Frame(sheet, 0, rate: 10, decals: holding(eyes))
        }
        // The book drops a little as he yawns over it.
        let yawn = Pastime(duration: 1.6) { t in
            let yawning = (0.2..<1.4).contains(t)
            return Frame(sheet, 0, rate: 8, decals: holding(nil, bookY: yawning ? 11 : 10)
                + (yawning ? Self.yawn(sheet, 0, wide: (0.45..<1.15).contains(t)) : [Decal(Props.eyesDown, 6, 7)]))
        }
        // Up over his head, open, and down onto it.
        let book = Props.book
        let onHead = Pastime.sequence([
            Pastime(duration: 0.08) { _ in Frame(sheet, 6, rate: 12, decals: [Decal(book, 2, 2 - book.height)]) },
            Pastime(duration: 0.3) { t in Frame(sheet, 7 + min(7, Int(t * 12)), rate: 12, decals: [Decal(book, 2, -book.height)]) },
            Pastime(duration: 0.12) { _ in Frame(sheet, 15, rate: 12, decals: [Decal(book, 2, 1 - book.height)]) },
            Pastime(duration: 0.12) { _ in Frame(sheet, 16, rate: 12, decals: [Decal(book, 2, 7 - book.height)]) },
            Pastime(duration: 0.3) { _ in Frame(sheet, 0, rate: 4, decals: [Decal(book, 2, 6 - book.height)]) },
        ])
        let sitDown = Clip(sheet: meditating, frames: 2...12, fps: 10)
        let sit = Pastime(duration: sitDown.duration) { t in
            let index = sitDown.frame(at: t)
            return Frame(meditating, index, rate: sitDown.fps, decals: [Self.book(on: meditating, index)])
        }
        return Pastime.sequence([bookOut, toFront, opening, reading, yawn, onHead, sit])!
    } }

    /// Dozing under the book, `t` into it: it rises and falls as he breathes.
    static func napping(_ t: TimeInterval) -> Frame? {
        ClawdAssets.meditating.map { sheet in
            let index = Clip(sheet: sheet, frames: 12...48, fps: 6).looped(at: t)
            return Frame(sheet, index, rate: 8, dozing: t, decals: [Self.book(on: sheet, index)])
        }
    }

    /// After a nap: he gets up with the book still on his head, then lifts it off over his head and puts it
    /// back behind his back.
    static let napEnd: Pastime? = ClawdAssets.pointing.flatMap { sheet in ClawdAssets.meditating.map { meditating in
        let wakeUp = Clip(sheet: meditating, frames: 45...59, fps: 10)
        let up = Pastime(duration: wakeUp.duration) { t in
            let index = wakeUp.frame(at: t)
            return Frame(meditating, index, rate: wakeUp.fps, decals: [Self.book(on: meditating, index)])
        }
        let book = Props.book
        let (_, offHead) = headgear(sheet, book, x: 2, folded: (Props.bookClosed, 10), tucked: 16 - Props.bookClosed.height,
                                    raising: 2 - book.height, overhead: -book.height, lowering: 1 - book.height, worn: 6 - book.height)
        let standing = Pastime(duration: 0.3) { _ in Frame(sheet, 0, rate: 4, decals: [Decal(book, 2, 6 - book.height)]) }
        return Pastime.sequence([up, standing, offHead])!
    } }

    // MARK: - The grass skirt

    /// The grass skirt from the Hula sheet's first frame, where he stands in it: cut out by its green and
    /// placed for the Pointing sheet, with both sheets' feet on the same spot. Its top row is `y`.
    static let skirt: (art: PixelArt, x: Int, y: Int)? = {
        guard let hula = ClawdAssets.hula, let pointing = ClawdAssets.pointing else { return nil }
        let pixels = hula.frames[0]
        var points: [(x: Int, y: Int, v: UInt8)] = []
        for y in 0..<hula.height {
            for x in 0..<hula.width {
                let v = pixels[y * hula.width + x]
                guard v != 255, Int(v) < hula.palette.count else { continue }
                let c = hula.palette[Int(v)]
                if c.g > c.r + 0.1, c.g > c.b { points.append((x, y, v)) }
            }
        }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        let used = Array(Set(points.map(\.v))).sorted()
        let letters = Array("abcdefghijklmnop")
        guard used.count <= letters.count else { return nil }
        var rows = Array(repeating: Array(repeating: Character("."), count: maxX - minX + 1), count: maxY - minY + 1)
        for p in points { rows[p.y - minY][p.x - minX] = letters[used.firstIndex(of: p.v)!] }
        var colors: [Character: UInt32] = [:]
        for (i, v) in used.enumerated() {
            let c = hula.palette[Int(v)]
            colors[letters[i]] = UInt32(c.r * 255) << 24 | UInt32(c.g * 255) << 16 | UInt32(c.b * 255) << 8 | 0xff
        }
        let art = PixelArt("grassSkirt", rows.map { String($0) }, colors)
        let dx = Int(pointing.anchor.x - hula.anchor.x), dy = Int(pointing.anchor.y - hula.anchor.y)
        return (art, minX + dx, minY + dy)
    }()

    /// The hula, skirt and all: he reaches behind his back for the grass skirt, lifts it over his head, pulls
    /// it down to his waist, dances, and takes it off over his head again, back behind him.
    static let hula: Pastime? = skirtOnAndOff.flatMap { onOff in ClawdAssets.hula.flatMap { hulaSheet in
        Pastime.sequence([onOff.on, Pastime([Clip(sheet: hulaSheet, frames: 0...53, fps: 12)]), onOff.off])
    } }

    /// Putting the skirt on (from behind his back, over his head, down to his waist), and taking it off.
    static let skirtOnAndOff: (on: Pastime, off: Pastime)? = ClawdAssets.pointing.flatMap { sheet in skirt.map { skirt in
        let art = skirt.art
        // Behind him it's folded in to his body's width (x 4–19), or its ends would show.
        let inset = max(0, 4 - skirt.x)
        let foldedWidth = min(art.width - inset, 16)
        let folded = PixelArt("grassSkirtFolded", (0..<art.height).map { y in
            String((0..<foldedWidth).map { x in art.rgba[(y * art.width + x + inset) * 4 + 3] > 0 ? "x" : "." })
        }, ["x": 0x5a_8a_3a_ff])
        let onHead = 6 - art.height
        let (lift, lower) = headgear(sheet, art, x: skirt.x, folded: (folded, skirt.x + inset), tucked: 16 - art.height,
                                     raising: 2 - art.height, overhead: -art.height, lowering: 1 - art.height, worn: onHead)
        // Down over his face to his waist, and up again.
        func pull(from: Int, to: Int) -> Pastime {
            Pastime(duration: 0.5) { t in
                Frame(sheet, 0, rate: 16, decals: [Decal(art, skirt.x, lerp(from, to, smooth(t / 0.5)))])
            }
        }
        return (Pastime.sequence([lift, pull(from: onHead + 1, to: skirt.y)])!, Pastime.sequence([pull(from: skirt.y, to: onHead + 1), lower])!)
    } }

    /// The open book on Clawd's head while he sits under it, rising and falling as he breathes.
    private static func book(on sheet: PixelSheet, _ index: Int) -> Decal {
        let pixels = sheet.frames[min(index, sheet.frames.count - 1)]
        let head = pixels.firstIndex { $0 != 255 }.map { $0 / sheet.width } ?? 0
        return Decal(Props.book, 2, head - Props.book.height + 1)
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
        var recent: [Int] = []
        while !Self.pastimes.isEmpty {
            start += Double.random(in: 3...8, using: &random)
            let pick = Self.nextPastime(after: &recent, of: Self.pastimes.count, using: &random)
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

    /// How many pastimes go by before one comes back.
    static let pastimeGap = 6

    /// Which pastime comes next: any of `count`, in no set order, but none of the last `pastimeGap`
    /// (`recent`, which it adds to), so the same few don't keep coming back.
    static func nextPastime(after recent: inout [Int], of count: Int, using random: inout SeededRandom) -> Int {
        let free = (0..<count).filter { !recent.contains($0) }
        let pick = free.randomElement(using: &random) ?? Int.random(in: 0..<count, using: &random)
        recent = Array((recent + [pick]).suffix(min(pastimeGap, count - 1)))
        return pick
    }

    /// Standing still until `until`, in seconds of the clock as `now` is: the next look comes right
    /// then, so a pastime starts on time rather than up to half a second into it.
    private func standing(until: TimeInterval, _ now: TimeInterval) -> Frame {
        Self.alive(laptop, now, until: until)
    }

    // MARK: - Standing still

    /// What his eyes do while he stands: open, shut for a blink, glancing a pixel aside, or up.
    enum Eyes: Equatable { case open, shut, aside(Int), up }

    /// One breath: in for the first half, out (`exhaled`) for the second.
    static let breath: TimeInterval = 4
    private static let blinkSlot: TimeInterval = 4.5
    private static let glanceSlot: TimeInterval = 11

    /// Still, but alive: he breathes, blinks every few seconds (now and then twice), and once in a while
    /// glances aside or up. From the clock alone, like his life in the notch, so it plays out the same
    /// however often he's drawn; and he's drawn again only when something changes, or at `until`.
    static func alive(_ laptop: PixelSheet, _ now: TimeInterval, until: TimeInterval) -> Frame {
        let state = liveliness(at: now)
        let sheet = state.exhaled ? (exhaled ?? laptop) : laptop
        let down = sheet.name == laptop.name ? 0 : 1  // breathing out his head sinks a pixel
        // Laptop 0: eyes at x 6–7 and 16–17, y 9–10.
        var decals: [Decal] = []
        switch state.eyes {
        case .open: break
        case .shut: decals = [Decal(Props.closedEyes, 5, 9 + down)]
        case .aside(let dx): decals = [Decal(dx > 0 ? Props.eyesAsideNear : Props.eyesAsideFar, 5, 9 + down)]
        case .up: decals = [Decal(Props.eyesUp, 6, 9 + down)]
        }
        let next = min(state.next, until)
        return Frame(sheet, 0, rate: 1 / max(next - now, 1.0 / 16), decals: decals)
    }

    /// How he breathes and where he looks at `now`, and when that next changes.
    static func liveliness(at now: TimeInterval) -> (exhaled: Bool, eyes: Eyes, next: TimeInterval) {
        let half = breath / 2
        var changes = [((now / half).rounded(.down) + 1) * half]
        let exhaled = now.truncatingRemainder(dividingBy: breath) >= half

        var eyes = Eyes.open
        let glance = (now / glanceSlot).rounded(.down)
        for slot in [glance, glance + 1] {
            var random = SeededRandom(seed: UInt64(slot) &* 0x9E37 ^ 0x6C61)
            guard Double.random(in: 0..<1, using: &random) < 0.45 else { continue }
            let start = slot * glanceSlot + Double.random(in: 1...6, using: &random)
            let end = start + Double.random(in: 1.2...2.4, using: &random)
            let look: Eyes = [.aside(-1), .aside(1), .up][Int.random(in: 0..<3, using: &random)]
            if (start..<end).contains(now) { eyes = look }
            changes += [start, end]
        }
        let blink = (now / blinkSlot).rounded(.down)
        for slot in [blink, blink + 1] {
            var random = SeededRandom(seed: UInt64(slot) &* 0x9E37 ^ 0x626C)
            let at = slot * blinkSlot + Double.random(in: 0.3...3.8, using: &random)
            var shut = [at]
            if Double.random(in: 0..<1, using: &random) < 0.25 { shut.append(at + 0.35) }  // a double blink
            for start in shut {
                if (start..<(start + 0.15)).contains(now) { eyes = .shut }
                changes += [start, start + 0.15]
            }
        }
        return (exhaled, eyes, changes.filter { $0 > now }.min() ?? now + 1)
    }

    /// The standing frame breathed out: everything above his legs a pixel lower, on legs a pixel shorter.
    static let exhaled: PixelSheet? = ClawdAssets.laptop.flatMap { sheet in
        let pixels = sheet.frames[0], w = sheet.width
        func row(_ y: Int) -> ArraySlice<UInt8> { pixels[(y * w)..<((y + 1) * w)] }
        // The legs: the rows at the bottom that are all like the last one.
        var legs = sheet.height - 1
        while legs > 0, row(legs - 1) == row(sheet.height - 1) { legs -= 1 }
        guard legs > 0 else { return nil }  // a frame all of one row: nothing to breathe
        var out = [UInt8](repeating: 255, count: pixels.count)
        for y in 1...legs { out.replaceSubrange((y * w)..<((y + 1) * w), with: row(y - 1)) }
        for y in (legs + 1)..<sheet.height { out.replaceSubrange((y * w)..<((y + 1) * w), with: row(y)) }
        return PixelSheet(name: sheet.name + "-exhaled", width: w, height: sheet.height, palette: sheet.palette,
                          frames: [out], anchor: sheet.anchor)
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
