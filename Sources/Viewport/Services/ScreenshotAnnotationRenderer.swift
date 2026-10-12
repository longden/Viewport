import AppKit
import CoreGraphics
import CoreText
import Foundation

enum ScreenshotAnnotationKind: String, CaseIterable, Identifiable {
    case arrow
    case box
    case redact
    case text
    case step

    var id: String { rawValue }

    var title: String {
        switch self {
        case .arrow: "Arrow"
        case .box: "Box"
        case .redact: "Redact"
        case .text: "Text"
        case .step: "Step"
        }
    }

    var systemImage: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .box: "rectangle"
        case .redact: "rectangle.dashed"
        case .text: "textformat"
        case .step: "1.circle"
        }
    }

    /// Text and step callouts are placed with a click; dragging adds a leader line.
    var isCallout: Bool {
        self == .text || self == .step
    }
}

struct ScreenshotAnnotation: Identifiable, Equatable {
    let id: UUID
    var kind: ScreenshotAnnotationKind
    /// Normalized top-left origin (0…1) relative to image bounds.
    /// Callouts sit at `start`; `end` is the leader-line tip.
    var start: CGPoint
    var end: CGPoint
    /// Label for `.text` callouts.
    var text: String?
    /// Number shown in a `.step` marker.
    var number: Int?

    init(
        id: UUID = UUID(),
        kind: ScreenshotAnnotationKind,
        start: CGPoint,
        end: CGPoint,
        text: String? = nil,
        number: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.text = text
        self.number = number
    }

    /// The string drawn inside a callout, if any.
    var calloutText: String? {
        switch kind {
        case .text:
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        case .step:
            return number.map(String.init)
        case .arrow, .box, .redact:
            return nil
        }
    }

    /// Next number for a new step marker, continuing after the highest one placed.
    static func nextStepNumber(in annotations: [ScreenshotAnnotation]) -> Int {
        (annotations.compactMap { $0.kind == .step ? $0.number : nil }.max() ?? 0) + 1
    }
}

enum ScreenshotAnnotationRenderer {
    static let arrowLineWidth: CGFloat = 4
    static let boxLineWidth: CGFloat = 4
    static let arrowHeadLength: CGFloat = 18
    /// Large mosaic blocks so redaction is obviously unreadable.
    static let redactBlockSize: CGFloat = 18
    static let stepMarkerRadius: CGFloat = 15
    static let stepFontSize: CGFloat = 16
    static let textFontSize: CGFloat = 17
    static let textPadding = CGSize(width: 10, height: 6)
    static let textCornerRadius: CGFloat = 8
    static let leaderLineWidth: CGFloat = 3
    static let leaderDotRadius: CGFloat = 4
    /// Drags shorter than this (preview points) place a callout without a leader.
    static let minimumLeaderLength: CGFloat = 12

    /// Maps preview-canvas point sizes onto image pixels so export strokes match
    /// what was drawn on the fitted preview (aspect-fit).
    static func styleScale(
        imageWidth: Int,
        imageHeight: Int,
        previewSize: CGSize
    ) -> CGFloat {
        guard previewSize.width > 1, previewSize.height > 1 else { return 1 }
        return max(
            CGFloat(imageWidth) / previewSize.width,
            CGFloat(imageHeight) / previewSize.height
        )
    }

