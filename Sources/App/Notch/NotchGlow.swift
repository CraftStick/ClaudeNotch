import AppKit
import SwiftUI

/// A soft glow around the island in Claude's orange, slowly breathing, while Claude waits for you: seen
/// from the corner of your eye without the notch having to open.
///
/// Like the rim, it breathes in a Core Animation layer, so the app does no work per frame; a shadow
/// drawn from the island's outline, so there's no picture and no mask. The layer covers a view of a
/// fixed size and place, the island hanging from its top centre.
struct NotchGlow: NSViewRepresentable {
    /// The island's size now, and the radius of its bottom corners.
    let island: CGSize
    let radius: CGFloat

    func makeNSView(context: Context) -> NotchGlowView { NotchGlowView() }

    func updateNSView(_ view: NotchGlowView, context: Context) {
        view.shape = (island, radius)
    }
}

final class NotchGlowView: NSView {
    private let glow = CALayer()
    var shape: (island: CGSize, radius: CGFloat) = (.zero, 0) {
        didSet { if shape != oldValue { place(animated: true) } }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        glow.shadowColor = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1).cgColor
        glow.shadowOffset = .zero
        glow.shadowRadius = 9
        glow.shadowOpacity = 1
        layer?.addSublayer(glow)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }  // top-left origin

    override func layout() {
        super.layout()
        place(animated: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        place(animated: false)
    }

    /// Fits the glow to the island, following it as it opens and closes, and keeps it breathing.
    private func place(animated: Bool) {
        let (island, radius) = shape
        // From above the top edge: the top corners are under the menu bar, only the sides and bottom glow.
        let rect = CGRect(x: (bounds.width - island.width) / 2, y: -radius, width: island.width, height: island.height + radius)
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.35)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        glow.frame = bounds
        glow.shadowPath = island.width > 0 ? CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil) : nil
        CATransaction.commit()

        guard window != nil, glow.animation(forKey: "breathe") == nil else { return }
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.3
        breathe.toValue = 0.95
        breathe.duration = 1.4
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // A slow fade: 15 frames a second look as smooth, and the screen redraws that corner less often.
        breathe.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 15, preferred: 15)
        glow.add(breathe, forKey: "breathe")
    }
}
