import CoreGraphics
import Foundation

/// How Clawd takes what happens at work, beyond typing and waving: packing papers into a box while
/// the context is compacted, an hourglass at a rate limit, a "?" when auto mode turns something down,
/// head in his hands after a few failures in a row, a sparkler for passing tests, a rocket for a push;
/// and, over whatever he does, a drop of sweat as the context fills up, getting impatient while he
/// waits for you, a yawn late at night.
extension ClawdAnimator {
    // MARK: Motions

    /// Turned to what's beside him, the way he sits at the laptop: three-quarter, his back in shadow
    /// (Turning 6–10). His body x 4–19 (in shadow x 4–6) from y 1 down to the ground at y 16, eyes at
    /// x 9–10 and 17–18, y 3–4, arms at y 5–8 out to x 0 and x 22.
    static func turned(rate: Double, offsetX: CGFloat = 0, offsetY: CGFloat = 0, decals: [Decal]) -> Frame? {
        ClawdAssets.turning.map { Frame($0, 8, rate: rate, offsetX: offsetX, offsetY: offsetY, decals: decals) }
    }

    /// Turning from you to what's beside him, and back.
    static let turnAside = ClawdAssets.turning.map { Clip(sheet: $0, frames: [4, 5], fps: 12) }
    static let turnBack = ClawdAssets.turning.map { Clip(sheet: $0, frames: [5, 4, 0], fps: 12) }

    /// Compacting: two sheets of paper tumble in an arc from his hand into the box beside him, which he
    /// watches; the lid flaps shut with a puff of dust and he gives it a satisfied squash. Loops while
    /// Claude compacts.
    static let compacting: Pastime? = ClawdAssets.turning.map { _ in
        Pastime(duration: 3.2) { t in
            var decals: [Decal] = []
            let shut = (1.55..<3.0).contains(t)
            decals.append(Decal(shut ? Props.boxShut : Props.box, 25, 9))
            // Each sheet: from his hand (23, 5) up over his shoulder and down into the box (28, 10).
            for start in [0.0, 0.55] where (start..<(start + 0.9)).contains(t) {
                let p = (t - start) / 0.9
                let x = 23 + Int((28 - 23) * p)
                let y = 5 - Int(4 * p * (1 - p) * 10) + Int(5 * p)
                decals.append(Decal(Int(t / 0.15) % 2 == 0 ? Props.paper : Props.paperTumbling, x, y))
            }
            // Dust out from under the lid as it shuts, spreading and fading.
            if (1.6..<1.85).contains(t) { decals += [Decal(Props.puff, 23, 14), Decal(Props.puff, 35, 14)] }
            if (1.85..<2.2).contains(t) { decals += [Decal(Props.puffWide, 21, 13), Decal(Props.puffWide, 35, 13)] }
            let squash = (1.6..<1.95).contains(t)
            if squash {
                decals.append(Decal(Props.happyEyesTurned, 8, 3))
            } else if t < 1.55 {
                decals.append(Decal(Props.eyesDownTurned, 9, 3))  // watching his papers go in
            }
            return turned(rate: 12, offsetY: squash ? 1 : 0, decals: decals)!
        }
    }

    /// What stands beside him on the ground comes out from behind him, and goes back there: `decal` slid
    /// along from inside his body (turned, x 4–19) to where it stands, `p` of the way (0…1). Behind him it
    /// shows only where he isn't.
    static func fromBehind(_ decal: Decal, _ p: Double) -> Decal {
        Decal(decal.art, lerp(6, decal.x, smooth(p)), decal.y, .behind)
    }

    /// The box for compacting, pushed out from behind him once he's turned to it; and back when he's done.
    static let boxOut: Pastime? = ClawdAssets.turning.map { _ in
        Pastime(duration: 0.4) { t in turned(rate: 16, decals: [fromBehind(Decal(Props.box, 25, 9), t / 0.4)])! }
    }
    static let boxAway: Pastime? = ClawdAssets.turning.map { _ in
        Pastime(duration: 0.4) { t in turned(rate: 16, decals: [fromBehind(Decal(Props.boxShut, 25, 9), 1 - t / 0.4)])! }
    }

