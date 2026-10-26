import AppKit
import SwiftUI

/// Clawd facing you from behind his open laptop, his face lit by its screen, on a warm cream tile with a pale sun
/// behind him. A 32 × 32 picture on the macOS squircle (the 824/1024 grid) with a soft shadow.
struct AppIcon: View {
    let size: CGFloat

    var body: some View {
        let inner = size * 824 / 1024
        Image(decorative: IconScene.image, scale: 1)
            .resizable()
            // Crisp pixels; smoothed only where there's no room for them.
            .interpolation(inner >= 2 * CGFloat(IconScene.size) ? .none : .high)
            .frame(width: inner, height: inner)
            .clipShape(RoundedRectangle(cornerRadius: inner * 0.225, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: size * 0.02, y: size * 0.012)
            .frame(width: size, height: size)
    }
}

/// The picture, pixel by pixel, each part over the last; all of it centred on the middle two columns.
enum IconScene {
    static let size = 32

    private static let colors: [Character: UInt32] = [
        // The tile and the sun.
        "c": 0xf3_ea_db_ff, "s": 0xf6_d7_c0_ff,
        // Clawd: body, eyes, his face where the screen lights it.
        "#": 0xd9_77_57_ff, "o": 0x1f_1a_17_ff, "+": 0xe8_93_6f_ff,
        // The laptop: the lid's top edge, the lid, its logo; the base's top and front; its shadow on the ground.
        "T": 0xe4_e8_ef_ff, "L": 0xc7_cd_d8_ff, "e": 0xf1_f3_f7_ff, "B": 0x9b_a2_b1_ff, "b": 0x7d_84_94_ff,
        "_": 0xe8_da_c4_ff,
    ]

    /// Over his body: the lid, rounded at the top, with a round logo on it.
    private static let lid = [
        ".TTTTTTTTTTTT.",
        "LLLLLLLLLLLLLL",
        "LLLLLLLLLLLLLL",
        "LLLLLLeeLLLLLL",
        "LLLLLeeeeLLLLL",
        "LLLLLeeeeLLLLL",
        "LLLLLLeeLLLLLL",
        "LLLLLLLLLLLLLL",
        "LLLLLLLLLLLLLL",
    ]
    /// Under it and wider, over his legs; then its shadow.
    private static let base = [
        ".BBBBBBBBBBBBBBBB.",
        "bbbbbbbbbbbbbbbbbb",
    ]
    private static let shadow = [".__________________."]

    static let pixels: [UInt32] = {
        var pixels = [UInt32](repeating: colors["c"]!, count: size * size)
        func set(_ x: Int, _ y: Int, _ color: UInt32) {
            if (0..<size).contains(x), (0..<size).contains(y) { pixels[y * size + x] = color }
        }
        func put(_ rows: [String], _ x: Int, _ y: Int) {
            for (dy, row) in rows.enumerated() {
                for (dx, char) in row.enumerated() {
                    if let color = colors[char] { set(x + dx, y + dy, color) }
                }
            }
        }
        // The sun, its edge checkered.
        for y in 0..<size {
            for x in 0..<size {
                let d = pow(Double(x) - 15.5, 2) + pow(Double(y) - 14.5, 2)
                if d <= 11.5 * 11.5 || (d <= 12.5 * 12.5 && (x + y) % 2 == 0) { set(x, y, colors["s"]!) }
            }
        }
        // Clawd as the app draws him, facing you, two pixels to his cells.
        ClawdSprite.draw(.front, unit: 1, eyesOpen: true) { rect, pixel in
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    set(x + 2, y + 6, colors[pixel == .eye ? "o" : "#"]!)
                }
            }
        }
        put(["++++++++++++"], 10, 12)  // the screen's light on his face
        put(lid, 9, 13)
        put(base, 7, 22)
        put(shadow, 6, 24)
        return pixels
    }()

    static let image: CGImage = {
        let rgba = pixels.flatMap { [UInt8($0 >> 24 & 0xff), UInt8($0 >> 16 & 0xff), UInt8($0 >> 8 & 0xff), UInt8($0 & 0xff)] }
        return CGImage.pixels(rgba, width: size, height: size)!
    }()
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
