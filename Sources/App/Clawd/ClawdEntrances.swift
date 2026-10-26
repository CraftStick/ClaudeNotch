import CoreGraphics
import Foundation

/// Ways Clawd comes into the notch: up through its floor, peeking in round its left edge before he walks
/// in, or skipping in. One of them, or a hop, says hi as the app opens; and living in the notch for good,
/// he comes back from a stroll these ways too.
extension ClawdAnimator {
    /// The notch's left edge, from his feet, as it is round him at rest: where he's cut off coming in.
    static let edge: CGFloat = -32

    /// What of `frame` is inside the notch: not what's sunk below its floor, nor what's left of its edge.
    /// The island clips him there too, but only roughly where he stands (and the docs' GIFs not at all).
    /// The edge only for a frame facing right, as he faces coming in.
    static func inside(_ frame: Frame) -> Frame {
        var frame = frame
        let sheet = frame.sheet
        let ground = Int(sheet.anchor.y)
        let sunk = min(ground, Int(frame.offsetY))
        if sunk > 0 { frame.decals.insert(Decal(Props.cut(sheet.width, sunk), 0, ground - sunk, .cut), at: 0) }
        let past = min(sheet.width, Int(sheet.anchor.x + edge - frame.offsetX))
        if !frame.mirrored, past > 0 { frame.decals.insert(Decal(Props.cut(past, sheet.height), 0, 0, .cut), at: 0) }
        return frame
    }

    /// Up through the floor: his eyes come up first and look one way, the other and at you; then up he
    /// springs and throws his arms up.
    static let peekaboo: Pastime? = ClawdAssets.pointing.flatMap { sheet in
        let hidden = 17.0, peeking = 11.0  // under the floor; only his head and eyes over it
        func up(_ sunk: Double, eyes: Decal? = nil) -> Frame {
            inside(Frame(sheet, 0, rate: 16, offsetY: CGFloat(sunk.rounded()), decals: eyes.map { [$0] } ?? []))
        }
        let arms = Clip(sheet: sheet, frames: [6, 7, 8, 9, 10, 10, 10, 10, 15, 16, 0], fps: 14)
        return Pastime.sequence([
            Pastime(duration: 0.6) { t in up(hidden + (peeking - hidden) * smooth(t / 0.6)) },
            Pastime(duration: 1.6) { t in
                let look = t < 0.5 ? Decal(Props.eyesAsideNear, 5, 7) : t < 1.0 ? Decal(Props.eyesAsideFar, 5, 7) : nil
                return up(peeking, eyes: (1.3..<1.42).contains(t) ? Decal(Props.closedEyes, 5, 7) : look)
            },
            Pastime(duration: 0.3) { t in up(t < 0.22 ? peeking * (1 - smooth(t / 0.22)) : -1) },
            Pastime(duration: arms.duration) { t in
                var frame = Frame(arms, at: t)
                if (3...10).contains(frame.index) { frame.decals = [Decal(Props.happyEyes, 5, 7)] }
                return frame
            },
        ])
    }

    /// Round the left edge: he leans in, turned to look, ducks back, looks again with a blink, and walks in.
    static let peek: Pastime? = ClawdAssets.turning.flatMap { turning in ClawdAssets.walking.flatMap { walking in
        // Turned, his front eye and arm (x 17–22) show past the edge; leaning back, none of him.
        let out: CGFloat = -44, peeking: CGFloat = -35
        func lean(_ x: CGFloat, blink: Bool = false) -> Frame {
            inside(Frame(turning, 8, rate: 16, offsetX: x.rounded(), mirrored: false,
                         decals: blink ? [Decal(Props.closedEyesTurned, 9, 3)] : []))
        }
        func move(from: CGFloat, to: CGFloat, _ seconds: TimeInterval) -> Pastime {
            Pastime(duration: seconds) { t in lean(from + (to - from) * smooth(t / seconds)) }
        }
        let step = Clip(sheet: walking, frames: 5...24, fps: 12), face = Clip(sheet: walking, frames: 25...27, fps: 12)
        let walk = TimeInterval(-peeking / 14)  // as fast as he walks off
        return Pastime.sequence([
            move(from: out, to: peeking, 0.4),
            Pastime(duration: 0.9) { _ in lean(peeking) },
            move(from: peeking, to: out, 0.3),
            Pastime(duration: 0.5) { _ in lean(out) },
            move(from: out, to: peeking, 0.25),
            Pastime(duration: 0.8) { t in lean(peeking, blink: (0.35..<0.47).contains(t)) },
            Pastime(duration: walk) { t in
                inside(Frame(walking, step.looped(at: t), rate: 12, offsetX: (peeking * (1 - t / walk)).rounded(), mirrored: false))
            },
            Pastime([face]),
        ])
    } }

    /// Skipping in from the left, a hop to every step; then he turns to you.
    static let skip: Pastime? = ClawdAssets.walking.flatMap { walking in
        let from: CGFloat = -60, speed: CGFloat = 26
        let step = Clip(sheet: walking, frames: 5...24, fps: 16), face = Clip(sheet: walking, frames: 25...27, fps: 12)
        let skipping = TimeInterval(-from / speed)
        return Pastime.sequence([
            Pastime(duration: skipping) { t in
                let hop = t.truncatingRemainder(dividingBy: 0.36) / 0.36
                let lift = (4 * hop * (1 - hop) * 3).rounded()
                return inside(Frame(walking, step.looped(at: t), rate: 16, offsetX: (from * (1 - t / skipping)).rounded(),
                                    offsetY: -lift, mirrored: false))
            },
            Pastime([face]),
        ])
    }
}
