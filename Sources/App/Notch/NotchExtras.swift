import AppKit
import IOKit.ps
import SwiftUI

/// What the notch shows on the right when it has no task's time to count (Clawd on his own, Claude
/// closed), picked in Clawd's menu: the time, the sun or the moon, the battery, a little wave, or nothing.
enum NotchExtra: String, CaseIterable {
    case clock, sky, battery, wave, none

    static let key = "notchExtra"

    static var current: NotchExtra {
        UserDefaults.standard.string(forKey: key).flatMap(NotchExtra.init(rawValue:)) ?? .clock
    }

    var name: String {
        switch self {
        case .clock: return tr("Часы", "Clock")
        case .sky: return tr("Солнце и луна", "Sun and moon")
        case .battery: return tr("Заряд батареи", "Battery")
        case .wave: return tr("Волна", "Wave")
        case .none: return tr("Ничего", "Nothing")
        }
    }

    /// The battery is only there to show on a Mac that has one.
    static var available: [NotchExtra] { allCases.filter { $0 != .battery || Battery.read() != nil } }
}

/// `moving`: the notch can be seen; while it can't, nothing here moves or wakes the app up.
struct NotchExtraView: View {
    let kind: NotchExtra
    var moving = true

    var body: some View {
        switch kind {
        case .clock: PixelClock(moving: moving)
        case .sky: PixelSky(moving: moving)
        case .battery: PixelBattery()
        case .wave: MiniWave(moving: moving)
        case .none: EmptyView()
        }
    }
}

// MARK: - Sun and moon

/// The sun by day, setting into the horizon at dusk and rising from it at dawn, and the moon with a
/// twinkling star at night, by the Mac's clock. It changes a few times a day; the star twinkles in Core
/// Animation, which wakes the app up for nothing.
private struct PixelSky: View {
    let moving: Bool

    var body: some View {
        PixelSkyLayer(moving: moving).frame(width: PixelSkyView.size.width, height: PixelSkyView.size.height)
    }
}

private struct PixelSkyLayer: NSViewRepresentable {
    let moving: Bool

    func makeNSView(context: Context) -> PixelSkyView { PixelSkyView() }
    func updateNSView(_ view: PixelSkyView, context: Context) { view.moving = moving }
}

final class PixelSkyView: NSView {
    static let pixel: CGFloat = 2
    static let size = CGSize(width: 13 * pixel, height: 9 * pixel)

    enum Time { case day, dusk, night }