    /// A rate limit: he turns to an hourglass beside him, eyes on it, while its sand runs down; once it's
    /// all through he blinks and turns back to you.
    static let rateLimit: Pastime? = turnAside.flatMap { aside in turnBack.map { back in
        Pastime(duration: aside.duration + 0.4 + 8 + 0.4 + back.duration) { t in
            let glass = { (level: Int, running: Bool) in Decal(Props.hourglass(level, running: running), 25, 6) }
            if t < aside.duration { return Frame(aside, at: t) }
            // Out from behind him first, and back there before he turns back.
            if t < aside.duration + 0.4 { return turned(rate: 16, decals: [fromBehind(glass(0, false), (t - aside.duration) / 0.4)])! }
            let u = t - aside.duration - 0.4
            if (8..<8.4).contains(u) { return turned(rate: 16, decals: [fromBehind(glass(9, false), 1 - (u - 8) / 0.4)])! }
            guard u < 8 else {
                return Frame(back, at: u - 8.4)
            }
            let running = u < 7
            let level = running ? Int(u / 7 * 9) : 9
            var decals = [glass(level, running && Int(u * 8) % 2 == 0)]
            let blink = u.truncatingRemainder(dividingBy: 2.6) > 2.45 || (7.3..<7.45).contains(u)
            decals.append(blink ? Decal(Props.closedEyesTurned, 9, 3) : Decal(Props.eyesDownTurned, 9, 3))
            if !running, !blink { decals.removeLast() }  // done: back to looking straight ahead
            return turned(rate: 8, decals: decals)!
        }
    } }

    /// Searching (code, files, the web): in a deerstalker, turned aside, he peers through a magnifying
    /// glass with one eye narrowed, moving it about and edging along as he looks. Loops.
    static let searching: Pastime? = ClawdAssets.turning.map { _ in
        Pastime(duration: 2.4) { t in
            let spots = [(19, -1), (20, -1), (20, 0), (19, 0)]
            let spot = spots[Int(t / 0.6) % spots.count]
            return turned(rate: 8, offsetX: t < 1.2 ? 0 : 1,
                          decals: [Decal(Props.deerstalker, 2, -6), Decal(Props.squint, 17, 3), Decal(Props.magnifier, spot.0, spot.1)])!
        }
    }

    /// Putting the hat on, before the first look: lifted from behind his head, up over it, and down onto it,
    /// as he turns aside; then the magnifying glass out from behind him. Nil once both are out.
    static func hatOn(_ t: TimeInterval) -> Frame? {
        guard t < 0.8, let aside = turnAside else { return nil }
        let hat = deerstalkerLifted(t / 0.5)
        guard t >= aside.duration else {
            // Facing you, his head's top row is where it is when he's turned.
            var frame = Frame(aside, at: t)
            frame.decals = [hat]
            return frame
        }
        return turned(rate: 16, decals: [hat] + (t < 0.5 ? [] : [fromBehind(Decal(Props.magnifier, 19, -1), (t - 0.5) / 0.3)]))
    }

    /// Done searching: the magnifying glass goes back behind him, and the hat comes off, up and back down
    /// behind his head, before he turns back to you.
    static let hatOff: Pastime? = ClawdAssets.turning.map { _ in
        Pastime(duration: 0.8) { t in
            turned(rate: 16, decals: t < 0.3 ? [Decal(Props.deerstalker, 2, -6), fromBehind(Decal(Props.magnifier, 19, -1), 1 - t / 0.3)]
                                             : [deerstalkerLifted(1 - (t - 0.3) / 0.5)])!
        }
    }

