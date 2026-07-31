import AppKit
import SwiftUI

final class CapturePreviewNSView: NSView {
    private let displayLayer = CALayer()
    private var gestureStart: (
        point: CGPoint,
        timestamp: TimeInterval
    )?
    weak var session: WindowCaptureSession?

    init(session: WindowCaptureSession) {
        self.session = session
        super.init(frame: .zero)

        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor

        displayLayer.contentsGravity = .resize
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.cornerRadius = 16
        displayLayer.masksToBounds = true
        displayLayer.magnificationFilter = .linear
        displayLayer.minificationFilter = .trilinear
        layer?.addSublayer(displayLayer)
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let sourceSize = session?.capturedFrameSize,
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.contents = image
        needsLayout = true
        CATransaction.commit()
    }

    func clear() {
        displayLayer.contents = nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let point = normalizedPoint(for: event) else {
            gestureStart = nil
            return
        }
        gestureStart = (point, event.timestamp)
    }

    override func mouseDragged(with event: NSEvent) {
        guard gestureStart != nil,
              let point = normalizedPoint(
                for: event,
                clampsToDisplayedFrame: true
              ) else {
            return
        }
        _ = point
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = gestureStart else { return }
        gestureStart = nil
        guard let point = normalizedPoint(
            for: event,
            clampsToDisplayedFrame: true
        ) else {
            return
        }
        session?.performGesture(
            from: start.point,
            to: point,
            duration: max(event.timestamp - start.timestamp, 0.05)
        )
    }

    override func scrollWheel(with event: NSEvent) {
        guard let point = normalizedPoint(for: event) else {
            super.scrollWheel(with: event)
            return
        }

        let distance = min(max(abs(event.scrollingDeltaY) / 500, 0.08), 0.45)
        let end = CGPoint(
            x: point.x,
            y: min(max(
                point.y + (event.scrollingDeltaY > 0 ? distance : -distance),
                0
            ), 1)
        )
        session?.performGesture(
            from: point,
            to: end,
            duration: 0.25
        )
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
        guard let sourceSize = session?.capturedWindowSize else { return nil }

        return DevicePreviewInputGeometry.normalizedPoint(
            convert(event.locationInWindow, from: nil),
            in: bounds,
            sourceSize: sourceSize,
            clampsToDisplayedFrame: clampsToDisplayedFrame
        )
    }
}

struct CapturePreviewView: NSViewRepresentable {
    @ObservedObject var session: WindowCaptureSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> CapturePreviewNSView {
        let view = CapturePreviewNSView(session: session)
        session.attachPreview(view)
        return view
    }

    func updateNSView(_ nsView: CapturePreviewNSView, context: Context) {
        nsView.session = session
        session.attachPreview(nsView)
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
