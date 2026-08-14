import CoreGraphics

/// Maps preview pointer locations into device input space.
///
/// Contract:
/// - Output is **top-left normalized 0…1** relative to the currently displayed
///   frame (aspect-fit inside the preview; AppKit Y is flipped).
/// - Surface / screencap / gRPC / scrcpy / USB frames are already device pixels —
///   do **not** apply chrome insets before HID or injection.
/// - Host-window (ScreenCaptureKit) frames include Simulator/Emulator chrome;
///   capture must crop with `hostWindowChromeInsets` + `hostWindowContentRect`
///   so display space matches framebuffer space used by input.
enum InputAccessPhase: Equatable {
    case ready
    case permissionNeeded
    case viewOnly

    var label: String {
        switch self {
        case .ready:
            "Interactive"
        case .permissionNeeded:
            "Input unavailable"
        case .viewOnly:
            "View only"
        }
    }
}

enum DevicePreviewInputGeometry {
    struct EdgeInsets: Equatable {
        var top: CGFloat
        var left: CGFloat
        var bottom: CGFloat
        var right: CGFloat

        static let zero = EdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    /// Host-window capture includes Simulator / Emulator chrome. Strip the
    /// typical title-bar (and light toolbar) so the stream shows device pixels.
    static func hostWindowChromeInsets(
        for source: ViewerSource
    ) -> EdgeInsets {
        switch source {
        case .android:
            // Android Emulator title bar + menu strip.
            EdgeInsets(top: 56, left: 0, bottom: 0, right: 0)
        case .iOS:
            // Simulator title bar with traffic lights.
            EdgeInsets(top: 52, left: 0, bottom: 0, right: 0)
        case .web:
            .zero
        }
    }

    static func normalizedPoint(
        _ point: CGPoint,
        in destinationBounds: CGRect,
        sourceSize: CGSize,
        clampsToDisplayedFrame: Bool = false,
        flipsYFromAppKit: Bool = true
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

        return normalizedPoint(
            point,
            displayedFrame: displayedFrame,
            clampsToDisplayedFrame: clampsToDisplayedFrame,
            flipsYFromAppKit: flipsYFromAppKit
        )
    }

    /// Maps a pointer into the **actually drawn** preview rect (e.g. the
    /// aspect-fitted `displayLayer.frame`), not a second recomputed fit.
    static func normalizedPoint(
        _ point: CGPoint,
        displayedFrame: CGRect,
        clampsToDisplayedFrame: Bool = false,
        flipsYFromAppKit: Bool = true
    ) -> CGPoint? {
        guard displayedFrame.width > 0, displayedFrame.height > 0 else {
            return nil
        }

        let isInside = point.x >= displayedFrame.minX
            && point.x <= displayedFrame.maxX
            && point.y >= displayedFrame.minY
            && point.y <= displayedFrame.maxY
        guard isInside || clampsToDisplayedFrame else {
            return nil
        }

        let x = clamp((point.x - displayedFrame.minX) / displayedFrame.width)
        let yInFrame = (point.y - displayedFrame.minY) / displayedFrame.height
        // AppKit view coordinates start at the bottom-left unless the view is
        // flipped; device framebuffer / HID coordinates are top-left.
        let y = flipsYFromAppKit ? clamp(1 - yInFrame) : clamp(yInFrame)
        return CGPoint(x: x, y: y)
    }

    /// Content rect inside a host window: chrome removed, then fitted to the
    /// device framebuffer aspect. Top-aligned in the remaining area so the
    /// title bar stays out of frame.
    static func hostWindowContentRect(
        windowSize: CGSize,
        deviceAspect: CGSize?,
        chromeInsets: EdgeInsets
    ) -> CGRect? {
        guard windowSize.width > 0, windowSize.height > 0 else {
            return nil
        }

        let inset = CGRect(
            x: chromeInsets.left,
            y: chromeInsets.top,
            width: windowSize.width - chromeInsets.left - chromeInsets.right,
            height: windowSize.height - chromeInsets.top - chromeInsets.bottom
        )
        guard inset.width > 32, inset.height > 32 else {
            return CGRect(origin: .zero, size: windowSize)
        }

        guard let deviceAspect,
              deviceAspect.width > 0,
              deviceAspect.height > 0,
              let fitted = centerCroppedRect(
                of: inset.size,
                matching: deviceAspect
              ) else {
            return inset
        }

        // Keep the fitted rect under the title bar instead of recentering over
        // it. Prefer top alignment within the inset content area.
        return CGRect(
            x: inset.minX + fitted.minX,
            y: inset.minY + fitted.minY,
            width: fitted.width,
            height: fitted.height
        )
    }

    /// Largest centered rect inside `imageSize` that matches `aspectSize`.
    static func centerCroppedRect(
        of imageSize: CGSize,
        matching aspectSize: CGSize
    ) -> CGRect? {
        guard imageSize.width > 0,
              imageSize.height > 0,
              aspectSize.width > 0,
              aspectSize.height > 0 else {
            return nil
        }

        let imageAspect = imageSize.width / imageSize.height
        let targetAspect = aspectSize.width / aspectSize.height
        if abs(imageAspect - targetAspect) < 0.01 {
            return CGRect(origin: .zero, size: imageSize)
        }

        if imageAspect > targetAspect {
            let width = imageSize.height * targetAspect
            return CGRect(
                x: (imageSize.width - width) / 2,
                y: 0,
                width: width,
                height: imageSize.height
            )
        }

        let height = imageSize.width / targetAspect
        return CGRect(
            x: 0,
            y: (imageSize.height - height) / 2,
            width: imageSize.width,
            height: height
        )
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}
