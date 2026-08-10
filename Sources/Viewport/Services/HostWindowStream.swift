import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit

@MainActor
final class HostWindowStream: NSObject {
    private let sampleQueue: DispatchQueue
    nonisolated private let frameDelivery =
        LatestValueDelivery<HostWindowFrameInput>()

    // Cleared from `stop()`, which must be callable from nonisolated `deinit`.
    private nonisolated(unsafe) var activeStream: SCStream?
    private nonisolated(unsafe) var onFrame: ((CVPixelBuffer) -> Void)?
    private nonisolated(unsafe) var onFailure: ((Error) -> Void)?

    override init() {
        sampleQueue = DispatchQueue(
            label: "com.longden.viewport.host-window-stream",
            qos: .userInteractive
        )
        super.init()
    }

    deinit {
        stop()
    }

    var isAvailable: Bool {
        CGPreflightScreenCaptureAccess()
    }

    func start(
        source: ViewerSource,
        deviceName: String,
        profile: CapturePerformanceProfile,
        contentAspect: CGSize? = nil,
        onFrame: @escaping (CVPixelBuffer) -> Void,
        onFailure: @escaping (Error) -> Void
    ) async throws -> Bool {
        await stopAndWait()
        guard isAvailable else { return false }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard let window = Self.bestWindow(
            in: content.windows,
            source: source,
            deviceName: deviceName
        ) else {
            return false
        }

        let captureRect = DevicePreviewInputGeometry.hostWindowContentRect(
            windowSize: window.frame.size,
            deviceAspect: contentAspect,
            chromeInsets: DevicePreviewInputGeometry.hostWindowChromeInsets(
                for: source
            )
        ) ?? CGRect(origin: .zero, size: window.frame.size)
        // sourceRect is in window-local points (origin at the top-left).
        let sourceRect = CGRect(
            x: captureRect.origin.x,
            y: captureRect.origin.y,
            width: captureRect.size.width,
            height: captureRect.size.height
        )

        let configuration = SCStreamConfiguration()
        let requestedDimension = profile.maximumDisplayDimension ?? 2_800
        let longestSide = max(sourceRect.width, sourceRect.height, 1)
        let scale = min(
            profile.maximumHostWindowScale,
            CGFloat(requestedDimension) / longestSide
        )
        configuration.width = max(Int(sourceRect.width * scale), 1)
        configuration.height = max(Int(sourceRect.height * scale), 1)
        configuration.sourceRect = sourceRect
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(profile.hostWindowFrameRate)
        )
        configuration.queueDepth = 4
        configuration.showsCursor = false
        configuration.capturesAudio = false

        let stream = SCStream(
            filter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration,
            delegate: self
        )
        try stream.addStreamOutput(
            self,
            type: .screen,
            sampleHandlerQueue: sampleQueue
        )

        self.onFrame = onFrame
        self.onFailure = onFailure
        activeStream = stream

        do {
            try await stream.startCapture()
            guard activeStream === stream else {
                try? await stream.stopCapture()
                return false
            }
            return true
        } catch {
            if activeStream === stream {
                activeStream = nil
                self.onFrame = nil
                self.onFailure = nil
            }
            throw error
        }
    }

    nonisolated func stop() {
        let stream = activeStream
        activeStream = nil
        onFrame = nil
        onFailure = nil
        frameDelivery.clear()
        guard let stream else { return }

        Task {
            try? await stream.stopCapture()
        }
    }

    private func stopAndWait() async {
        let stream = activeStream
        activeStream = nil
        onFrame = nil
        onFailure = nil
        frameDelivery.clear()
        if let stream {
            try? await stream.stopCapture()
        }
    }

    private static func bestWindow(
        in windows: [SCWindow],
        source: ViewerSource,
        deviceName: String
    ) -> SCWindow? {
        let candidates = windows.filter { window in
            let descriptor = CaptureDescriptor(
                applicationName: window.owningApplication?.applicationName ?? "",
                bundleIdentifier: window.owningApplication?.bundleIdentifier ?? "",
                windowTitle: window.title ?? ""
            )
            return descriptor.matches(source)
                && window.frame.width > 120
                && window.frame.height > 180
        }
        return candidates.first(where: {
            HostWindowDeviceTitleMatching.matches(
                title: $0.title ?? "",
                deviceName: deviceName
            )
        })
    }
}

/// Exact host-window title matching for Simulator / Emulator windows.
/// Avoids substring matches like "iPhone 16" → "iPhone 16 Pro…".
enum HostWindowDeviceTitleMatching {
    static func matches(title: String, deviceName: String) -> Bool {
        let normalizedName = deviceName.lowercased()
        let normalizedTitle = title.lowercased()
        // Exact match on the full title, or the title starts with the
        // device name followed by a separator (" — ", " – ", " - ").
        return normalizedTitle == normalizedName
            || normalizedTitle.hasPrefix(normalizedName + " \u{2014} ")
            || normalizedTitle.hasPrefix(normalizedName + " \u{2013} ")
            || normalizedTitle.hasPrefix(normalizedName + " - ")
    }
}

extension HostWindowStream: SCStreamOutput, SCStreamDelegate {
    nonisolated func stream(
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

        frameDelivery.submit(
            HostWindowFrameInput(stream: stream, pixelBuffer: pixelBuffer)
        ) { [weak self] input in
            Task { @MainActor [weak self] in
                guard let self, self.activeStream === input.stream else { return }
                self.onFrame?(input.pixelBuffer)
            }
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.activeStream === stream else { return }
            self.activeStream = nil
            let onFailure = self.onFailure
            self.onFrame = nil
            self.onFailure = nil
            onFailure?(error)
        }
    }
}

private struct HostWindowFrameInput: @unchecked Sendable {
    let stream: SCStream
    let pixelBuffer: CVPixelBuffer
}
