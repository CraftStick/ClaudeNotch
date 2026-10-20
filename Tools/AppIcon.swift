import AppKit
import SwiftUI

/// Clawd facing you, big, on a dark tile: the macOS squircle on the 824/1024 grid with a soft shadow.
struct AppIcon: View {
    let size: CGFloat

    var body: some View {
        let inner = size * 824 / 1024
        let cell = inner * 0.026
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.15, blue: 0.14), Color(red: 0.07, green: 0.07, blue: 0.07)],
                           startPoint: .top, endPoint: .bottom)
            Canvas { ctx, _ in
                // One path per color, so neighbouring pixels never show seams.
                var body = Path(), eyes = Path()
                ClawdSprite.draw(.front, unit: cell, eyesOpen: true) { rect, pixel in
                    if pixel == .eye { eyes.addRect(rect) } else { body.addRect(rect) }
                }
                ctx.fill(body, with: .color(Color(red: 0.85, green: 0.47, blue: 0.34)))
                ctx.fill(eyes, with: .color(.black))
            }
            .frame(width: CGFloat(ClawdSprite.columns) * cell, height: CGFloat(ClawdSprite.rows) * cell)
        }
        .frame(width: inner, height: inner)
        .clipShape(RoundedRectangle(cornerRadius: inner * 0.225, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: size * 0.02, y: size * 0.012)
        .frame(width: size, height: size)
    }
}

/// Writes every size of the icon into the .iconset folder given as the argument.
@main
enum MakeAppIcon {
    @MainActor static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let renderer = ImageRenderer(content: AppIcon(size: CGFloat(points * scale)))
                renderer.scale = 1
                let png = NSBitmapImageRep(cgImage: renderer.cgImage!).representation(using: .png, properties: [:])!
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                try png.write(to: folder.appendingPathComponent(name))
            }
        }
    }
}
