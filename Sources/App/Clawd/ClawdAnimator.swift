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
    /// `offsetY` drops him from above (a parachute); `decals` are props drawn over him.
    struct Frame {
        let sheet: PixelSheet
        let index: Int
        var dozing: TimeInterval?
        var offsetX: CGFloat = 0
        var offsetY: CGFloat = 0
        var rate: Double = 16
        var mirrored = true
        var decals: [Decal] = []

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
        if let cue = session.cue, let reaction = Self.reactions[cue] {
            // Put the laptop away first.
            let putAway = exit(from: session.cueInterrupted)
            let lead = putAway?.duration ?? 0
            let t = date.timeIntervalSince(session.cueStart)
            if let putAway, t < lead { return Frame(putAway, at: t) }
            if t < lead + reaction.duration { return reaction.frame(t - lead) }
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
            let cycle = Array(3...16) + Array(repeating: 0, count: 10)  // wave, then a short pause
            return Frame(waving, cycle[Int(t * 12) % cycle.count], rate: 12)
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
            let index = doze.looped(at: asleep - sitDown.duration)
            return Frame(meditating, index, rate: 8, dozing: asleep,
                         decals: [Self.book(on: meditating, index, dropping: asleep - sitDown.duration)])
        }
        let window: TimeInterval = 30
        let n = Int(t / window)
        let intoFidget = t - Double(n) * window - 10  // starts 10 s into each window
        if !Self.fidgets.isEmpty, intoFidget >= 0 {
            let fidget = Self.fidgets[n % Self.fidgets.count]
            if intoFidget < fidget.duration { return Frame(fidget, at: intoFidget) }
        }
        return standing
    }

    private static let fidgets: [Clip] = [
        ClawdAssets.lookingAround.map { Clip(sheet: $0, frames: 4...30, fps: 12) },
        ClawdAssets.swaying.map { Clip(sheet: $0, frames: 4...48, fps: 12) },
        ClawdAssets.lookingAround.map { Clip(sheet: $0, frames: 4...30, fps: 12) },
        ClawdAssets.dancing.map { Clip(sheet: $0, frames: 4...38, fps: 12) },
        ClawdAssets.hula.map { Clip(sheet: $0, frames: 6...53, fps: 12) },
    ].compactMap { $0 }

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

        // Props from ClawdProps.swift, over his own frames. Nothing turns up out of thin air: props come from
        // out of sight above the screen, the notch being at its top edge, and go back there. All of them are
        // placed on the Pointing sheet: 0 stands (his head's top row at y 5, hands at x 0 and 23, y 9–12), 6
        // raises his arms, 7–14 hold them up (hands' top row at y 0), 15 brings them down to his head (y 1),
        // 16 squashes him as they come down to his sides, 17–18 turn him and 24 holds out his near arm.

        // Out of sight: the top row an item of this height needs for all of it to be above the screen's edge,
        // which is 10 px above the sheet in a 32-point notch and a few more in a taller one.
        func hidden(_ height: Int) -> Int { -16 - height }
        func lerp(_ from: Int, _ to: Int, _ p: Double) -> Int { from + Int((Double(to - from) * min(1, max(0, p))).rounded()) }
        func moved(_ decals: [Decal], _ dy: Int) -> [Decal] { decals.map { Decal($0.art, $0.x, $0.y + dy) } }

        // Reaching up for `art` and taking it down: it comes down into his raised hands at x `x` (its top
        // row at `overhead`), then he brings it down, to a place in each of the frames in `down`. And the
        // other way round, putting it back up there.
        func reach(_ sheet: PixelSheet, _ art: PixelArt, x: Int, overhead: Int,
                   down: [(Int, Decal)]) -> (take: Pastime, putBack: Pastime) {
            func armsUp(_ t: TimeInterval, _ y: Int) -> Frame {
                Frame(sheet, 7 + min(7, Int(t * 12)), rate: 16, decals: [Decal(art, x, y)])
            }
            let raise = Pastime(duration: 0.08) { _ in Frame(sheet, 6, rate: 12) }
            let steps = down.map { index, decal in Pastime(duration: 0.12) { _ in Frame(sheet, index, rate: 12, decals: [decal]) } }
            let take = Pastime.sequence([
                raise,
                // Arms up, and down it comes into his hands, slowing as it gets there.
                Pastime(duration: 0.6) { t in
                    let p = min(1, t / 0.45)
                    return armsUp(t, lerp(hidden(art.height), overhead, 1 - (1 - p) * (1 - p)))
                },
            ] + steps)!
            let putBack = Pastime.sequence(steps.reversed() + [
                // Arms up, and up it goes, slowly at first.
                Pastime(duration: 0.6) { t in
                    let p = max(0, t - 0.15) / 0.45
                    return armsUp(t, lerp(overhead, hidden(art.height), p * p))
                },
                raise,
            ])!
            return (take, putBack)
        }

        // With `hat` on (where it sits while he stands), he turns and holds out his near arm, and `holding`
        // drops into his hand from above; `act` gives what he holds for `seconds`; then he throws it back up
        // and turns back.
        func holdOut(_ sheet: PixelSheet, wearing hat: Decal, _ holding: [Decal], seconds: TimeInterval,
                     _ act: @escaping (TimeInterval) -> [Decal]) -> Pastime {
            func frame(_ index: Int, _ decals: [Decal] = []) -> Frame {
                // The hat sits a pixel lower while he's squashed.
                Frame(sheet, index, rate: 16, decals: moved([hat], index == 17 ? 1 : 0) + decals)
            }
            // How far up what he holds is out of sight, and how long it takes to fall from there.
            let away = hidden(0) - (holding.map { $0.y + $0.art.height }.max() ?? 0)
            let flight = Double(-away) / 60
            return Pastime.sequence([
                Pastime(duration: 0.08) { _ in frame(17) },
                Pastime(duration: 0.08) { _ in frame(18) },
                // Down it comes, and his hand gives a little as he catches it.
                Pastime(duration: flight) { t in frame(24, moved(holding, lerp(away, 0, t / flight))) },
                Pastime(duration: 0.1) { _ in frame(24, moved(holding, 1)) },
                Pastime(duration: seconds) { t in frame(24, act(t)) },
                // A flick of the wrist, and up it goes.
                Pastime(duration: 0.1) { _ in frame(24, moved(holding, -1)) },
                Pastime(duration: flight) { t in frame(24, moved(holding, lerp(-1, away, t / flight))) },
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

        // A mug of coffee from up there, brought down to his side: steam curls up from it, and twice he takes a
        // sip, eyes shut in a smile.
        let coffee = ClawdAssets.pointing.map { sheet in
            let mug = Props.mug
            let (take, putBack) = reach(sheet, mug, x: 8, overhead: -mug.height,
                                        down: [(15, Decal(mug, 17, 1 - mug.height)), (16, Decal(mug, 24, 9))])
            let drinking = Pastime(duration: 8) { t in
                let sip = (1.6..<3.0).contains(t) || (5.0..<6.4).contains(t)
                let decals = sip
                    ? [Decal(mug, 23, 6), Decal(Props.happyEyes, 5, 7)] + steam(t, x: 26, y: 5)
                    : [Decal(mug, 24, 8)] + steam(t, x: 27, y: 7)
                return Frame(sheet, 0, rate: 12, decals: decals)
            }
            return Pastime.sequence([take, drinking, putBack])!
        }

        // Headphones from up there, held by the band: on they go, and he nods to the beat with his eyes shut
        // while notes float off.
        let music = ClawdAssets.pointing.map { sheet in
            let phones = Props.headphones
            let (take, putBack) = reach(sheet, phones, x: 1, overhead: -1,
                                        down: [(15, Decal(phones, 1, -1)), (16, Decal(phones, 1, 4))])
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

        // A wizard's hat, and a wand that drops into his hand: sparkles fly off its star, and he winks.
        let wizard = ClawdAssets.pointing.map { sheet in
            let hat = Props.wizardHat
            let (take, putBack) = reach(sheet, hat, x: 2, overhead: -hat.height,
                                        down: [(15, Decal(hat, 2, 1 - hat.height)), (16, Decal(hat, 2, -4))])
            let wand = [Decal(Props.wand, 27, 4), Decal(Props.star, 30, 1)]
            let spots = [(34, 0), (33, 4), (29, -2), (35, 3), (32, -3), (36, 1)]
            let magic = holdOut(sheet, wearing: Decal(hat, 2, -5), wand, seconds: 4) { u in
                var decals = wand
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
            return Pastime.sequence([take, magic, putBack])!
        }

        // A chef's hat, and a frying pan with a pancake in it that drops into his hand: he tosses the
        // pancake, it turns over in the air and lands.
        let chef = ClawdAssets.pointing.map { sheet in
            let hat = Props.chefHat
            let (take, putBack) = reach(sheet, hat, x: 4, overhead: -hat.height,
                                        down: [(15, Decal(hat, 4, 1 - hat.height)), (16, Decal(hat, 4, -3))])
            let pan = [Decal(Props.pan, 27, 8), Decal(Props.pancakeFlat, 32, 7)]
            let cooking = holdOut(sheet, wearing: Decal(hat, 4, -4), pan, seconds: 3.9) { u in
                guard u >= 0.3 else { return pan }  // a moment to get a grip
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
            return Pastime.sequence([take, cooking, putBack])!
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
                    ? pastime.frame(now - start) : standing(until: start + pastime.duration, now)
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