    /// The deerstalker `p` of the way on (0…1): from behind his head (its brim at his eyes) up till it's clear
    /// of his head, then down onto it.
    private static func deerstalkerLifted(_ p: Double) -> Decal {
        if p < 0.6 { return Decal(Props.deerstalker, 2, lerp(3, -9, smooth(p / 0.6)), p < 0.45 ? .behind : .front) }
        return Decal(Props.deerstalker, 2, lerp(-9, -6, smooth((p - 0.6) / 0.4)))
    }

    /// Waiting for you a long while: after a minute he looks around for you between waves; after five
    /// he sits down to wait, blinking. Nil while it's still just waving.
    static func waitingLong(_ t: TimeInterval) -> Frame? {
        if t >= 300, let sheet = ClawdAssets.meditating {
            let sitting = t - 300
            let sitDown = Clip(sheet: sheet, frames: [3, 4, 5, 6, 7, 46], fps: 8)
            if sitting < sitDown.duration { return Frame(sitDown, at: sitting) }
            let blink = sitting.truncatingRemainder(dividingBy: 4) < 0.15
            return Frame(sheet, blink ? 45 : 46, rate: blink ? 8 : 1 / 3.8)
        }
        if t >= 60, let sheet = ClawdAssets.lookingAround {
            let look = Clip(sheet: sheet, frames: 4...30, fps: 12)
            let c = (t - 60).truncatingRemainder(dividingBy: 12)
            if c < look.duration { return Frame(look, at: c) }
        }
        return nil
    }

    // MARK: Cues

