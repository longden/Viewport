import AppKit
import CoreGraphics
import Foundation

enum OverlayDiffError: LocalizedError {
    case missingBase
    case missingOverlay
    case imageCreationFailed

    var errorDescription: String? {
        switch self {
        case .missingBase:
            "Choose a base pane that has a live frame."
        case .missingOverlay:
            "Choose an overlay pane that has a live frame."
        case .imageCreationFailed:
            "The onion-skin composite could not be created."
        }
    }
}

/// Stacks two pane captures for cross-platform layout comparison.
enum OverlayDiffComposer {
    static func compose(
        base: CGImage,
        overlay: CGImage,
        opacity: Double
    ) throws -> CGImage {
        let opacity = min(max(opacity, 0), 1)
        let width = max(base.width, overlay.width)
        let height = max(base.height, overlay.height)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw OverlayDiffError.imageCreationFailed
        }

        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let baseRect = centeredRect(
            for: CGSize(width: base.width, height: base.height),
            in: CGSize(width: width, height: height)
        )
        let overlayRect = centeredRect(
            for: CGSize(width: overlay.width, height: overlay.height),
            in: CGSize(width: width, height: height)
        )

        context.interpolationQuality = .high
        context.setAlpha(1)
        context.draw(base, in: baseRect)
        context.setAlpha(CGFloat(opacity))
        context.draw(overlay, in: overlayRect)

        guard let image = context.makeImage() else {
            throw OverlayDiffError.imageCreationFailed
        }
        return image
    }

    private static func centeredRect(
        for size: CGSize,
        in canvas: CGSize
    ) -> CGRect {
        let scale = min(
            canvas.width / max(size.width, 1),
            canvas.height / max(size.height, 1)
        )
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(
            x: (canvas.width - width) / 2,
            y: (canvas.height - height) / 2,
            width: width,
            height: height
        )
    }
}
