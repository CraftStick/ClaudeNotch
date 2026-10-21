import Foundation

/// How Clawd takes what happens at work, beyond typing and waving: packing papers into a box while
/// the context is compacted, an hourglass at a rate limit, a "?" when auto mode turns something down,
/// head in his hands after a few failures in a row, a sparkler for passing tests, a rocket for a push;
/// and, over whatever he does, a drop of sweat as the context fills up, getting impatient while he
/// waits for you, a yawn late at night.
extension ClawdAnimator {
    // MARK: Motions

    /// Compacting: two sheets of paper tumble in an arc from his hand into the box beside him, which he
    /// watches; the lid flaps shut with a puff of dust and he gives it a satisfied squash. Loops while
    /// Claude compacts.
    static let compacting: Pastime? = ClawdAssets.pointing.map { sheet in
        Pastime(duration: 3.2) { t in
            var decals: [Decal] = []
            let shut = (1.55..<3.0).contains(t)
            decals.append(Decal(shut ? Props.boxShut : Props.box, 25, 13))
            // Each sheet: from his hand (21, 9) up over his shoulder and down into the box (28, 14).
            for start in [0.0, 0.55] where (start..<(start + 0.9)).contains(t) {
                let p = (t - start) / 0.9
                let x = 21 + Int((28 - 21) * p)
                let y = 9 - Int(4 * p * (1 - p) * 12) + Int(5 * p)
                decals.append(Decal(Int(t / 0.15) % 2 == 0 ? Props.paper : Props.paperTumbling, x, y))
            }
            // Dust out from under the lid as it shuts, spreading and fading.
            if (1.6..<1.85).contains(t) { decals += [Decal(Props.puff, 23, 18), Decal(Props.puff, 35, 18)] }
            if (1.85..<2.2).contains(t) { decals += [Decal(Props.puffWide, 21, 17), Decal(Props.puffWide, 35, 17)] }
            let squash = (1.6..<1.95).contains(t)
            if squash {
                decals.append(Decal(Props.happyEyes, 5, 7))
            } else if t < 1.55 {
                decals.append(Decal(Props.eyesAside, 6, 7))  // watching his papers go in
            }
            return Frame(sheet, 0, rate: 12, offsetY: squash ? 1 : 0, decals: decals)
        }
    }

    /// A rate limit: he stands by an hourglass, eyes on it, while its sand runs down; once it's all
    /// through he blinks at you.
    static let rateLimit: Pastime? = ClawdAssets.pointing.map { sheet in
        Pastime(duration: 8) { t in
            let running = t < 7
            let level = running ? Int(t / 7 * 9) : 9
            var decals = [Decal(Props.hourglass(level, running: running && Int(t * 8) % 2 == 0), 25, 10)]
            let blink = t.truncatingRemainder(dividingBy: 2.6) > 2.45 || (7.3..<7.45).contains(t)
            decals.append(blink ? Decal(Props.closedEyes, 5, 7) : Decal(Props.eyesAside, 6, 7))
            if !running, !blink { decals.removeLast() }  // done: back to looking at you
            return Frame(sheet, 0, rate: 8, decals: decals)
        }
    }

    /// Searching (code, files, the web): a deerstalker drops onto his head and he peers through a
    /// magnifying glass with one eye narrowed, moving it about and edging along as he looks. Loops.
    static let searching: Pastime? = ClawdAssets.pointing.map { sheet in
        Pastime(duration: 2.4) { t in
            let spots = [(18, 3), (19, 3), (19, 4), (18, 4)]
            let spot = spots[Int(t / 0.6) % spots.count]
            return Frame(sheet, 0, rate: 8, offsetX: t < 1.2 ? 0 : 1,
                         decals: [Decal(Props.deerstalker, 2, -2), Decal(Props.squint, 16, 7), Decal(Props.magnifier, spot.0, spot.1)])
        }
    }