    /// The reactions that go with the moods, added to `reactions`.
    static let moodReactions: [Cue: Pastime] = {
        var all: [Cue: Pastime?] = [:]
        // Head in his hands: the third failure in a row.
        all[.despair] = ClawdAssets.disappointed.flatMap { Pastime([Clip(sheet: $0, frames: 2...42, fps: 12)]) }
        // Tests passed: a sparkler, held up and waved about.
        all[.sparkler] = ClawdAssets.spark.flatMap { Pastime([Clip(sheet: $0, frames: 0...72, fps: 12)]) }
        // Auto mode turned something down: not a failure. A "?" pops up over his head and he looks up at
        // it with a little shrug, twice.
        all[.shrug] = ClawdAssets.pointing.map { sheet in
            Pastime(duration: 2.6) { t in
                guard t > 0.1 else { return Frame(sheet, 0, rate: 12) }
                let pop = t < 0.3 ? 2 : 0  // springs up into place
                let bob = Int((sin(t * 5) * 0.8).rounded())
                let shrug = (0.5..<0.75).contains(t) || (1.1..<1.35).contains(t)
                return Frame(sheet, 0, rate: 12, offsetY: shrug ? -1 : 0,
                             decals: [Decal(Props.question, 12, -4 + pop + bob), Decal(Props.eyesUp, 6, 7)])
            }
        }
        // Pushed: with a launch button in his hand he presses it, the rocket beside him lights up, shakes
        // in a spray of sparks and smoke and shoots off, his eyes following it up; then he's delighted.
        all[.rocket] = turnAside.flatMap { aside in
            let launch = Pastime(duration: 2.4) { t in
                var decals: [Decal] = []
                let lit = t >= 0.45
                let lift = t < 1.0 ? 0 : Int(pow((t - 1.0) * 5, 2))
                let shake = lit && lift == 0 ? (Int(t * 20) % 2 == 0 ? 1 : 0) : 0
                let y = 2 - lift
                decals.append(Decal(Props.rocket, 27 + shake, y))
                if lit {
                    let flicker = Int(t * 14) % 2 == 0
                    decals.append(Decal(flicker || lift > 0 ? Props.flameLong : Props.flame, 30 + shake, y + 11))
                    // Sparks thrown out round the flame, somewhere new each frame.
                    var random = SeededRandom(seed: UInt64(t * 14))
                    for _ in 0..<5 {
                        let sparkY = y + 12 + Int.random(in: 0...4, using: &random)
                        let sparkX = 28 + Int.random(in: 0...6, using: &random) + shake
                        if sparkY <= 16 { decals.append(Decal(Props.spark, sparkX, sparkY)) }  // not under the ground
                    }
                }
                // Smoke at the pad, spreading out as it goes.
                if (0.5..<1.2).contains(t) { decals += [Decal(Props.puff, 26, 14), Decal(Props.puff, 34, 14)] }
                if (1.2..<1.9).contains(t) { decals += [Decal(Props.puffWide, 24, 13), Decal(Props.puffWide, 34, 13)] }
                let pressing = (0.4..<0.65).contains(t)
                decals.append(Decal(pressing || lit ? Props.remotePressed : Props.remote, 21, 5))
                if t >= 1.0 { decals.append(Decal(Props.eyesUpTurned, 9, 2)) }
                return turned(rate: 14, offsetY: pressing ? 1 : 0, decals: decals)!
            }
            // He turns aside, then the rocket comes out from behind him and the button into his hand.
            let turnIn = Pastime.sequence([
                Pastime([aside]),
                Pastime(duration: 0.5) { t in
                    turned(rate: 16, decals: [fromBehind(Decal(Props.rocket, 27, 2), t / 0.5),
                                              fromBehind(Decal(Props.remote, 21, 5), min(1, t / 0.35))])!
                },
            ])
            let joy = ClawdAssets.excited.flatMap { Pastime([Clip(sheet: $0, frames: 2...21, fps: 14)]) }
            // The button back behind him, then he's delighted.
            let buttonAway = Pastime(duration: 0.35) { t in
                turned(rate: 16, decals: [fromBehind(Decal(Props.remote, 21, 5), 1 - t / 0.35)])!
            }
            return Pastime.sequence([turnIn, launch, buttonAway, joy])
        }
        // You said thanks: he goes shy, eyes smiling and cheeks pink, rocking a little, while a heart rises
        // over his head and a small one after it.
        all[.thanks] = ClawdAssets.pointing.map { sheet in
            Pastime(duration: 2.8) { t in
                guard t > 0.1 else { return Frame(sheet, 0, rate: 12) }
                var decals = [Decal(Props.happyEyes, 5, 7), Decal(Props.blush, 5, 9)]
                let rise = { (start: Double) -> Int? in t >= start ? -1 - Int((t - start) * 3.2) : nil }
                if let y = rise(0.25) { decals.append(Decal(t < 2.2 ? Props.heart : Props.heartFading, 8, y)) }
                if let y = rise(1.1), t < 2.5 { decals.append(Decal(Props.smallHeart, 15, y + 2)) }
                let rock = Int((sin(t * 6) * 1.2).rounded())
                return Frame(sheet, 0, rate: 12, offsetX: CGFloat(rock), decals: decals)
            }
        }
        // Spoken to rudely: he flinches back with his eyes squeezed shut, then hunches, eyes down, a drop
        // of sweat running down his head.
        all[.flinch] = ClawdAssets.pointing.map { sheet in
            Pastime(duration: 2.6) { t in
                if t < 0.08 { return Frame(sheet, 0, rate: 12) }
                if t < 0.7 {
                    let jolt = t < 0.2
                    return Frame(sheet, 0, rate: 12, offsetX: jolt ? 2 : 1, offsetY: 1, decals: [Decal(Props.squeezedEyes, 5, 6)])
                }
                let p = ((t - 0.7) / 1.4).truncatingRemainder(dividingBy: 1)
                var decals = [Decal(Props.eyesDown, 6, 7)]
                if p < 0.85 { decals.append(Decal(Props.sweat, 1, 4 + Int(p * 5))) }
                return Frame(sheet, 0, rate: 10, offsetX: 1, offsetY: 1, decals: decals)
            }
        }
        // It works after a run of failures: eyes shut, he sags with a long breath out, shakes a drop of
        // sweat off, and perks up, smiling.
        all[.phew] = ClawdAssets.pointing.map { sheet in
            Pastime(duration: 2.6) { t in
                if t < 0.1 { return Frame(sheet, 0, rate: 12) }
                if t < 1.3 {
                    var decals = [Decal(Props.closedEyes, 5, 7)]
                    if (0.35..<1.3).contains(t) { decals.append(Decal(t < 0.95 ? Props.breath : Props.breathFading, 24 + Int((t - 0.35) * 4), 8)) }
                    return Frame(sheet, 0, rate: 12, offsetY: t > 0.35 ? 1 : 0, decals: decals)
                }
                var decals = [Decal(Props.happyEyes, 5, 7)]
                if t < 1.8 {  // the drop flies off behind him
                    let p = (t - 1.3) / 0.5
                    decals.append(Decal(Props.sweat, 2 - Int(p * 6), 4 - Int(4 * p * (1 - p) * 3) + Int(p * 3)))
                }
                let shake = t < 1.6 ? (Int(t * 20) % 2 == 0 ? 1 : -1) : 0
                return Frame(sheet, 0, rate: 14, offsetX: CGFloat(shake), offsetY: (2.0..<2.25).contains(t) ? -1 : 0, decals: decals)
            }
        }
        // A big change (300+ lines): he stands tall, smiling, bobbing proudly, with sparkles twinkling round him.
        all[.proud] = ClawdAssets.pointing.map { sheet in
            Pastime(duration: 2.6) { t in
                guard t > 0.1 else { return Frame(sheet, 0, rate: 12) }
                var decals = [Decal(Props.happyEyes, 5, 7)]
                let spots = [(-2, 3), (24, 1), (26, 12), (-4, 14), (11, -1)]
                for (i, spot) in spots.enumerated() {
                    let phase = (t * 2.5 + Double(i) * 0.37).truncatingRemainder(dividingBy: 1)
                    if phase < 0.35 { decals.append(Decal(Props.bigSparkle, spot.0, spot.1)) }
                    else if phase < 0.6 { decals.append(Decal(Props.sparkle, spot.0 + 1, spot.1 + 1)) }
                }
                let bob = Int(t * 3) % 2 == 0 ? -1 : 0
                return Frame(sheet, 0, rate: 12, offsetY: CGFloat(bob), decals: decals)
            }
        }
        // More taken out than put in: a tidy-up. With a broom he sweeps in front of him, dust flying, eyes on
        // the floor; then a glint where it's clean, and he's pleased.
        all[.sweep] = ClawdAssets.pointing.flatMap { sheet in
            let side = grip[0]!
            let (broomOut, broomAway) = handHeld(sheet, [Decal(Props.broom, 19 - side.x, 7 - side.y)])
            let sweeping = Pastime(duration: 3.0) { t in
                if t < 2.2 {
                    let stroke = Int(t * 5) % 2  // back and forth
                    var decals = [Decal(Props.broom, 19 + stroke * 2, 7), Decal(Props.eyesDown, 6, 7)]
                    let dust = (t * 5).truncatingRemainder(dividingBy: 1)
                    if stroke == 1, dust < 0.6 { decals.append(Decal(dust < 0.3 ? Props.puff : Props.puffWide, 27 + Int(dust * 6), 18 - Int(dust * 3))) }
                    return Frame(sheet, 0, rate: 10, decals: decals)
                }
                var decals = [Decal(Props.broom, 19, 7), Decal(Props.happyEyes, 5, 7)]
                if t < 2.7 { decals.append(Decal(Int(t * 8) % 2 == 0 ? Props.bigSparkle : Props.sparkle, 29, 16)) }
                return Frame(sheet, 0, rate: 8, decals: decals)
            }
            return Pastime.sequence([broomOut, sweeping, broomAway])
        }
        // A huge output or file: eyes wide, a "!" pops up, and he jumps back a step, then edges in again.
        all[.surprise] = ClawdAssets.pointing.map { sheet in
            Pastime(duration: 1.9) { t in
                if t < 0.06 { return Frame(sheet, 0, rate: 12) }
                let pop = t < 0.2 ? 2 : 0
                let back = t < 0.5 ? 2 : (t < 1.2 ? 1 : 0)
                var decals = [Decal(Props.wideEyes, 5, 6)]
                if t < 1.5 { decals.append(Decal(Props.exclamation, 11, -5 + pop)) }
                return Frame(sheet, 0, rate: 12, offsetX: CGFloat(back), offsetY: t < 0.2 ? -1 : 0, decals: decals)
            }
        }
        // You allowed something: a thumb up and a wink, with a glint on the thumb.
        all[.thumbs] = ClawdAssets.pointing.map { sheet in
            Pastime(duration: 1.8) { t in
                guard t > 0.08 else { return Frame(sheet, 0, rate: 12) }
                let rise = t < 0.2 ? 2 : 0
                var decals = [Decal(Props.thumbUp, 21, 3 + rise)]
                if (0.35..<1.4).contains(t) { decals.append(Decal(Props.winkShut, 16, 7)) }
                if (0.3..<0.6).contains(t) { decals.append(Decal(t < 0.45 ? Props.bigSparkle : Props.sparkle, 24, 1)) }
                return Frame(sheet, 0, rate: 12, offsetY: (0.9..<1.1).contains(t) ? -1 : 0, decals: decals)
            }
        }
        // The first task of the day: he stretches, arms up high, with a big yawn, and lowers them again.
        all[.stretch] = ClawdAssets.pointing.map { sheet in
            let up = Clip(sheet: sheet, frames: 3...10, fps: 12), down = Clip(sheet: sheet, frames: [10, 9, 8, 7, 6, 5, 4, 3, 0], fps: 14)
            return Pastime(duration: up.duration + 1.6 + down.duration) { t in
                if t < up.duration { return Frame(up, at: t) }
                let held = t - up.duration
                if held < 1.6 {
                    return Frame(sheet, 10, rate: 8, offsetY: held < 1.2 ? -1 : 0,
                                 decals: yawn(sheet, 10, wide: (0.3..<1.2).contains(held)))
                }
                return Frame(down, at: held - 1.6)
            }
        }
        return all.compactMapValues { $0 }
    }()

