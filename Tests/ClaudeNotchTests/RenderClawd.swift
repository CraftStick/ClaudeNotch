import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ClaudeNotch

/// Pictures of Clawd for drawing props: with CLAWD_RENDER set to a folder, a sheet frame blown up on a
/// pixel grid (unmirrored, sheet coordinates), and a strip of a reaction's frames as the notch shows them.
/// Skipped without it.
struct RenderClawd {
    static let folder = ProcessInfo.processInfo.environment["CLAWD_RENDER"]

    @Test(.enabled(if: folder != nil)) func render() throws {
        let folder = try #require(Self.folder)
        let pointing = try #require(ClawdAssets.pointing)
        for i in [0, 3, 7, 10, 14] { try write(grid(pointing, i), "\(folder)/pointing\(i).png") }
        if let laptop = ClawdAssets.laptop { try write(grid(laptop, 20), "\(folder)/laptop20.png") }
        if let laptop = ClawdAssets.laptop, let head = ClawdAnimator.head(laptop, 20) {
            let night = ClawdAnimator.Frame(laptop, 20, decals: [Decal(Props.nightcap, head.x, head.y - 4),
                                                                 Decal(Props.clock(1), head.x + 5, head.y - 13)])
            try write(strip([night]), "\(folder)/night.png")
        }
        for cue in [Cue.surprise, .thumbs, .stretch] {
            let reaction = try #require(ClawdAnimator.moodReactions[cue], "\(cue)")
            let times = stride(from: 0.0, to: reaction.duration, by: reaction.duration / 12).map { $0 }
            try write(strip(times.map { reaction.frame($0) }), "\(folder)/\(cue).png")
        }
    }

    /// One frame, 16× on a grid, the sheet's own way round, with a mark every 5 pixels.
    private func grid(_ sheet: PixelSheet, _ index: Int) -> CGImage {
        let image = SpriteImages.image(sheet, index, mirrored: false)!
        let s = 16, margin = 8
        let w = sheet.width + 2 * margin, h = sheet.height + 2 * margin
        let ctx = CGContext(data: nil, width: w * s, height: h * s, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(gray: 0.12, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w * s, height: h * s))
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: margin * s, y: margin * s, width: sheet.width * s, height: sheet.height * s))
        for i in 0...max(w, h) {
            let major = (i - margin) % 5 == 0
            ctx.setStrokeColor(gray: major ? 0.6 : 0.3, alpha: 1)
            ctx.setLineWidth(major ? 2 : 1)
            ctx.stroke(CGRect(x: i * s, y: 0, width: 0, height: h * s))
            ctx.stroke(CGRect(x: 0, y: (h - i) * s, width: w * s, height: 0))
        }
        return ctx.makeImage()!
    }

    /// Frames side by side, 6×, as the notch places them on Clawd's feet.
    private func strip(_ frames: [ClawdAnimator.Frame]) -> CGImage {
        let s = 6
        let cw = Int(ClawdAnimator.size.width) + 16, ch = Int(ClawdAnimator.size.height) + 12
        let ctx = CGContext(data: nil, width: cw * s * frames.count, height: ch * s, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: cw * s * frames.count, height: ch * s))
        ctx.interpolationQuality = .none
        let feet = ClawdAnimator.feet
        for (i, f) in frames.enumerated() {
            guard let image = SpriteImages.image(f.sheet, f.index, mirrored: f.mirrored, decals: f.decals) else { continue }
            let box = SpriteImages.bounds(f.sheet, f.decals)
            let left = f.mirrored ? feet.x + f.sheet.anchor.x - CGFloat(box.width + box.minX) : feet.x - f.sheet.anchor.x + CGFloat(box.minX)
            let top = feet.y - f.sheet.anchor.y + CGFloat(box.minY) + f.offsetY + 8
            let x = CGFloat(i * cw) + 8 + left + f.offsetX
            ctx.draw(image, in: CGRect(x: x * CGFloat(s), y: (CGFloat(ch) - top - CGFloat(box.height)) * CGFloat(s),
                                       width: CGFloat(box.width * s), height: CGFloat(box.height * s)))
        }
        return ctx.makeImage()!
    }

    private func write(_ image: CGImage, _ path: String) throws {
        let dest = try #require(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
