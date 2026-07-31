import CoreGraphics

enum InputAccessPhase: Equatable {
    case ready
    case permissionNeeded

    var label: String {
        switch self {
        case .ready:
            "Interactive"
        case .permissionNeeded:
            "Input unavailable"
        }
    }
}

enum DevicePreviewInputGeometry {
    static func normalizedPoint(
        _ point: CGPoint,
        in destinationBounds: CGRect,
        sourceSize: CGSize,
        clampsToDisplayedFrame: Bool = false
    ) -> CGPoint? {
        guard destinationBounds.width > 0,
              destinationBounds.height > 0,
              sourceSize.width > 0,
              sourceSize.height > 0 else {
            return nil
        }

        let scale = min(
            destinationBounds.width / sourceSize.width,
            destinationBounds.height / sourceSize.height
        )
        let displayedSize = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
        let displayedFrame = CGRect(
            x: destinationBounds.midX - displayedSize.width / 2,
            y: destinationBounds.midY - displayedSize.height / 2,
            width: displayedSize.width,
            height: displayedSize.height
        )

        let isInside = point.x >= displayedFrame.minX
            && point.x <= displayedFrame.maxX
            && point.y >= displayedFrame.minY
            && point.y <= displayedFrame.maxY
        guard isInside || clampsToDisplayedFrame else {
            return nil
        }

        return CGPoint(
            x: clamp((point.x - displayedFrame.minX) / displayedFrame.width),
            // AppKit view coordinates start at the bottom-left; device
            // screenshot and HID coordinates start at the top-left.
            y: clamp(1 - (point.y - displayedFrame.minY) / displayedFrame.height)
        )
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}
