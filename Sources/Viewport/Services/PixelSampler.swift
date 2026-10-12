import CoreGraphics
import Foundation

/// Reads pixels from pane frames for the color picker and loupe.
enum PixelSampler {
    /// Pixel coordinate (top-left origin) for a normalized point.
    static func pixel(for point: CGPoint, width: Int, height: Int) -> (x: Int, y: Int) {
        let x = min(max(Int((point.x * CGFloat(width)).rounded(.down)), 0), max(width - 1, 0))
        let y = min(max(Int((point.y * CGFloat(height)).rounded(.down)), 0), max(height - 1, 0))
        return (x, y)
    }

    static func color(
        in image: CGImage,
        at point: CGPoint,
        source: ViewerSource
    ) -> ColorSample? {
        let pixel = pixel(for: point, width: image.width, height: image.height)
        guard let crop = image.cropping(to: CGRect(x: pixel.x, y: pixel.y, width: 1, height: 1)) else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        let alpha = max(Int(bytes[3]), 1)
        // Un-premultiply so semi-transparent web pixels report their colour.
        let unpremultiply = { (value: UInt8) -> Int in
            min(255, Int((Double(value) * 255 / Double(alpha)).rounded()))
        }
        return ColorSample(
            source: source,
            red: unpremultiply(bytes[0]),
            green: unpremultiply(bytes[1]),
            blue: unpremultiply(bytes[2])
        )
    }

    /// Square of pixels centred on `point` for the magnifier.
    static func loupe(
        in image: CGImage,
        at point: CGPoint,
        radius: Int = 7
    ) -> CGImage? {
        let pixel = pixel(for: point, width: image.width, height: image.height)
        let rect = CGRect(
            x: pixel.x - radius,
            y: pixel.y - radius,
            width: radius * 2 + 1,
            height: radius * 2 + 1
        )
        return image.cropping(to: rect.intersection(
            CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ))
    }
}
