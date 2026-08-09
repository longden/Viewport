import AppKit
import CoreGraphics
import Foundation

enum ScreenshotAnnotationKind: String, CaseIterable, Identifiable {
    case arrow
    case box
    case redact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .arrow: "Arrow"
        case .box: "Box"
        case .redact: "Redact"
        }
    }

    var systemImage: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .box: "rectangle"
        case .redact: "rectangle.dashed"
        }
    }
}

struct ScreenshotAnnotation: Identifiable, Equatable {
    let id: UUID
    var kind: ScreenshotAnnotationKind
    /// Normalized top-left origin (0…1) relative to image bounds.
    var start: CGPoint
    var end: CGPoint

    init(
        id: UUID = UUID(),
        kind: ScreenshotAnnotationKind,
        start: CGPoint,
        end: CGPoint
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
    }
}

enum ScreenshotAnnotationRenderer {
    static let arrowLineWidth: CGFloat = 4
    static let boxLineWidth: CGFloat = 4
    static let redactFillAlpha: CGFloat = 0.72
    static let redactStrokeAlpha: CGFloat = 0.35

    static func render(
        _ image: CGImage,
        annotations: [ScreenshotAnnotation]
    ) throws -> CGImage {
        let width = image.width
        let height = image.height
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
                drawArrow(from: start, to: end, in: context)
            case .box:
                drawBox(from: start, to: end, in: context)
            case .redact:
                redactRegion(from: start, to: end, in: context)
            }
        }

        guard let result = context.makeImage() else {
            throw WorkspaceScreenshotError.imageCreationFailed
        }
        return result
    }

    private static func denormalize(
        _ point: CGPoint,
        width: Int,
        height: Int
    ) -> CGPoint {
        CGPoint(
            x: point.x * CGFloat(width),
            y: (1 - point.y) * CGFloat(height)
        )
    }

    private static func drawArrow(
        from start: CGPoint,
        to end: CGPoint,
        in context: CGContext
    ) {
        context.saveGState()
        context.setStrokeColor(NSColor.systemRed.cgColor)
        context.setFillColor(NSColor.systemRed.cgColor)
        context.setLineWidth(arrowLineWidth)
        context.setLineCap(.round)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()

        let angle = atan2(end.y - start.y, end.x - start.x)
        let head: CGFloat = 18
        let left = CGPoint(
            x: end.x - head * cos(angle - .pi / 6),
            y: end.y - head * sin(angle - .pi / 6)
        )
        let right = CGPoint(
            x: end.x - head * cos(angle + .pi / 6),
            y: end.y - head * sin(angle + .pi / 6)
        )
        context.move(to: end)
        context.addLine(to: left)
        context.addLine(to: right)
        context.closePath()
        context.fillPath()
        context.restoreGState()
    }

    private static func drawBox(
        from start: CGPoint,
        to end: CGPoint,
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
        context.setLineWidth(boxLineWidth)
        context.stroke(rect)
        context.restoreGState()
    }

    private static func redactRegion(
        from start: CGPoint,
        to end: CGPoint,
        in context: CGContext
    ) {
        let rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: max(abs(end.x - start.x), 1),
            height: max(abs(end.y - start.y), 1)
        )
        context.saveGState()
        context.setFillColor(
            NSColor.black.withAlphaComponent(redactFillAlpha).cgColor
        )
        context.fill(rect)
        context.setStrokeColor(
            NSColor.white.withAlphaComponent(redactStrokeAlpha).cgColor
        )
        context.setLineWidth(1)
        context.stroke(rect)
        context.restoreGState()
    }
}