    /// Dawn 5–8, day 8–18, dusk 18–21, night 21–5; and the hour the next one starts.
    static func time(at date: Date) -> (Time, nextHour: Int) {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 5..<8: return (.dusk, 8)
        case 8..<18: return (.day, 18)
        case 18..<21: return (.dusk, 21)
        default: return (.night, 5)
        }
    }

    private static let gold: UInt32 = 0xff_c8_3a_ff, rays: UInt32 = 0xff_e0_8a_ff
    static let sun = PixelArt("sun", [
        "....r....",
        ".r.....r.",
        "...ooo...",
        "..ooooo..",
        "r.ooooo.r",
        "..ooooo..",
        "...ooo...",
        ".r.....r.",
        "....r....",
    ], ["o": gold, "r": rays])
    static let sunset = PixelArt("sunset", [
        "...r...r...",
        "...........",
        "....ooo....",
        "...ooooo...",
        "..ooooooo..",
        "hhhhhhhhhhh",
        "...........",
        ".hh..hhh.hh",
        "....hh.....",
    ], ["o": 0xff_8f_38_ff, "r": 0xff_b3_5a_ff, "h": 0xe8_40_2a_ff])
    static let moon = PixelArt("moon", [
        "..mmm..",
        ".mmm...",
        "mmm....",
        "mmm....",
        "mmm....",
        "mmm....",
        ".mmm...",
        "..mmm..",
        ".......",
    ], ["m": 0xf2_df_b5_ff])
    static let star = PixelArt("star", [".s.", "sSs", ".s."], ["s": 0xff_e0_6a_ff, "S": 0xff_f6_c8_ff])
    static let dot = PixelArt("dot", ["s"], ["s": 0xd8_c8_a0_ff])

    var moving = true { didSet { if moving != oldValue { update() } } }
    private let picture = CALayer()
    private let twinkle = CALayer()
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for part in [picture, twinkle] {
            part.magnificationFilter = .nearest
            part.anchorPoint = .zero
            layer?.addSublayer(part)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        update()
    }

    private func place(_ part: CALayer, _ art: PixelArt, x: Int, y: Int) {
        part.contents = CGImage.pixels(art.rgba, width: art.width, height: art.height)
        part.frame = CGRect(x: CGFloat(x) * Self.pixel, y: CGFloat(y) * Self.pixel,
                            width: CGFloat(art.width) * Self.pixel, height: CGFloat(art.height) * Self.pixel)
    }

    private func update() {
        timer?.invalidate()
        timer = nil
        twinkle.removeAnimation(forKey: "twinkle")
        guard window != nil else { return }
        let now = Date()
        let (time, nextHour) = Self.time(at: now)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Right-aligned in 13 by 9 pixels.
        switch time {
        case .day: place(picture, Self.sun, x: 4, y: 0)
        case .dusk: place(picture, Self.sunset, x: 2, y: 0)
        case .night:
            var night = [UInt8](repeating: 0, count: 13 * 9 * 4)
            for (art, x, y) in [(Self.moon, 0, 0), (Self.dot, 12, 7), (Self.dot, 8, 6)] {
                for row in 0..<art.height {
                    for column in 0..<art.width {
                        let from = (row * art.width + column) * 4
                        guard art.rgba[from + 3] > 0 else { continue }
                        let at = ((y + row) * 13 + x + column) * 4
                        night.replaceSubrange(at..<(at + 4), with: art.rgba[from..<(from + 4)])
                    }
                }
            }
            picture.contents = CGImage.pixels(night, width: 13, height: 9)
            picture.frame = CGRect(origin: .zero, size: Self.size)
            place(twinkle, Self.star, x: 9, y: 1)
        }
        twinkle.isHidden = time != .night
        CATransaction.commit()

        guard moving else { return }
        if time == .night {
            let blink = CAKeyframeAnimation(keyPath: "opacity")
            blink.values = [1, 0.35, 1, 0.6]
            blink.keyTimes = [0, 0.3, 0.55, 0.8]
            blink.calculationMode = .discrete
            blink.duration = 3.2
            blink.repeatCount = .infinity
            blink.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: 4, preferred: 2)
            twinkle.add(blink, forKey: "twinkle")
        }
        // Back when the next part of the day starts.
        var parts = Calendar.current.dateComponents([.year, .month, .day], from: now)
        parts.hour = nextHour
        var next = Calendar.current.date(from: parts) ?? now.addingTimeInterval(3600)
        if next <= now { next = Calendar.current.date(byAdding: .day, value: 1, to: next) ?? now.addingTimeInterval(3600) }
        let timer = Timer(fire: next.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in self?.update() }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

// MARK: - Battery