    // MARK: Over what he does

    /// While Claude works: a drop of sweat from 85% of the context, and a little sway from 95%; a yawn
    /// now and then at the laptop between 1 and 5 at night; a yawn every 25 s while a command runs for over a
    /// minute. After midnight, till 6, a nightcap at work, and tea instead of coffee.
    func mood(_ frame: Frame, at date: Date) -> Frame {
        let hour = Calendar.current.component(.hour, from: date)
        var frame = frame
        if hour < 6 {
            frame.decals = frame.decals.map { $0.art == Props.mug ? Decal(Props.teaMug, $0.x, $0.y, $0.layer) : $0 }
        }
        let wearing = frame.decals.contains { $0.art.name.hasPrefix("nightcap") }  // putting it on, or taking it off
        if hour < 6, !frame.hatless, !wearing,
           frame.capped || (session.phase.isActive && Self.cappedMotions.contains(session.motion)),
           let head = Self.head(frame.sheet, frame.index) {
            // Thinking, his bubble is up where the tip would droop.
            frame.decals.append(Decal(session.motion == .pondering ? Props.nightcapOtherWay : Props.nightcap, head.x, head.y - 4))
        }
        guard session.phase.isActive, [.typing, .pondering, .desktop, .running, .searching].contains(session.motion) else { return frame }
        let t = date.timeIntervalSince(session.motionStart)
        let full = session.contextWindow > 0 ? Double(session.contextTokens) / Double(session.contextWindow) : 0
        if full >= 0.85, let head = Self.head(frame.sheet, frame.index) {
            // Gathers at his temple, runs down and is gone; then the next one.
            let p = (t / 1.6).truncatingRemainder(dividingBy: 1)
            if p < 0.85 { frame.decals.append(Decal(Props.sweat, head.x - 3, head.y + 1 + Int(p * 5))) }
            if full >= 0.95 { frame.offsetX += sin(t * 2.4) > 0.6 ? 1 : 0 }
            frame.rate = max(frame.rate, 8)
        }
        // Bored: a command that's been running for over a minute.
        let waited = date.timeIntervalSince(session.lastEvent)
        if session.phase == .tool, session.activity.command, waited > 60 {
            let w = waited.truncatingRemainder(dividingBy: 25)
            if (12..<13.8).contains(w) { frame.decals += Self.yawn(frame.sheet, frame.index, wide: w > 12.4 && w < 13.4) }
            frame.rate = max(frame.rate, 2)
        }
        if session.motion == .typing, (1..<5).contains(hour) {
            let w = t.truncatingRemainder(dividingBy: 90)
            if (30..<31.8).contains(w) { frame.decals += Self.yawn(frame.sheet, frame.index, wide: w > 30.4 && w < 31.4) }
        }
        return frame
    }

