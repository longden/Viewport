import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import WebKit

/// High-fps ScreenCaptureKit crop of the on-screen web pane.
/// Avoids `WKWebView.takeSnapshot`, which stalls both UI and encode.
final class WebPaneCaptureStream: NSObject, @unchecked Sendable {
    private let sampleQueue = DispatchQueue(
        label: "com.viewport.recording.web-pane-capture",
        qos: .userInteractive
    )

    private var stream: SCStream?
    private var output: WebPaneStreamOutput?
    private var onFrame: ((CVPixelBuffer) -> Void)?

    @MainActor
    func start(
        target: WorkspaceRecordingTarget,
        frameRate: Int32,
        pixelFormat: OSType,
        maximumHeight: CGFloat,
        onFrame: @escaping (CVPixelBuffer) -> Void
    ) async throws {
        await stop()

        guard ScreenRecordingPermission.requestAccess() else {
            throw WorkspaceRecordingError.permissionRequired
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard let captureWindow = content.windows.first(where: {
            $0.windowID == target.windowID
        }) else {
            throw WorkspaceRecordingError.windowUnavailable
        }

        let sourceRect = target.sourceRect
        let outputSize = WorkspaceRecordingGeometry.outputSize(
            sourceSize: sourceRect.size,
            backingScale: target.backingScale,
            maximumHeight: maximumHeight
        )

        let output = WebPaneStreamOutput { buffer in
            onFrame(buffer)
        }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = Int(outputSize.width)
        configuration.height = Int(outputSize.height)
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: frameRate
        )
        configuration.queueDepth = 4
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.pixelFormat = pixelFormat
        configuration.captureResolution = .best
        configuration.colorSpaceName = CGColorSpace.sRGB

        let stream = SCStream(
            filter: SCContentFilter(desktopIndependentWindow: captureWindow),
            configuration: configuration,
            delegate: output
        )
        try stream.addStreamOutput(
            output,
            type: .screen,
            sampleHandlerQueue: sampleQueue
        )
        try await stream.startCapture()

        self.onFrame = onFrame
        self.output = output
        self.stream = stream
    }

    deinit {
        // SCStream stop is async; schedule cleanup without awaiting in deinit.
        let stream = self.stream
        self.stream = nil
        output = nil
        onFrame = nil
        guard let stream else { return }
        Task {
            try? await stream.stopCapture()
        }
    }

    func stop() async {
        let stream = self.stream
        self.stream = nil
        output = nil
        onFrame = nil
        if let stream {
            try? await stream.stopCapture()
        }
    }
}

private final class WebPaneStreamOutput:
    NSObject,
    SCStreamOutput,
    SCStreamDelegate,
    @unchecked Sendable
{
    private let onFrame: (CVPixelBuffer) -> Void

    init(onFrame: @escaping (CVPixelBuffer) -> Void) {
        self.onFrame = onFrame
        super.init()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let statusRawValue = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRawValue) == .complete else {
            return
        }
        onFrame(pixelBuffer)
    }
}

enum WebPaneCaptureGeometry {
    /// Fallback when the SwiftUI recording anchor has not published yet.
    @MainActor
    static func target(for webView: WKWebView) -> WorkspaceRecordingTarget? {
        guard let window = webView.window else { return nil }
        let windowRect = webView.convert(webView.bounds, to: nil)
        guard windowRect.width > 1, windowRect.height > 1 else { return nil }
        let screenRect = window.convertToScreen(windowRect)
        guard let sourceRect = WorkspaceRecordingGeometry.sourceRect(
            windowFrame: window.frame,
            captureRect: screenRect
        ) else {
            return nil
        }
        return WorkspaceRecordingTarget(
            windowID: CGWindowID(window.windowNumber),
            sourceRect: sourceRect,
            backingScale: window.backingScaleFactor
        )
    }
}
