import AppKit
import SwiftUI

/// The time in pixel digits, orange at the top and red at the bottom like the wave, where the notch has
/// nothing else to show on the right: Clawd on his own, with no task's time to count. The digits change
/// once a minute and the colon blinks in Core Animation, so the clock hardly ever wakes the app up; while
/// the notch can't be seen (`moving` false) it holds still.
struct PixelClock: View {
    var moving = true

    var body: some View {
        PixelClockLayer(moving: moving)
            .frame(width: PixelClockView.size.width, height: PixelClockView.size.height)
    }
}

private struct PixelClockLayer: NSViewRepresentable {
    let moving: Bool

    func makeNSView(context: Context) -> PixelClockView { PixelClockView() }
    func updateNSView(_ view: PixelClockView, context: Context) { view.moving = moving }
}

final class PixelClockView: NSView {
    /// Points per pixel, and room for the widest time, "12:59": 17 pixels by 5.
    static let pixel: CGFloat = 2
    static let size = CGSize(width: 17 * pixel, height: 5 * pixel)

    var moving = true { didSet { if moving != oldValue { update() } } }
    private let digits = CALayer()
    private let colon = CALayer()
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for part in [digits, colon] {
            part.magnificationFilter = .nearest  // crisp pixels
            part.anchorPoint = .zero
            layer?.addSublayer(part)
        }
        colon.contents = Self.picture(":")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        update()
    }

    /// Shows the time now and comes back when the minute changes; the colon blinks in between.
    private func update() {
        timer?.invalidate()
        timer = nil
        colon.removeAnimation(forKey: "blink")
        guard window != nil else { return }

        let time = Self.text(Date())
        // Right-aligned, hours and minutes apart where the colon blinks.
        let parts = time.split(separator: ":", maxSplits: 1).map(String.init)
        let width = Self.width(time)
        let left = Self.size.width - CGFloat(width) * Self.pixel
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        digits.contents = Self.picture(time.replacingOccurrences(of: ":", with: " "))
        digits.frame = CGRect(x: left, y: 0, width: CGFloat(width) * Self.pixel, height: Self.size.height)
        colon.frame = CGRect(x: left + CGFloat(Self.width(parts[0]) + 1) * Self.pixel, y: 0,
                             width: Self.pixel, height: Self.size.height)
        CATransaction.commit()

        guard moving else { return }
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 0.15]
        blink.keyTimes = [0, 0.5]
        blink.calculationMode = .discrete
        blink.duration = 2
        blink.repeatCount = .infinity
        blink.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: 4, preferred: 2)
        colon.add(blink, forKey: "blink")

        let now = Date().timeIntervalSinceReferenceDate
        let next = Timer(fire: Date(timeIntervalSinceReferenceDate: (now / 60).rounded(.down) * 60 + 60.05), interval: 0,
                         repeats: false) { [weak self] _ in self?.update() }
        next.tolerance = 1
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    // MARK: - Pixel digits

    /// The time as the Mac shows it, 24- or 12-hour, without AM or PM: "14:07", "2:07".
    static func text(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return String(formatter.string(from: date).filter { $0.isASCII && ($0.isNumber || $0 == ":") })
    }

    /// 3 by 5 pixels a digit, a pixel apart; the colon (and a space in its place) is 1 wide.
    private static let glyphs: [Character: [String]] = [
        "0": ["###", "#.#", "#.#", "#.#", "###"],
        "1": [".#.", "##.", ".#.", ".#.", "###"],
        "2": ["###", "..#", "###", "#..", "###"],
        "3": ["###", "..#", ".##", "..#", "###"],
        "4": ["#.#", "#.#", "###", "..#", "..#"],
        "5": ["###", "#..", "###", "..#", "###"],
        "6": ["###", "#..", "###", "#.#", "###"],
        "7": ["###", "..#", ".#.", ".#.", ".#."],
        "8": ["###", "#.#", "###", "#.#", "###"],
        "9": ["###", "#.#", "###", "..#", "###"],
        ":": [".", "#", ".", "#", "."],
        " ": [".", ".", ".", ".", "."],
    ]

    /// The text's width in pixels.
    static func width(_ text: String) -> Int {
        let glyphs = text.compactMap { Self.glyphs[$0] }
        return glyphs.map { $0[0].count }.reduce(0, +) + max(0, glyphs.count - 1)
    }

    /// The text in pixels, row by row from orange at the top to red at the bottom.
    static func picture(_ text: String) -> CGImage? {
        let width = Self.width(text)
        guard width > 0 else { return nil }
        let orange = (1.0, 0.56, 0.22), red = (0.91, 0.22, 0.16)
        var rgba = [UInt8](repeating: 0, count: width * 5 * 4)
        var x = 0
        for glyph in text.compactMap({ glyphs[$0] }) {
            for (y, row) in glyph.enumerated() {
                let p = Double(y) / 4
                let color = [orange.0 + (red.0 - orange.0) * p, orange.1 + (red.1 - orange.1) * p, orange.2 + (red.2 - orange.2) * p]
                for (dx, pixel) in row.enumerated() where pixel == "#" {
                    let at = (y * width + x + dx) * 4
                    rgba.replaceSubrange(at..<(at + 4), with: color.map { UInt8($0 * 255) } + [255])
                }
            }
            x += glyph[0].count + 1
        }
        return CGImage.pixels(rgba, width: width, height: 5)
    }
}
