import SwiftUI

/// In place of words when there's nothing to say (Clawd living in the notch with Claude closed): a wave of
/// light green dots, each with a dark green one under it, running along the row and fading out at both
/// ends; it rises higher in some places than in others. It only moves while it's on screen, which is while
/// the pointer rests on the notch.
struct PixelWave: View {
    /// A dot every 6 points, 4.5 across: dots apart, like lights.
    private static let pitch: CGFloat = 6
    private static let dot: CGFloat = 4.5
    /// The wave's length and height in dots, how much the height swells and shrinks along it, and how
    /// many dots it runs a second.
    private static let length = 18.0
    private static let height = 2.5
    private static let swell = 0.6
    private static let speed = 4.0
    /// Dots at each end that fade out.
    private static let fade = 6

    private static let light = Color(.sRGB, red: 0xbb / 255.0, green: 0xe7 / 255.0, blue: 0x91 / 255.0)
    private static let shadow = Color(.sRGB, red: 0x43 / 255.0, green: 0x61 / 255.0, blue: 0x23 / 255.0)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12)) { context in
            Canvas { ctx, size in
                let columns = Int(size.width / Self.pitch)
                let middle = ((size.height / Self.pitch - 1) / 2).rounded(.down)
                let t = context.date.timeIntervalSinceReferenceDate
                for i in 0..<columns {
                    let x = Double(i) - t * Self.speed
                    let height = Self.height + Self.swell * sin(x / (Self.length * 2.7) * 2 * .pi)
                    let row = middle - (height * sin(x / Self.length * 2 * .pi)).rounded()
                    let opacity = Double(min(i + 1, columns - i, Self.fade)) / Double(Self.fade)
                    func dot(_ row: CGFloat) -> Path {
                        Path(CGRect(x: CGFloat(i) * Self.pitch, y: row * Self.pitch, width: Self.dot, height: Self.dot))
                    }
                    ctx.fill(dot(row + 1), with: .color(Self.shadow.opacity(opacity)))
                    ctx.fill(dot(row), with: .color(Self.light.opacity(opacity)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}
