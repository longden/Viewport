import AppKit
import AVFoundation
import CoreMedia
import SwiftUI

final class CapturePreviewNSView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor

        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    func display(_ sampleBuffer: CMSampleBuffer) {
        let renderer = displayLayer.sampleBufferRenderer
        guard renderer.isReadyForMoreMediaData else { return }

        if renderer.status == .failed {
            renderer.flush()
        }
        renderer.enqueue(sampleBuffer)
    }

    func clear() {
        displayLayer.sampleBufferRenderer.flush(
            removingDisplayedImage: true,
            completionHandler: nil
        )
    }
}

struct CapturePreviewView: NSViewRepresentable {
    @ObservedObject var session: WindowCaptureSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> CapturePreviewNSView {
        let view = CapturePreviewNSView()
        session.attachPreview(view)
        return view
    }

    func updateNSView(_ nsView: CapturePreviewNSView, context: Context) {
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
