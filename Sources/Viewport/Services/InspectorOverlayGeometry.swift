import CoreGraphics

/// Maps inspector overlays onto the drawn pane frame. Shares the aspect-fit
/// contract of `DevicePreviewInputGeometry`: normalized points are top-left 0…1
/// of the displayed frame. SwiftUI overlay coordinates are already top-left.
enum InspectorOverlayGeometry {
    /// Aspect-fit rect of `contentSize` centred in `bounds`; the whole bounds
    /// when the content fills the pane (web).
    static func contentFrame(in bounds: CGSize, contentSize: CGSize?) -> CGRect {
        guard let contentSize,
              contentSize.width > 0, contentSize.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        return CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    static func normalized(_ point: CGPoint, in frame: CGRect) -> CGPoint? {
        guard frame.width > 0, frame.height > 0, frame.contains(point) else { return nil }
        return CGPoint(
            x: (point.x - frame.minX) / frame.width,
            y: (point.y - frame.minY) / frame.height
        )
    }

    /// Like `normalized` but clamps to the frame edges (drags that leave the frame).
    static func clampedNormalized(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        return CGPoint(
            x: min(max((point.x - frame.minX) / frame.width, 0), 1),
            y: min(max((point.y - frame.minY) / frame.height, 0), 1)
        )
    }

    static func point(_ normalized: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(
            x: frame.minX + normalized.x * frame.width,
            y: frame.minY + normalized.y * frame.height
        )
    }

    static func rect(_ normalized: CGRect, in frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX + normalized.minX * frame.width,
            y: frame.minY + normalized.minY * frame.height,
            width: normalized.width * frame.width,
            height: normalized.height * frame.height
        )
    }

    /// Positions in view space for grid lines `spacing` (normalized) apart.
    static func gridLines(spacing: CGFloat, length: CGFloat, origin: CGFloat) -> [CGFloat] {
        guard spacing > 0.0005, length > 0 else { return [] }
        let step = spacing * length
        guard step >= 2 else { return [] }
        var lines: [CGFloat] = []
        var position = step
        while position < length - 0.5 {
            lines.append(origin + position)
            position += step
        }
        return lines
    }

    /// Column rects (normalized x / width) for a layout grid.
    static func columns(
        count: Int,
        margin: CGFloat,
        gutter: CGFloat,
        screenWidth: CGFloat
    ) -> [ClosedRange<CGFloat>] {
        guard count > 0, screenWidth > 0 else { return [] }
        let available = screenWidth - margin * 2 - gutter * CGFloat(count - 1)
        guard available > 0 else { return [] }
        let columnWidth = available / CGFloat(count)
        return (0..<count).map { index in
            let start = margin + CGFloat(index) * (columnWidth + gutter)
            return (start / screenWidth)...((start + columnWidth) / screenWidth)
        }
    }
}
