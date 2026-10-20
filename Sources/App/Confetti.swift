import AppKit
import SwiftUI

/// A burst of pixel confetti from Clawd over the open island when a big task is done.
///
/// Clawd's own confetti sprite flies up, off the top of the screen, so the burst is what you see:
/// coloured squares thrown from his hands that drift across the island and fall. Core Animation's
/// emitter runs it in the render server, so the app does no work per frame; it lasts a couple of seconds.
struct ConfettiBurst: View {
    let shape: NotchShape
    /// The island's size now, and the largest it gets.
    let size: CGSize
    let canvas: CGSize
    /// Where the confetti comes from, in the island's coordinates: Clawd's hands.
    let origin: CGPoint

    var body: some View {
        ConfettiEmitter(island: size, origin: origin)
            .frame(width: canvas.width, height: canvas.height)
            .mask(alignment: .top) { shape.frame(width: size.width, height: size.height) }
            .allowsHitTesting(false)
    }
}

private struct ConfettiEmitter: NSViewRepresentable {
    let island: CGSize
    let origin: CGPoint

    func makeNSView(context: Context) -> ConfettiView { ConfettiView(island: island, origin: origin) }
    func updateNSView(_ view: ConfettiView, context: Context) {}
}

private final class ConfettiView: NSView {
    private let emitter = CAEmitterLayer()
    private let island: CGSize
    private let origin: CGPoint
    private var thrown = false

    init(island: CGSize, origin: CGPoint) {
        self.island = island
        self.origin = origin
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        emitter.emitterShape = .point
        emitter.birthRate = 0
        let colors: [(Double, Double, Double)] = [
            (0.96, 0.32, 0.3), (1.0, 0.84, 0.3), (0.38, 0.64, 1.0), (0.42, 0.86, 0.46), (1.0, 0.52, 0.76), (1.0, 0.6, 0.24),
        ]
        emitter.emitterCells = colors.map { Self.cell(NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1)) }
        layer?.addSublayer(emitter)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }  // top-left origin, y down

    override func layout() {
        super.layout()
        emitter.frame = bounds
        emitter.emitterPosition = CGPoint(x: (bounds.width - island.width) / 2 + origin.x, y: origin.y)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !thrown else { return }
        thrown = true
        // Thrown once Clawd has put his laptop away and raised his arms, for a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.emitter.beginTime = CACurrentMediaTime()
            self.emitter.birthRate = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.emitter.birthRate = 0 }
        }
    }

    /// A 3-point square of one colour, thrown up and to the right, tumbling as it falls.
    private static func cell(_ color: NSColor) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = square
        cell.color = color.cgColor
        cell.birthRate = 55
        cell.lifetime = 2.2
        cell.lifetimeRange = 0.5
        cell.velocity = 210
        cell.velocityRange = 110
        cell.emissionLongitude = -.pi / 8  // y grows downwards: a little above the horizontal
        cell.emissionRange = .pi / 2.2
        cell.yAcceleration = 90
        cell.spin = 3
        cell.spinRange = 8
        cell.scaleRange = 0.35
        cell.alphaSpeed = -0.35
        return cell
    }

    private static let square: CGImage? = {
        let side = 3
        let pixels = [UInt8](repeating: 255, count: side * side * 4)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()
}