    static func render(
        _ image: CGImage,
        annotations: [ScreenshotAnnotation],
        styleScale: CGFloat = 1
    ) throws -> CGImage {
        let width = image.width
        let height = image.height
        let scale = max(styleScale, 0.01)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw WorkspaceScreenshotError.imageCreationFailed
        }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: bounds)

        for annotation in annotations {
            let start = denormalize(annotation.start, width: width, height: height)
            let end = denormalize(annotation.end, width: width, height: height)
            switch annotation.kind {
            case .arrow:
                drawArrow(from: start, to: end, scale: scale, in: context)
            case .box:
                drawBox(from: start, to: end, scale: scale, in: context)
            case .redact:
                pixelateRegion(
                    from: start,
                    to: end,
                    source: image,
                    in: context
                )
            case .text, .step:
                drawCallout(
                    annotation,
                    at: start,
                    leaderEnd: end,
                    scale: scale,
                    in: context
                )
            }
        }

        guard let result = context.makeImage() else {
            throw WorkspaceScreenshotError.imageCreationFailed
        }
        return result
    }

    /// Tip, left wing, right wing, and where the shaft should stop (base of tip).
    static func arrowGeometry(
        from start: CGPoint,
        to end: CGPoint,
        scale: CGFloat = 1
    ) -> (
        tip: CGPoint,
        left: CGPoint,
        right: CGPoint,
        shaftEnd: CGPoint
    ) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let head = arrowHeadLength * max(scale, 0.01)
        let left = CGPoint(
            x: end.x - head * cos(angle - .pi / 6),
            y: end.y - head * sin(angle - .pi / 6)
        )
        let right = CGPoint(
            x: end.x - head * cos(angle + .pi / 6),
            y: end.y - head * sin(angle + .pi / 6)
        )
        // Stop the shaft at the triangle base so it doesn't poke through the tip.
        let inset = head * cos(.pi / 6)
        let shaftEnd = CGPoint(
            x: end.x - inset * cos(angle),
            y: end.y - inset * sin(angle)
        )
        return (end, left, right, shaftEnd)
    }

    static func denormalize(
        _ point: CGPoint,
        width: Int,
        height: Int
    ) -> CGPoint {
        CGPoint(
            x: point.x * CGFloat(width),
            y: (1 - point.y) * CGFloat(height)
        )
    }

    /// Bottom-left CG coords → pixel crop rect (top-left image space).
    static func pixelCropRect(
        from start: CGPoint,
        to end: CGPoint,
        imageWidth: Int,
        imageHeight: Int
    ) -> CGRect {
        let minX = min(start.x, end.x)
        let maxX = max(start.x, end.x)
        let minY = min(start.y, end.y)
        let maxY = max(start.y, end.y)
        let topLeftY = CGFloat(imageHeight) - maxY
        return CGRect(
            x: floor(minX),
            y: floor(topLeftY),
            width: max(ceil(maxX - minX), 1),
            height: max(ceil(maxY - minY), 1)
        ).integral.intersection(
            CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        )
    }

    static func pixelatedImage(
        from source: CGImage,
        cropRect: CGRect,
        blockSize: CGFloat = redactBlockSize
    ) -> CGImage? {
        guard cropRect.width >= 1, cropRect.height >= 1,
              let cropped = source.cropping(to: cropRect) else {
            return nil
        }

        let block = max(blockSize, 8)
        let tinyWidth = max(1, Int((cropRect.width / block).rounded(.down)))
        let tinyHeight = max(1, Int((cropRect.height / block).rounded(.down)))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let tinyContext = CGContext(
            data: nil,
            width: tinyWidth,
            height: tinyHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        tinyContext.interpolationQuality = .none
        tinyContext.draw(
            cropped,
            in: CGRect(x: 0, y: 0, width: tinyWidth, height: tinyHeight)
        )
        guard let tiny = tinyContext.makeImage() else { return nil }

        let outWidth = max(Int(cropRect.width.rounded(.up)), 1)
        let outHeight = max(Int(cropRect.height.rounded(.up)), 1)
        guard let outContext = CGContext(
            data: nil,
            width: outWidth,
            height: outHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        outContext.interpolationQuality = .none
        outContext.draw(
            tiny,
            in: CGRect(x: 0, y: 0, width: outWidth, height: outHeight)
        )
        return outContext.makeImage()
    }

    private static func drawArrow(
        from start: CGPoint,
        to end: CGPoint,
        scale: CGFloat,
        in context: CGContext
    ) {
        let geometry = arrowGeometry(from: start, to: end, scale: scale)
        context.saveGState()
        context.setStrokeColor(NSColor.systemRed.cgColor)
        context.setFillColor(NSColor.systemRed.cgColor)
        context.setLineWidth(arrowLineWidth * scale)
        context.setLineCap(.round)
        context.move(to: start)
        context.addLine(to: geometry.shaftEnd)
        context.strokePath()

        context.move(to: geometry.tip)
        context.addLine(to: geometry.left)
        context.addLine(to: geometry.right)
        context.closePath()
        context.fillPath()
        context.restoreGState()
    }

    /// Whether a callout drag is long enough to draw a leader line.
    static func hasLeader(
        from start: CGPoint,
        to end: CGPoint,
        scale: CGFloat = 1
    ) -> Bool {
        hypot(end.x - start.x, end.y - start.y) >= minimumLeaderLength * max(scale, 0.01)
    }

    /// Leader start on the edge of a callout bubble so the line doesn't cross the label.
    static func leaderStart(
        bubble: CGRect,
        toward end: CGPoint
    ) -> CGPoint {
        let center = CGPoint(x: bubble.midX, y: bubble.midY)
        let dx = end.x - center.x
        let dy = end.y - center.y
        guard dx != 0 || dy != 0 else { return center }
        let halfWidth = max(bubble.width / 2, 0.01)
        let halfHeight = max(bubble.height / 2, 0.01)
        let factor = 1 / max(abs(dx) / halfWidth, abs(dy) / halfHeight)
        return CGPoint(x: center.x + dx * min(factor, 1), y: center.y + dy * min(factor, 1))
    }

    /// Bubble rect centred on `center` for a label of `textSize`.
    static func calloutBubble(
        kind: ScreenshotAnnotationKind,
        center: CGPoint,
        textSize: CGSize,
        scale: CGFloat = 1
    ) -> CGRect {
        let scale = max(scale, 0.01)
        if kind == .step {
            let radius = max(stepMarkerRadius * scale, textSize.width / 2 + 5 * scale)
            return CGRect(
                x: center.x - radius,
                y: center.y - stepMarkerRadius * scale,
                width: radius * 2,
                height: stepMarkerRadius * scale * 2
            )
        }
        let width = textSize.width + textPadding.width * 2 * scale
        let height = textSize.height + textPadding.height * 2 * scale
        return CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        )
    }

    static func calloutFont(
        for kind: ScreenshotAnnotationKind,
        scale: CGFloat
    ) -> NSFont {
        let size = (kind == .step ? stepFontSize : textFontSize) * max(scale, 0.01)
        return kind == .step
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
            : NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    private static func drawCallout(
        _ annotation: ScreenshotAnnotation,
        at center: CGPoint,
        leaderEnd: CGPoint,
        scale: CGFloat,
        in context: CGContext
    ) {
        guard let label = annotation.calloutText else { return }
        let font = calloutFont(for: annotation.kind, scale: scale)
        let attributed = NSAttributedString(
            string: label,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.white
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let textSize = CGSize(width: width, height: ascent + descent)
        let bubble = calloutBubble(
            kind: annotation.kind,
            center: center,
            textSize: textSize,
            scale: scale
        )
        let fill = annotation.kind == .step
            ? NSColor.systemRed.cgColor
            : NSColor.black.withAlphaComponent(0.82).cgColor

        context.saveGState()
        if hasLeader(from: center, to: leaderEnd, scale: scale) {
            let lineStart = leaderStart(bubble: bubble, toward: leaderEnd)
            context.setStrokeColor(NSColor.systemRed.cgColor)
            context.setFillColor(NSColor.systemRed.cgColor)
            context.setLineWidth(leaderLineWidth * scale)
            context.setLineCap(.round)
            context.move(to: lineStart)
            context.addLine(to: leaderEnd)
            context.strokePath()
            let dot = leaderDotRadius * scale
            context.fillEllipse(in: CGRect(
                x: leaderEnd.x - dot,
                y: leaderEnd.y - dot,
                width: dot * 2,
                height: dot * 2
            ))
        }

        context.setFillColor(fill)
        if annotation.kind == .step {
            let path = CGPath(
                roundedRect: bubble,
                cornerWidth: bubble.height / 2,
                cornerHeight: bubble.height / 2,
                transform: nil
            )
            context.addPath(path)
            context.fillPath()
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(2 * scale)
            context.addPath(path)
            context.strokePath()
        } else {
            let radius = textCornerRadius * scale
            context.addPath(CGPath(
                roundedRect: bubble,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            ))
            context.fillPath()
        }

        // CG space is bottom-left: the baseline sits `descent` above the bottom
        // of the vertically centred text block.
        context.textMatrix = .identity
        context.textPosition = CGPoint(
            x: bubble.midX - width / 2,
            y: bubble.midY - textSize.height / 2 + descent
        )
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func drawBox(
        from start: CGPoint,
        to end: CGPoint,
        scale: CGFloat,
        in context: CGContext
    ) {
        let rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        context.saveGState()
        context.setStrokeColor(NSColor.systemYellow.cgColor)
        context.setLineWidth(boxLineWidth * scale)
        context.stroke(rect)
        context.restoreGState()
    }

    private static func pixelateRegion(
        from start: CGPoint,
        to end: CGPoint,
        source: CGImage,
        in context: CGContext
    ) {
        let drawRect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: max(abs(end.x - start.x), 1),
            height: max(abs(end.y - start.y), 1)
        )
        let crop = pixelCropRect(
            from: start,
            to: end,
            imageWidth: source.width,
            imageHeight: source.height
        )
        context.saveGState()
        if crop.width >= 1, crop.height >= 1,
           let mosaic = pixelatedImage(from: source, cropRect: crop) {
            context.interpolationQuality = .none
            context.draw(mosaic, in: drawRect)
        } else {
            context.setFillColor(NSColor.black.cgColor)
            context.fill(drawRect)
        }
        context.restoreGState()
    }
}
