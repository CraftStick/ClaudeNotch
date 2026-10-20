import AppKit
import SwiftUI

/// A thin line along the island's edge in red, orange and gold, flowing around it while Claude is at
/// work and holding still while it rests.
///
/// The colours turn in a Core Animation layer, so the render server moves them and the app does no
/// work per frame; animated by SwiftUI instead, every frame would cost a pass over the whole notch.
/// Even so the screen has to redraw that corner of the menu bar for every frame (about 7% of a core
/// for WindowServer), so they only move while there's work to show.
///
/// SwiftUI cuts the line out of the layer with a mask in the island's shape, so it follows the island
/// as it opens and closes. The view holding the layer has a fixed size and place, so AppKit never has
/// to move it; the layer inside is only as big as the island.
struct NotchRim: View {
    let shape: NotchShape
    /// The island's size now.
    let size: CGSize
    /// The largest the island gets, for the view holding the layer.
    let canvas: CGSize
    let working: Bool

    static let width: CGFloat = 2

    var body: some View {
        FlowingColors(island: size, moving: working)
            .frame(width: canvas.width, height: canvas.height)
            .mask(alignment: .top) {
                // Inside the edge, over the black: it reads the same on any background.
                NotchShape(topRadius: shape.topRadius, bottomRadius: shape.bottomRadius, closed: false)
                    .stroke(lineWidth: 2 * Self.width)
                    .clipShape(shape)
                    .frame(width: size.width, height: size.height)
            }
            .allowsHitTesting(false)
    }
}

/// A conic gradient of the rim's colours around the middle of an island of size `island`, which
/// hangs from the top centre of the view; it turns while `moving`.
private struct FlowingColors: NSViewRepresentable {
    let island: CGSize
    let moving: Bool

    func makeNSView(context: Context) -> FlowingColorsView { FlowingColorsView(island: island, moving: moving) }

    func updateNSView(_ view: FlowingColorsView, context: Context) {
        view.island = island
        view.moving = moving
    }
}

private final class FlowingColorsView: NSView {
    private let gradient = CAGradientLayer()
    private static let turn: CFTimeInterval = 5
    /// The island's size, and the size the layer covers: while the island shrinks the mask still
    /// has the old size for a moment, so the layer keeps it until the animation is over.
    var island: CGSize { didSet { if island != oldValue { resize() } } }
    var moving: Bool { didSet { if moving != oldValue { place() } } }
    private var covered: CGSize
    private var shrink: DispatchWorkItem?
    /// Where the colours are in their turn (0…1) as of `since`, and whether they were turning then:
    /// they carry on from there when they start or stop, or the island changes size.
    private var phase = 0.0
    private var since = CACurrentMediaTime()
    private var turning = false

    init(island: CGSize, moving: Bool) {
        self.island = island
        self.moving = moving
        covered = island
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        let red = NSColor(srgbRed: 0.95, green: 0.24, blue: 0.18, alpha: 1)
        let orange = NSColor(srgbRed: 1.0, green: 0.52, blue: 0.2, alpha: 1)
        let gold = NSColor(srgbRed: 1.0, green: 0.8, blue: 0.3, alpha: 1)
        gradient.type = .conic
        gradient.colors = [red, orange, gold, orange, red].map(\.cgColor)
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        layer?.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }  // top-left origin

    override func layout() {
        super.layout()
        place()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        place()
    }

    private func resize() {
        shrink?.cancel()
        covered = CGSize(width: max(covered.width, island.width), height: max(covered.height, island.height))
        place()
        guard covered != island else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.covered = self.island
            self.place()
        }
        shrink = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    /// Lays the layer over the island and sets the colours turning or holding still.
    private func place() {
        let now = CACurrentMediaTime()
        if turning { phase = (phase + (now - since) / Self.turn).truncatingRemainder(dividingBy: 1) }
        since = now
        turning = moving && window != nil

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = CGRect(x: (bounds.width - covered.width) / 2, y: 0, width: covered.width, height: covered.height)
        gradient.removeAnimation(forKey: "spin")
        gradient.endPoint = end(at: phase)
        CATransaction.commit()

        guard turning, covered.width > 0, covered.height > 0 else { return }
        let steps = 48
        let turn = CAKeyframeAnimation(keyPath: "endPoint")
        turn.values = (0...steps).map { NSValue(point: end(at: phase + Double($0) / Double(steps))) }
        turn.duration = Self.turn
        turn.repeatCount = .infinity
        turn.calculationMode = .linear
        turn.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 20, preferred: 20)  // easy on the battery
        gradient.add(turn, forKey: "spin")
    }

    /// The conic gradient's end point at `phase` of a turn. It circles the middle in points, not in
    /// the layer's 0…1 units, so the turn is even on a wide island.
    private func end(at phase: Double) -> CGPoint {
        let a = phase * 2 * .pi
        let w = max(1, covered.width), h = max(1, covered.height)
        return CGPoint(x: 0.5 + cos(a) * 10 / w, y: 0.5 + sin(a) * 10 / h)
    }
}