    /// The top of his head in a frame: its row, and the column it starts at. Found by his orange, lit or in
    /// shadow: what he has beside him (a desk with its screen, a speech bubble) may reach higher.
    static func head(_ sheet: PixelSheet, _ index: Int) -> (x: Int, y: Int)? {
        let pixels = sheet.frames[min(index, sheet.frames.count - 1)]
        let skin = Set(sheet.palette.indices.filter { i in
            let c = sheet.palette[i]
            return c.r > 0.55 && c.r > c.g + 0.2 && c.g > c.b && c.b < 0.5
        }.map(UInt8.init))
        guard let first = pixels.firstIndex(where: { skin.contains($0) }) else { return nil }
        return (first % sheet.width, first / sheet.width)
    }

    /// Eyes shut and mouth open: drawn over whatever eyes the frame has, found by their colour.
    static func yawn(_ sheet: PixelSheet, _ index: Int, wide: Bool) -> [Decal] {
        let pixels = sheet.frames[min(index, sheet.frames.count - 1)]
        let dark = Set(sheet.palette.indices.filter { sheet.palette[$0].r + sheet.palette[$0].g + sheet.palette[$0].b < 0.3 }.map(UInt8.init))
        let eyePixels = pixels.indices.filter { dark.contains(pixels[$0]) }.map { ($0 % sheet.width, $0 / sheet.width) }
        guard let top = eyePixels.map(\.1).min(), let bottom = eyePixels.map(\.1).max(),
              let left = eyePixels.map(\.0).min(), let right = eyePixels.map(\.0).max() else { return [] }
        // The skin just above the eyes, to paint them over with.
        let skin = pixels[max(0, top - 1) * sheet.width + left]
        guard skin != 255, Int(skin) < sheet.palette.count else { return [] }
        let c = sheet.palette[Int(skin)]
        let body = UInt32(c.r * 255) << 24 | UInt32(c.g * 255) << 16 | UInt32(c.b * 255) << 8 | 0xff
        var decals: [Decal] = []
        // Each eye: painted over, then shut along its bottom row.
        let columns = Set(eyePixels.map(\.0)).sorted()
        var groups: [[Int]] = []
        for x in columns { if let last = groups.last?.last, x == last + 1 { groups[groups.count - 1].append(x) } else { groups.append([x]) } }
        let height = bottom - top + 1
        for group in groups {
            let width = group.count
            decals.append(Decal(PixelArt("skin\(width)x\(height)-\(body)", Array(repeating: String(repeating: "b", count: width), count: height), ["b": body]), group[0], top))
            decals.append(Decal(PixelArt("shut\(width)", [String(repeating: "x", count: width)], ["x": 0x14_14_13_ff]), group[0], bottom))
        }
        let mouth = PixelArt(wide ? "yawnWide" : "yawn", wide ? ["xx", "xx"] : ["xx"], ["x": 0x3a_1a_14_ff])
        decals.append(Decal(mouth, (left + right) / 2, bottom + 2))
        return decals
    }
}
