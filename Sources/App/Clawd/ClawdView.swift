import AppKit
import SwiftUI

/// Clawd in the notch. With the Claude app's sprites he turns to a laptop and types while Claude
/// works, puts it away and waves while Claude waits for you. After a turn he reacts (a happy hop,
/// a sigh after Esc, dizzy after an error), then idles with the odd fidget and dozes off; or, when he
/// lives in the notch for good, keeps busy with his own pastimes.
struct ClawdView: View {
    let session: Session

    var body: some View {
        if let laptop = ClawdAssets.laptop, let waving = ClawdAssets.waving {
            ClawdLayer(animator: ClawdAnimator(session: session, laptop: laptop, waving: waving))
                .frame(width: ClawdAnimator.size.width, height: ClawdAnimator.size.height)
        } else {
            DrawnClawdView(phase: session.phase)
        }
    }
}

/// Shows `ClawdAnimator`'s frames with Core Animation: each frame swaps a ready picture into a layer.
/// Drawn by SwiftUI instead, every frame (12 a second while Claude works) meant a SwiftUI pass over the
/// whole notch: about 6% of a CPU core, against about 1% this way.
private struct ClawdLayer: NSViewRepresentable {
    let animator: ClawdAnimator

    func makeNSView(context: Context) -> ClawdLayerView { ClawdLayerView(animator: animator) }
    func updateNSView(_ view: ClawdLayerView, context: Context) { view.animator = animator }
}

private final class ClawdLayerView: NSView {
    var animator: ClawdAnimator { didSet { showFrame() } }
    private let sprite = CALayer()
    /// Two "z"s drifting up and fading from beside the head while Clawd dozes, half a cycle apart.
    private let zs = [CALayer(), CALayer()]
    private var timer: Timer?

    init(animator: ClawdAnimator) {
        self.animator = animator
        super.init(frame: NSRect(origin: .zero, size: ClawdAnimator.size))
        // AppKit's own layer, not one set here: AppKit keeps it flipped to match `isFlipped` wherever
        // SwiftUI puts the view. A layer set by hand is flipped relative to its parent, which changes
        // with the notch's state, and frames of different heights then stood at different heights.
        wantsLayer = true
        layerContentsRedrawPolicy = .never  // nothing to draw: the sublayers show the pictures
        guard let root = layer else { return }
        for (layer, glyph) in [(sprite, nil), (zs[0], SpriteImages.smallZ), (zs[1], SpriteImages.bigZ)] {
            layer.magnificationFilter = .nearest  // crisp pixels
            if let glyph {
                layer.contents = glyph
                layer.bounds = CGRect(x: 0, y: 0, width: glyph.width, height: glyph.height)
                layer.anchorPoint = .zero
            }
            root.addSublayer(layer)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }  // top-left origin, like the sprite sheets

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        showFrame()
    }

    /// Shows the frame for now and comes back when the picture changes; stops while out of a window.
    private func showFrame() {
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        let frame = animator.frame(at: Date())
        let sheet = frame.sheet

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.contents = SpriteImages.image(sheet, frame.index, mirrored: frame.mirrored, decals: frame.decals)
        // The sheet's anchor on Clawd's feet; props may make the picture bigger than the sheet.
        let feet = ClawdAnimator.feet
        let box = SpriteImages.bounds(sheet, frame.decals)
        let left = frame.mirrored
            ? feet.x + sheet.anchor.x - CGFloat(box.width + box.minX)
            : feet.x - sheet.anchor.x + CGFloat(box.minX)
        sprite.frame = CGRect(x: left + frame.offsetX,
                              y: feet.y - sheet.anchor.y + CGFloat(box.minY) + frame.offsetY,
                              width: CGFloat(box.width), height: CGFloat(box.height))
        // Beside his head, or from above a book on it.
        let zStart = frame.decals.isEmpty ? feet.y - 14 : sprite.frame.minY - 5
        for (z, offset) in zip(zs, [0.0, 0.5]) {
            z.isHidden = frame.dozing == nil
            guard let dozing = frame.dozing else { continue }
            let p = (dozing / 2.6 + offset).truncatingRemainder(dividingBy: 1)
            z.position = CGPoint(x: feet.x + 4 + p * 4, y: zStart - p * 12)
            z.opacity = Float(0.75 * (1 - p))
        }
        CATransaction.commit()

        let delay = 1 / min(16, max(1, frame.rate))
        let next = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.showFrame() }
        next.tolerance = delay / 10  // lets macOS bundle the wakeup with others
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }
}

