import AppKit
import SwiftUI

/// The disk image's window: a warm light background (Finder draws the icons' names in black in light
/// mode, and can't be told otherwise) with an arrow from Claude Notch to Applications and a hint below.
/// make-dmg.sh puts the icons on `left` and `right`.
struct DmgBackground: View {
    static let size = CGSize(width: 600, height: 380)
    /// Taller than the window by a title bar: Finder may count it in the window's bounds or not.
    static let canvas = CGSize(width: size.width, height: size.height + 28)
    /// High enough for all of it to show above Finder's path bar, which takes the bottom of the window when
    /// it's switched on (View → Show Path Bar).
    static let left = CGPoint(x: 160, y: 130)
    static let right = CGPoint(x: 440, y: 130)

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.985, green: 0.975, blue: 0.96), Color(red: 0.94, green: 0.925, blue: 0.9)],
                           startPoint: .top, endPoint: .bottom)
            Arrow()
                .stroke(Color(red: 0.85, green: 0.47, blue: 0.34), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                .frame(width: 104, height: 28)
                .position(x: (Self.left.x + Self.right.x) / 2, y: Self.left.y - 6)
            VStack(spacing: 4) {
                Text("Перетащи Claude Notch в «Программы»")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(white: 0.25))
                Text("Drag Claude Notch to Applications")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.45))
            }
            .frame(width: Self.size.width)
            .position(x: Self.size.width / 2, y: 245)
            // Apple hasn't notarized the app: the first launch needs a click in System Settings, and few
            // people read the release notes.
            VStack(spacing: 3) {
                Text("Первый запуск: Настройки → Конфиденциальность и безопасность → «Всё равно открыть»")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(white: 0.3))
                Text("First launch: System Settings → Privacy & Security → Open Anyway")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(white: 0.45))
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(red: 0.85, green: 0.47, blue: 0.34).opacity(0.1)))
            .position(x: Self.size.width / 2, y: 300)
        }
        .frame(width: Self.canvas.width, height: Self.canvas.height)
    }
}

/// A gentle arc with an open head, pointing right.
private struct Arrow: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let start = CGPoint(x: r.minX + 2, y: r.midY + 6)
        let end = CGPoint(x: r.maxX - 4, y: r.midY + 6)
        p.move(to: start)
        p.addQuadCurve(to: end, control: CGPoint(x: r.midX, y: r.minY - 6))
        p.move(to: CGPoint(x: end.x - 14, y: end.y - 13))
        p.addLine(to: end)
        p.addLine(to: CGPoint(x: end.x - 17, y: end.y + 4))
        return p
    }
}

/// Writes background.png and background@2x.png into the folder given as the argument.
@main
enum MakeDmgBackground {
    @MainActor static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for scale in [1, 2] {
            let renderer = ImageRenderer(content: DmgBackground())
            renderer.scale = CGFloat(scale)
            let image = NSBitmapImageRep(cgImage: renderer.cgImage!)
            image.size = DmgBackground.canvas  // points, so the @2x one counts as Retina
            let png = image.representation(using: .png, properties: [:])!
            try png.write(to: folder.appendingPathComponent(scale == 1 ? "background.png" : "background@2x.png"))
        }
    }
}
