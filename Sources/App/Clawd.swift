import AppKit
import SwiftUI

/// Clawd, the Claude Code mascot, as pixel sprites: facing you, or turned to a laptop and typing.
enum ClawdSprite {
    /// `typingNear`/`typingFar`: which hand is on the keys.
    enum Pose { case front, typingNear, typingFar }
    enum Pixel { case body, shade, eye, screen, keys, pressedKey }

    /// Canvas size, in sprite pixels, that fits every pose.
    static let columns = 28
    static let rows = 16

    // "#" body, "%" body in shadow, "o" eye, "s" laptop screen, "k" keyboard, "K" pressed key.

    /// Facing you. Drawn at 2×2 sprite pixels per cell.
    private static let front = [
        "..########..",
        "..#o####o#..",
        "############",
        "############",
        "..########..",
        "..########..",
        "..#.#..#.#..",
        "..#.#..#.#..",
    ]
    // Three-quarter view, turned to the laptop on the left: the body (right part) is shared,
    // the left part holds the laptop and the hands. The near hand is kept a pixel away from
    // the body so it reads as a hand; "K" is the key being pressed.
    private static let typingBody = [
        "############%%%%.",
        "############%%%%.",
        "############%%%%.",
        "#oo#####oo##%%%%.",
        "#oo#####oo##%%%%.",
        "############%%%%.",
        "############%%%%.",
        "############%%%%.",
        "############%%%%.",
        "############%%%%.",
        "############%%%%.",
        "##..##...##..%%..",
        "###.###..###.%%%.",
        ".##..##...##..%%.",
    ]
    private static let nearHandDown = [
        "...........",
        "...........",
        "...........",
        "...........",
        "...........",
        "s........##",
        "ss.......##",
        ".s..%%..##.",
        ".ss.%%..##.",
        "..s....###.",
        "..ss...###.",
        "...kkkkkKk.",
        "...........",
        "...........",
    ]
    private static let farHandDown = [
        "...........",
        "...........",
        "...........",
        "...........",
        "...........",
        "s........##",
        "ss.......##",
        ".s.....###.",
        ".ss....###.",
        "..s.%%.....",
        "..ss%%.....",
        "...kKkkkkk.",
        "...........",
        "...........",
    ]
    private static let typingNear = zip(nearHandDown, typingBody).map { $0 + $1 }
    private static let typingFar = zip(farHandDown, typingBody).map { $0 + $1 }

    /// Calls `paint` for every pixel of `pose` on the shared canvas, top-left origin.
    static func draw(_ pose: Pose, unit: CGFloat, eyesOpen: Bool, paint: (CGRect, Pixel) -> Void) {
        guard pose != .front else {
            paintMap(front, cell: 2 * unit, dx: 2 * unit, dy: 0, eyesOpen: eyesOpen, paint: paint)
            return
        }
        let map = pose == .typingNear ? typingNear : typingFar
        let dy = CGFloat(rows - map.count) * unit  // sits on the bottom edge
        paintMap(map, cell: unit, dx: 0, dy: dy, eyesOpen: eyesOpen, paint: paint)
    }

    private static func paintMap(_ map: [String], cell: CGFloat, dx: CGFloat, dy: CGFloat, eyesOpen: Bool,
                                 paint: (CGRect, Pixel) -> Void) {
        for (row, line) in map.enumerated() {
            for (column, char) in line.enumerated() {
                let pixel: Pixel
                switch char {
                case "#": pixel = .body
                case "%": pixel = .shade
                case "o": pixel = eyesOpen ? .eye : .body
                case "s": pixel = .screen
                case "k": pixel = .keys
                case "K": pixel = .pressedKey
                default: continue
                }
                paint(CGRect(x: dx + CGFloat(column) * cell, y: dy + CGFloat(row) * cell, width: cell, height: cell), pixel)
            }
        }
    }

    /// Template image for the menu bar (Clawd facing you); the eyes are see-through.
    static func menuBarImage(cell: CGFloat = 1.5) -> NSImage {
        let size = NSSize(width: CGFloat(front[0].count) * cell, height: CGFloat(front.count) * cell)
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill()
            paintMap(front, cell: cell, dx: 0, dy: 0, eyesOpen: true) { rect, pixel in
                if pixel == .body { rect.fill() }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Hand-drawn Clawd, used when the Claude app is not installed: types on a laptop while Claude works (faster while it runs a tool),
/// turns to you and hops while it waits for you, blinks now and then.
struct DrawnClawdView: View {
    let phase: Phase
    var unit: CGFloat = 1

    /// Irregular rhythm of which hand hits the keys: 1 = near hand, 0 = far hand.
    private static let rhythm = [1, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0, 0, 1, 0, 1]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !phase.isActive)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pose = pose(t)
            Canvas { ctx, _ in
                // One path per color, so neighbouring pixels never show seams.
                var paths: [ClawdSprite.Pixel: Path] = [:]
                ClawdSprite.draw(pose, unit: unit, eyesOpen: !blinking(t)) { rect, pixel in
                    paths[pixel, default: Path()].addRect(rect)
                }
                for (pixel, path) in paths {
                    ctx.fill(path, with: .color(color(pixel)))
                }
            }
            .frame(width: CGFloat(ClawdSprite.columns) * unit, height: CGFloat(ClawdSprite.rows) * unit)
            .offset(y: hop(t))
        }
    }

    private func pose(_ t: TimeInterval) -> ClawdSprite.Pose {
        let keysPerSecond: Double
        switch phase {
        case .tool: keysPerSecond = 9
        case .thinking: keysPerSecond = 4
        case .waiting, .done, .stopped, .failed: return .front
        }
        let k = Int(t * keysPerSecond)
        return Self.rhythm[k % Self.rhythm.count] == 1 ? .typingNear : .typingFar
    }

    private func color(_ pixel: ClawdSprite.Pixel) -> Color {
        let (r, g, b): (Double, Double, Double)
        switch phase {
        case .stopped: (r, g, b) = (0.55, 0.55, 0.55)
        case .failed: (r, g, b) = (0.9, 0.3, 0.3)
        default: (r, g, b) = (0.85, 0.47, 0.34)  // claudeOrange
        }
        switch pixel {
        case .body: return Color(red: r, green: g, blue: b)
        case .shade: return Color(red: r * 0.8, green: g * 0.8, blue: b * 0.8)
        case .eye: return .black
        case .screen: return Color(white: 0.55)
        case .keys: return Color(white: 0.4)
        case .pressedKey: return Color(white: 0.95)
        }
    }

    private func blinking(_ t: TimeInterval) -> Bool {
        phase.isActive && t.truncatingRemainder(dividingBy: 3.7) < 0.15
    }

    private func hop(_ t: TimeInterval) -> CGFloat {
        phase == .waiting ? -abs(sin(t * .pi * 1.5)) * unit * 3 : 0
    }
}