    /// Putting the hat on, before the first look: down onto his head from above.
    static func hatOn(_ t: TimeInterval) -> Frame? {
        guard t < 0.3, let sheet = ClawdAssets.pointing else { return nil }
        let drop = Int((1 - t / 0.3) * 6)
        return Frame(sheet, 0, rate: 16, decals: [Decal(Props.deerstalker, 2, -2 - drop)])
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
        all[.rocket] = ClawdAssets.pointing.flatMap { sheet in
            let launch = Pastime(duration: 2.4) { t in
                var decals: [Decal] = []
                let lit = t >= 0.45
                let lift = t < 1.0 ? 0 : Int(pow((t - 1.0) * 5, 2))
                let shake = lit && lift == 0 ? (Int(t * 20) % 2 == 0 ? 1 : 0) : 0
                let y = 6 - lift
                decals.append(Decal(Props.rocket, 27 + shake, y))
                if lit {
                    let flicker = Int(t * 14) % 2 == 0
                    decals.append(Decal(flicker || lift > 0 ? Props.flameLong : Props.flame, 30 + shake, y + 11))
                    // Sparks thrown out round the flame, somewhere new each frame.
                    var random = SeededRandom(seed: UInt64(t * 14))
                    for _ in 0..<5 {
                        let sparkY = y + 12 + Int.random(in: 0...4, using: &random)
                        let sparkX = 28 + Int.random(in: 0...6, using: &random) + shake
                        if sparkY <= 20 { decals.append(Decal(Props.spark, sparkX, sparkY)) }  // not under the ground
                    }
                }
                // Smoke at the pad, spreading out as it goes.
                if (0.5..<1.2).contains(t) { decals += [Decal(Props.puff, 26, 18), Decal(Props.puff, 34, 18)] }
                if (1.2..<1.9).contains(t) { decals += [Decal(Props.puffWide, 24, 17), Decal(Props.puffWide, 34, 17)] }
                let pressing = (0.4..<0.65).contains(t)
                decals.append(Decal(pressing || lit ? Props.remotePressed : Props.remote, 21, 9))
                decals.append(Decal(t < 1.0 ? Props.eyesAside : Props.eyesUp, 6, 7))
                return Frame(sheet, 0, rate: 14, offsetY: pressing ? 1 : 0, decals: decals)
            }
            let joy = ClawdAssets.excited.flatMap { Pastime([Clip(sheet: $0, frames: 2...21, fps: 14)]) }
            return Pastime.sequence([launch, joy])
        }
        return all.compactMapValues { $0 }
    }()

    // MARK: Over what he does

    /// While Claude works: a drop of sweat from 85% of the context, and a little sway from 95%; a yawn
    /// now and then at the laptop between 1 and 5 at night.
    func mood(_ frame: Frame, at date: Date) -> Frame {
        guard session.phase.isActive, [.typing, .pondering, .desktop, .running, .searching].contains(session.motion) else { return frame }
        var frame = frame
        let t = date.timeIntervalSince(session.motionStart)
        let full = session.contextWindow > 0 ? Double(session.contextTokens) / Double(session.contextWindow) : 0
        if full >= 0.85, let head = Self.head(frame.sheet, frame.index) {
            // Gathers at his temple, runs down and is gone; then the next one.
            let p = (t / 1.6).truncatingRemainder(dividingBy: 1)
            if p < 0.85 { frame.decals.append(Decal(Props.sweat, head.x - 3, head.y + 1 + Int(p * 5))) }
            if full >= 0.95 { frame.offsetX += sin(t * 2.4) > 0.6 ? 1 : 0 }
            frame.rate = max(frame.rate, 8)
        }
        let hour = Calendar.current.component(.hour, from: date)
        if session.motion == .typing, (1..<5).contains(hour) {
            let w = t.truncatingRemainder(dividingBy: 90)
            if (30..<31.8).contains(w) { frame.decals += Self.yawn(frame.sheet, frame.index, wide: w > 30.4 && w < 31.4) }
        }
        return frame
    }

    /// The top of his head in a frame: its row, and the column it starts at.
    static func head(_ sheet: PixelSheet, _ index: Int) -> (x: Int, y: Int)? {
        let pixels = sheet.frames[min(index, sheet.frames.count - 1)]
        guard let first = pixels.firstIndex(where: { $0 != 255 }) else { return nil }
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