/// The Mac's battery: how full it is, and whether it's charging. Nil on a Mac without one.
enum Battery {
    static func read() -> (level: Int, charging: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = description[kIOPSIsChargingKey] as? Bool == true
                || description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return (current * 100 / max, charging)
        }
        return nil
    }

    /// The battery in pixels: an outline with four bars, green, orange when low, red when nearly empty, and a
    /// bolt beside it while charging. 20 pixels by 7.
    static func picture(level: Int, charging: Bool) -> CGImage? {
        let width = 20, height = 7
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        func set(_ x: Int, _ y: Int, _ color: UInt32) {
            let at = (y * width + x) * 4
            rgba.replaceSubrange(at..<(at + 4), with: [UInt8(color >> 24 & 0xff), UInt8(color >> 16 & 0xff),
                                                       UInt8(color >> 8 & 0xff), UInt8(color & 0xff)])
        }
        if charging {
            for (y, row) in ["..#", ".#.", "###", ".#.", "#.."].enumerated() {
                for (x, pixel) in row.enumerated() where pixel == "#" { set(x, y + 1, 0xff_d2_3f_ff) }
            }
        }
        // The outline, 15 by 7 from x 4, and its tip.
        let outline: UInt32 = 0x9a_a0_a6_ff
        for x in 4...18 { set(x, 0, outline); set(x, 6, outline) }
        for y in 0...6 { set(4, y, outline); set(18, y, outline) }
        for y in 2...4 { set(19, y, outline) }
        // Four bars, 2 pixels wide, one for each quarter; at least one while there's anything left.
        let bars = level >= 88 ? 4 : level >= 63 ? 3 : level >= 38 ? 2 : level > 0 ? 1 : 0
        let fill: UInt32 = level <= 20 ? 0xe8_37_2a_ff : level <= 40 ? 0xff_b3_3a_ff : 0x5c_db_6e_ff
        for bar in 0..<bars {
            for x in (6 + bar * 3)...(7 + bar * 3) { for y in 2...4 { set(x, y, fill) } }
        }
        return CGImage.pixels(rgba, width: width, height: height)
    }
}

/// Watches the battery from the system's own notices, so it never polls.
private final class BatteryWatch: ObservableObject {
    static let shared = BatteryWatch()
    @Published private(set) var state = Battery.read()

    private init() {
        let source = IOPSNotificationCreateRunLoopSource({ _ in
            DispatchQueue.main.async { BatteryWatch.shared.state = Battery.read() }
        }, nil)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    }
}

private struct PixelBattery: View {
    @ObservedObject private var watch = BatteryWatch.shared

    var body: some View {
        if let state = watch.state, let picture = Battery.picture(level: state.level, charging: state.charging) {
            Image(decorative: picture, scale: 0.5)  // 2 points a pixel
                .interpolation(.none)
                .help("\(state.level)%")
        }
    }
}

// MARK: - A little wave

/// A short piece of the red and orange wave, running all the time while the notch can be seen: the
/// liveliest thing here, and the only one that wakes the app up several times a second.
private struct MiniWave: View {
    let moving: Bool

    private static let pixel: CGFloat = 2, columns = 20, length = 10.0, height = 2.0, speed = 5.0
    private static let red = (0.91, 0.22, 0.16), orange = (1.0, 0.56, 0.22)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 10, paused: !moving)) { context in
            Canvas { ctx, size in
                let t = context.date.timeIntervalSinceReferenceDate
                let middle = ((size.height / Self.pixel - 1) / 2).rounded(.down)
                for i in 0..<Self.columns {
                    let rise = Self.height * sin((Double(i) - t * Self.speed) / Self.length * 2 * .pi)
                    let row = middle - rise.rounded()
                    let level = (rise + Self.height) / (2 * Self.height)
                    let (r, g, b) = (Self.red.0 + (Self.orange.0 - Self.red.0) * level, Self.red.1 + (Self.orange.1 - Self.red.1) * level,
                                     Self.red.2 + (Self.orange.2 - Self.red.2) * level)
                    let opacity = Double(min(i + 1, Self.columns - i, 3)) / 3
                    func dot(_ row: CGFloat) -> Path {
                        Path(CGRect(x: CGFloat(i) * Self.pixel, y: row * Self.pixel, width: Self.pixel, height: Self.pixel))
                    }
                    ctx.fill(dot(row + 1), with: .color(Color(.sRGB, red: r * 0.4, green: g * 0.4, blue: b * 0.4, opacity: opacity)))
                    ctx.fill(dot(row), with: .color(Color(.sRGB, red: r, green: g, blue: b, opacity: opacity)))
                }
            }
        }
        .frame(width: CGFloat(Self.columns) * Self.pixel, height: 7 * Self.pixel)
        .allowsHitTesting(false)
    }
}
