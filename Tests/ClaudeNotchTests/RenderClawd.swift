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
        // The nightcap on each pose he works in.
        let poses = [(ClawdAssets.laptop, 20), (ClawdAssets.desktop, 30), (ClawdAssets.thinking, 30), (ClawdAssets.running, 8)]
        let night = poses.compactMap { sheet, index in
            sheet.flatMap { sheet in ClawdAnimator.head(sheet, index).map { head in
                ClawdAnimator.Frame(sheet, index, decals: [Decal(sheet.name == "Thinking" ? Props.nightcapOtherWay : Props.nightcap,
                                                                 head.x, head.y - 4)])
            } }
        }
        try write(strip(night), "\(folder)/night.png")
        // Sheets as they come, every few frames.
        for (name, sheet, frames) in [("Hula", ClawdAssets.hula, Array(stride(from: 0, through: 53, by: 3))), ("Meditating", ClawdAssets.meditating, Array(stride(from: 0, through: 59, by: 4))),
                                      ("Thinking", ClawdAssets.thinking, [0, 3, 4, 6, 18, 19, 20, 21, 22, 30, 36]), ("Meditating-sit", ClawdAssets.meditating, [0, 2, 3, 4, 5, 6, 7, 8, 45, 46, 50, 54, 56, 58, 59])] {
            guard let sheet else { continue }
            try write(strip(frames.map { ClawdAnimator.Frame(sheet, $0) }), "\(folder)/sheet-\(name).png")
        }
        if let start = ClawdAnimator.napStart, let end = ClawdAnimator.napEnd {
            for part in 0..<3 {
                let from = start.duration * Double(part) / 3, step = start.duration / 30
                try write(strip((0..<10).map { start.frame(from + Double($0) * step) }), "\(folder)/nap-start\(part).png")
            }
            try write(strip(stride(from: 0.0, to: end.duration, by: end.duration / 16).map { end.frame($0) }), "\(folder)/nap-end.png")
        }
        // Asleep under his book when a task comes in: he gets up, puts the book away, and opens his laptop.
        if let laptop = ClawdAssets.laptop, let waving = ClawdAssets.waving {
            let rest = Date(timeIntervalSinceReferenceDate: 800_000_000)
            var s = Session(id: "nap", turnStart: rest, lastEvent: rest)
            s.phase = .thinking
            s.syncMotion(at: rest.addingTimeInterval(-30))
            s.phase = .done
            s.turnEnd = rest
            s.syncMotion(at: rest)
            let start = rest.addingTimeInterval(240)  // asleep by then
            s.phase = .thinking
            s.lastEvent = start
            s.syncMotion(at: start)
            let animator = ClawdAnimator(session: s, laptop: laptop, waving: waving)
            try write(strip(stride(from: 0.0, to: 5.6, by: 0.35).map { animator.frame(at: start.addingTimeInterval($0)) }), "\(folder)/cut-short.png")
        }
        // Sitting while he thinks, then the next tool; sitting after waiting six minutes, then your answer.
        if let laptop = ClawdAssets.laptop, let waving = ClawdAssets.waving {
            var strips: [ClawdAnimator.Frame] = []
            for (phase, wait) in [(Phase.thinking, 40.0), (Phase.waiting, 360.0)] {
                let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
                var s = Session(id: "sit", turnStart: t0, lastEvent: t0)
                s.phase = phase
                s.syncMotion(at: t0)
                if phase == .thinking { s.syncMotion(at: t0.addingTimeInterval(wait)) }  // pondering by then
                let next = t0.addingTimeInterval(wait + 1)
                s.phase = .tool
                s.activity = Describe.tool("Read", ["file_path": "/a.swift"])
                s.lastEvent = next
                s.syncMotion(at: next)
                let animator = ClawdAnimator(session: s, laptop: laptop, waving: waving)
                strips += stride(from: -0.3, to: 1.2, by: 0.15).map { animator.frame(at: next.addingTimeInterval($0)) }
            }
            try write(strip(strips), "\(folder)/stand-up.png")
        }
        if let hula = ClawdAnimator.hula { try frames(hula, into: "\(folder)/gif-hula") }
        if let look = ClawdAnimator.searching, let off = ClawdAnimator.hatOff,
           let search = ClawdAnimator.Pastime.sequence([ClawdAnimator.Pastime(duration: 0.8) { ClawdAnimator.hatOn($0)! }, look, look, off]) {
            try frames(search, into: "\(folder)/gif-searching")
        }
        if let rocket = ClawdAnimator.moodReactions[.rocket] { try frames(rocket, into: "\(folder)/gif-rocket") }
        if let start = ClawdAnimator.napStart, let end = ClawdAnimator.napEnd,
           let nap = ClawdAnimator.Pastime.sequence([start, ClawdAnimator.Pastime(duration: 5) { ClawdAnimator.napping($0)! }, end]) {
            try frames(nap, into: "\(folder)/gif-sleeping")
        }
        if let hula = ClawdAnimator.hula {
            try write(strip(stride(from: 0.0, to: 2.4, by: 0.1).map { hula.frame($0) }), "\(folder)/hula-on.png")
            try write(strip(stride(from: hula.duration - 2.4, to: hula.duration, by: 0.1).map { hula.frame($0) }), "\(folder)/hula-off.png")
        }
        if let dizzy = ClawdAnimator.reactions[.dizzy] {
            try write(strip(stride(from: 0.0, to: dizzy.duration, by: dizzy.duration / 14).map { dizzy.frame($0) }), "\(folder)/dizzy.png")
        }
        for cue in [Cue.sweep, .rocket] {
            let reaction = try #require(ClawdAnimator.moodReactions[cue], "\(cue)")
            try write(strip(stride(from: 0.0, to: 1.6, by: 0.1).map { reaction.frame($0) }), "\(folder)/\(cue)-start.png")
        }
        var props: [ClawdAnimator.Frame] = []
        if let out = ClawdAnimator.boxOut { props += stride(from: 0.0, to: out.duration, by: 0.1).map { out.frame($0) } }
        for t in stride(from: 0.0, to: 0.8, by: 0.08) { if let f = ClawdAnimator.hatOn(t) { props.append(f) } }
        if let off = ClawdAnimator.hatOff { props += stride(from: 0.0, to: off.duration, by: 0.1).map { off.frame($0) } }
        if let rl = ClawdAnimator.rateLimit { props += stride(from: 0.2, to: 0.9, by: 0.1).map { rl.frame($0) } }
        try write(strip(props), "\(folder)/props-in.png")
        for cue in [Cue.surprise, .thumbs, .stretch] {
            let reaction = try #require(ClawdAnimator.moodReactions[cue], "\(cue)")
            let times = stride(from: 0.0, to: reaction.duration, by: reaction.duration / 12).map { $0 }
            try write(strip(times.map { reaction.frame($0) }), "\(folder)/\(cue).png")
        }
    }

    /// A pastime as numbered frames, 12 a second, for docs/clawd's GIFs (ffmpeg makes them): 4× on black,
    /// 48 × 52 like the others, with the "z"s while he dozes.
    private func frames(_ pastime: ClawdAnimator.Pastime, from: TimeInterval = 0, to: TimeInterval? = nil, into dir: String) throws {
        try? FileManager.default.removeItem(atPath: dir)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let s = 4, w = 48, h = 52
        let feet = CGPoint(x: 30, y: 48)
        for (n, t) in stride(from: from, to: to ?? pastime.duration, by: 1.0 / 12).enumerated() {
            let f = pastime.frame(t)
            let ctx = CGContext(data: nil, width: w * s, height: h * s, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w * s, height: h * s))
            ctx.interpolationQuality = .none
            func draw(_ image: CGImage, x: CGFloat, y: CGFloat, width: Int, height: Int, alpha: CGFloat = 1) {
                ctx.setAlpha(alpha)
                ctx.draw(image, in: CGRect(x: x * CGFloat(s), y: (CGFloat(h) - y - CGFloat(height)) * CGFloat(s),
                                           width: CGFloat(width * s), height: CGFloat(height * s)))
                ctx.setAlpha(1)
            }
            if let image = SpriteImages.image(f.sheet, f.index, mirrored: f.mirrored, decals: f.decals) {
                let box = SpriteImages.bounds(f.sheet, f.decals)
                let left = f.mirrored ? feet.x + f.sheet.anchor.x - CGFloat(box.width + box.minX) : feet.x - f.sheet.anchor.x + CGFloat(box.minX)
                let top = feet.y - f.sheet.anchor.y + CGFloat(box.minY) + f.offsetY
                draw(image, x: left + f.offsetX, y: top, width: box.width, height: box.height)
                if let dozing = f.dozing {
                    let zStart = f.decals.isEmpty ? feet.y - 14 : top - 5
                    for (glyph, offset) in [(SpriteImages.smallZ, 0.0), (SpriteImages.bigZ, 0.5)] {
                        guard let glyph else { continue }
                        let p = (dozing / 2.6 + offset).truncatingRemainder(dividingBy: 1)
                        draw(glyph, x: feet.x + 4 + p * 4, y: zStart - p * 12, width: glyph.width, height: glyph.height, alpha: 0.75 * (1 - p))
                    }
                }
            }
            try write(ctx.makeImage()!, String(format: "%@/%03d.png", dir, n))
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
