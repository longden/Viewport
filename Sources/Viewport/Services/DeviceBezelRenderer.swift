import CoreGraphics
import Foundation

/// Optional decorative device chassis around capture frames.
/// Off by default so screenshots stay max-pixel. Uses simple geometric
/// chrome inspired by phone outlines (not vendor skin assets).
enum DeviceBezelRenderer {
    struct Metrics: Equatable {
        var outerInset: CGFloat
        var cornerRadius: CGFloat
        var frameColor: CGColor
        var screenCornerRadius: CGFloat

        static let phone = Metrics(
            outerInset: 14,
            cornerRadius: 28,
            frameColor: CGColor(gray: 0.12, alpha: 1),
            screenCornerRadius: 18
        )
    }

    static func draw(
        image: CGImage,
        metrics: Metrics = .phone
    ) -> CGImage? {
        autoreleasepool {
            drawBezel(image: image, metrics: metrics)
        }
    }

    private static func drawBezel(
        image: CGImage,
        metrics: Metrics
    ) -> CGImage? {
        let inset = metrics.outerInset
        let width = CGFloat(image.width) + inset * 2
        let height = CGFloat(image.height) + inset * 2
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: Int(width.rounded()),
            height: Int(height.rounded()),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        let outer = CGRect(x: 0, y: 0, width: width, height: height)
        let screen = outer.insetBy(dx: inset, dy: inset)

        context.setFillColor(metrics.frameColor)
        context.addPath(
            CGPath(
                roundedRect: outer,
                cornerWidth: metrics.cornerRadius,
                cornerHeight: metrics.cornerRadius,
                transform: nil
            )
        )
        context.fillPath()

        context.saveGState()
        context.addPath(
            CGPath(
                roundedRect: screen,
                cornerWidth: metrics.screenCornerRadius,
                cornerHeight: metrics.screenCornerRadius,
                transform: nil
            )
        )
        context.clip()
        context.draw(image, in: screen)
        context.restoreGState()

        // Subtle speaker notch / camera capsule for product-ready look.
        let capsuleWidth = min(width * 0.28, 120)
        let capsule = CGRect(
            x: (width - capsuleWidth) / 2,
            y: inset * 0.35,
            width: capsuleWidth,
            height: max(inset * 0.45, 6)
        )
        context.setFillColor(CGColor(gray: 0.05, alpha: 1))
        context.addPath(
            CGPath(
                roundedRect: capsule,
                cornerWidth: capsule.height / 2,
                cornerHeight: capsule.height / 2,
                transform: nil
            )
        )
        context.fillPath()

        return context.makeImage()
    }
}
