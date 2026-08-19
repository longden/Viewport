import AppKit
import CoreVideo
import IOSurface
import SwiftUI

final class CapturePreviewNSView: NSView {
    private struct ScrollGesture {
        var currentPoint: CGPoint
        var pendingDeltaY: CGFloat
        var beganDeviceTouch: Bool
        var startedAt: TimeInterval
    }

    private let displayLayer = CALayer()
    private var gestureStart: (
        point: CGPoint,
        timestamp: TimeInterval
    )?
    private var lastMoveSentAt: TimeInterval = 0
    private var scrollGesture: ScrollGesture?
    private var scrollEndWorkItem: DispatchWorkItem?
    weak var session: WindowCaptureSession?
    /// Fired on mouse-down so SwiftUI can focus the pane without an
    /// `onTapGesture` that steals AppKit clicks from this view.
    var onActivate: (() -> Void)?
    /// While true, keep showing the last frame but skip buffer swaps so
    /// divider drags are not competing with 30–60 FPS layer updates.
    var isResizingPanes = false
    private var lastLaidOutBounds: CGRect = .null
    private var lastLaidOutSourceSize: CGSize = .zero

    init(session: WindowCaptureSession) {
        self.session = session
        super.init(frame: .zero)

        // Layer-backed (not layer-hosting): keep AppKit's geometry so the
        // framebuffer and mouse coordinates share one space.
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        displayLayer.contentsGravity = .resize
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.cornerRadius = ViewerSource.surfaceCornerRadius
        displayLayer.masksToBounds = true
        displayLayer.cornerCurve = .continuous
        displayLayer.magnificationFilter = .linear
        displayLayer.minificationFilter = .linear
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard displayLayer.superlayer == nil else { return }
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(displayLayer)
        needsLayout = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func layout() {
        super.layout()
        let sourceSize = session?.capturedFrameSize
        if !lastLaidOutBounds.isNull,
           lastLaidOutBounds == bounds,
           lastLaidOutSourceSize == (sourceSize ?? .zero) {
            return
        }
        lastLaidOutBounds = bounds
        lastLaidOutSourceSize = sourceSize ?? .zero

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let sourceSize,
           sourceSize.width > 0,
           sourceSize.height > 0 {
            let scale = min(
                bounds.width / sourceSize.width,
                bounds.height / sourceSize.height
            )
            let size = CGSize(
                width: sourceSize.width * scale,
                height: sourceSize.height * scale
            )
            displayLayer.frame = CGRect(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        } else {
            displayLayer.frame = bounds
        }
        CATransaction.commit()
    }

    func display(_ image: CGImage) {
        guard !isResizingPanes else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.contents = image
        CATransaction.commit()
    }

    func display(surface: IOSurfaceRef) {
        guard !isResizingPanes else { return }
        // Reassign even when the IOSurface identity is unchanged — SimulatorKit
        // updates pixels in place, and setNeedsDisplay does not resample contents.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.contents = surface
        CATransaction.commit()
    }

    func display(pixelBuffer: CVPixelBuffer) {
        guard !isResizingPanes else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.contents = pixelBuffer
        CATransaction.commit()
    }

    func sourceSizeDidChange() {
        lastLaidOutSourceSize = .zero
        needsLayout = true
    }

    func clear() {
        finishScrollGesture()
        displayLayer.contents = nil
    }

    override func mouseDown(with event: NSEvent) {
        finishScrollGesture()
        window?.makeFirstResponder(self)
        onActivate?()
        guard let point = normalizedPoint(for: event) else {
            gestureStart = nil
            return
        }
        gestureStart = (point, event.timestamp)
        lastMoveSentAt = event.timestamp
        session?.beginPointer(at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard gestureStart != nil,
              let point = normalizedPoint(
                for: event,
                clampsToDisplayedFrame: true
              ) else {
            return
        }
        // ~60 Hz is enough for smooth dragging without flooding ADB.
        guard event.timestamp - lastMoveSentAt >= 0.016 else { return }
        lastMoveSentAt = event.timestamp
        session?.movePointer(to: point)
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = gestureStart else { return }
        gestureStart = nil
        guard let point = normalizedPoint(
            for: event,
            clampsToDisplayedFrame: true
        ) else {
            session?.endPointer(
                at: start.point,
                duration: max(event.timestamp - start.timestamp, 0.05)
            )
            return
        }
        session?.endPointer(
            at: point,
            duration: max(event.timestamp - start.timestamp, 0.05)
        )
    }

    override func scrollWheel(with event: NSEvent) {
        guard let pointerPoint = normalizedPoint(for: event) else {
            finishScrollGesture()
            super.scrollWheel(with: event)
            return
        }

        let frameHeight = max(displayLayer.frame.height, 1)
        let deltaY = CGFloat(event.scrollingDeltaY) / frameHeight
        guard deltaY != 0 else {
            scheduleScrollEnd()
            return
        }

        var gesture = scrollGesture ?? ScrollGesture(
            // Keep room in both directions even when the pointer is near an
            // edge of the preview. This prevents a clamped swipe becoming a tap.
            currentPoint: CGPoint(
                x: pointerPoint.x,
                y: min(max(pointerPoint.y, 0.18), 0.82)
            ),
            pendingDeltaY: 0,
            beganDeviceTouch: false,
            startedAt: event.timestamp
        )
        gesture.pendingDeltaY += deltaY

        // Ignore trackpad noise until there is enough movement to distinguish
        // a two-finger scroll from a click. Once active, preserve every delta.
        let activationDistance: CGFloat = 0.004
        if !gesture.beganDeviceTouch,
           abs(gesture.pendingDeltaY) < activationDistance {
            scrollGesture = gesture
            scheduleScrollEnd()
            return
        }

        if !gesture.beganDeviceTouch {
            session?.beginPointer(at: gesture.currentPoint)
            gesture.beganDeviceTouch = true
        }

        let nextPoint = CGPoint(
            x: gesture.currentPoint.x,
            y: min(max(
                gesture.currentPoint.y + gesture.pendingDeltaY,
                0.06
            ), 0.94)
        )
        gesture.pendingDeltaY = 0
        if nextPoint != gesture.currentPoint {
            session?.movePointer(to: nextPoint)
            gesture.currentPoint = nextPoint
        }
        scrollGesture = gesture
        scheduleScrollEnd()
    }

    override func keyDown(with event: NSEvent) {
        guard session?.postKeyboardEvent(event) == true else {
            super.keyDown(with: event)
            return
        }
    }

    override func keyUp(with event: NSEvent) {
        guard session?.postKeyboardEvent(event) == true else {
            super.keyUp(with: event)
            return
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard session?.postKeyboardEvent(event) == true else {
            super.flagsChanged(with: event)
            return
        }
    }

    private func normalizedPoint(
        for event: NSEvent,
        clampsToDisplayedFrame: Bool = false
    ) -> CGPoint? {
        // Prefer the layer that actually shows the frame so layout and hit
        // testing cannot drift (e.g. after a size change before the next
        // layout pass finishes). Fall back to recomputing the aspect-fit.
        let point = convert(event.locationInWindow, from: nil)
        let drawnFrame = displayLayer.frame
        if drawnFrame.width > 1, drawnFrame.height > 1 {
            return DevicePreviewInputGeometry.normalizedPoint(
                point,
                displayedFrame: drawnFrame,
                clampsToDisplayedFrame: clampsToDisplayedFrame,
                flipsYFromAppKit: !isFlipped
            )
        }

        guard let sourceSize = session?.capturedWindowSize else { return nil }
        return DevicePreviewInputGeometry.normalizedPoint(
            point,
            in: bounds,
            sourceSize: sourceSize,
            clampsToDisplayedFrame: clampsToDisplayedFrame,
            flipsYFromAppKit: !isFlipped
        )
    }

    private func scheduleScrollEnd() {
        scrollEndWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.finishScrollGesture()
        }
        scrollEndWorkItem = workItem
        // Trackpad momentum arrives immediately after the finger phase ends.
        // Debouncing keeps both phases in one device touch.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.12,
            execute: workItem
        )
    }

    private func finishScrollGesture() {
        scrollEndWorkItem?.cancel()
        scrollEndWorkItem = nil
        guard let gesture = scrollGesture else { return }
        scrollGesture = nil
        guard gesture.beganDeviceTouch else { return }
        session?.endPointer(
            at: gesture.currentPoint,
            duration: max(ProcessInfo.processInfo.systemUptime - gesture.startedAt, 0.05)
        )
    }
}

struct CapturePreviewView: NSViewRepresentable {
    var session: WindowCaptureSession
    var onActivate: (() -> Void)? = nil
    @Environment(\.isPaneResizing) private var isPaneResizing

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> CapturePreviewNSView {
        let view = CapturePreviewNSView(session: session)
        view.onActivate = onActivate
        view.isResizingPanes = isPaneResizing
        session.attachPreview(view)
        return view
    }

    func updateNSView(_ nsView: CapturePreviewNSView, context: Context) {
        if nsView.session !== session {
            nsView.session = session
            session.attachPreview(nsView)
        }
        nsView.onActivate = onActivate
        if nsView.isResizingPanes != isPaneResizing {
            nsView.isResizingPanes = isPaneResizing
            // Leaving a drag: pull the freshest frame that was skipped.
            if !isPaneResizing {
                session.redisplayPreview()
            }
        }
    }

    static func dismantleNSView(
        _ nsView: CapturePreviewNSView,
        coordinator: Coordinator
    ) {
        nsView.clear()
        coordinator.session.detachPreview(nsView)
    }

    final class Coordinator {
        let session: WindowCaptureSession

        init(session: WindowCaptureSession) {
            self.session = session
        }
    }
}