/// Sprite frames turned into pictures once, mirrored the way Clawd faces in the notch.
private enum SpriteImages {
    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 600  // a few kilobytes each
        return cache
    }()

    /// The picture of a frame with its props: where the sheet's own top-left corner is in it (minus),
    /// and its size.
    static func bounds(_ sheet: PixelSheet, _ decals: [Decal]) -> (minX: Int, minY: Int, width: Int, height: Int) {
        let minX = decals.map(\.x).reduce(0, min), minY = decals.map(\.y).reduce(0, min)
        let maxX = decals.map { $0.x + $0.art.width }.reduce(sheet.width, max)
        let maxY = decals.map { $0.y + $0.art.height }.reduce(sheet.height, max)
        return (minX, minY, maxX - minX, maxY - minY)
    }

    /// `mirrored`: facing left, the way Clawd usually stands in the notch. `decals` are drawn over him,
    /// behind him or cut out of him, as their layer says.
    static func image(_ sheet: PixelSheet, _ index: Int, mirrored: Bool = true, decals: [Decal] = []) -> CGImage? {
        let layers: [Decal.Layer: String] = [.front: "", .behind: "<", .cut: "-"]
        let key = ("\(sheet.name)#\(index)\(mirrored ? "" : ">")"
            + decals.map { "|\($0.art.name)@\($0.x),\($0.y)\(layers[$0.layer]!)" }.joined()) as NSString
        if let image = cache.object(forKey: key) { return image }
        let box = bounds(sheet, decals)
        var rgba = [UInt8](repeating: 0, count: box.width * box.height * 4)
        func offset(_ x: Int, _ y: Int) -> Int {
            let column = x - box.minX
            return ((y - box.minY) * box.width + (mirrored ? box.width - 1 - column : column)) * 4
        }
        let pixels = sheet.frames[min(index, sheet.frames.count - 1)]
        let colors = sheet.palette.map { [UInt8($0.r * 255), UInt8($0.g * 255), UInt8($0.b * 255), 255] }
        for y in 0..<sheet.height {
            for x in 0..<sheet.width {
                let v = pixels[y * sheet.width + x]
                guard v != 255 else { continue }
                let at = offset(x, y)
                rgba.replaceSubrange(at..<(at + 4), with: colors[Int(v)])
            }
        }
        // What's cut away first, so what's behind him shows there; then behind him, only where he isn't;
        // then in front.
        for layer in [Decal.Layer.cut, .behind, .front] {
            for decal in decals where decal.layer == layer {
                let art = decal.art
                for y in 0..<art.height {
                    for x in 0..<art.width {
                        let from = (y * art.width + x) * 4
                        guard art.rgba[from + 3] > 0 else { continue }
                        let at = offset(decal.x + x, decal.y + y)
                        switch layer {
                        case .cut: rgba.replaceSubrange(at..<(at + 4), with: [0, 0, 0, 0])
                        case .behind where rgba[at + 3] > 0: continue
                        default: rgba.replaceSubrange(at..<(at + 4), with: art.rgba[from..<(from + 4)])
                        }
                    }
                }
            }
        }
        guard let image = CGImage.pixels(rgba, width: box.width, height: box.height) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    static let smallZ = glyph(["####", "..#.", ".#..", "####"])
    static let bigZ = glyph(["#####", "...#.", "..#..", ".#...", "#####"])

    private static func glyph(_ rows: [String]) -> CGImage? {
        let width = rows[0].count
        let rgba = rows.flatMap { $0.flatMap { $0 == "#" ? [UInt8](repeating: 255, count: 4) : [0, 0, 0, 0] } }
        return CGImage.pixels(rgba, width: width, height: rows.count)
    }
}
