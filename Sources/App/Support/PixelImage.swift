import CoreGraphics
import Foundation

extension CGImage {
    /// A pixel-art picture from RGBA bytes (alpha premultiplied), row by row from the top.
    static func pixels(_ rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard rgba.count == width * height * 4, let provider = CGDataProvider(data: Data(rgba) as CFData),
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
