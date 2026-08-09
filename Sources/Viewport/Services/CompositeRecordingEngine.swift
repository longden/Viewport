import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import Metal
import QuartzCore

/// GPU-composites per-pane live frames into one H.264 MP4.
///
/// Device panes feed IOSurface / CVPixelBuffer when available. Web is captured
/// with a ScreenCaptureKit crop of the on-screen pane (not `takeSnapshot`).
final class CompositeRecordingEngine: @unchecked Sendable {
    private let writer: PixelBufferRecordingWriter
    private let compositor: PaneFrameCompositor
    private let frameInterval: CFTimeInterval
    private let sources: [ViewerSource]
    private let layoutImages: [CGRect]
    private let quality: RecordingQuality

    private let stateQueue = DispatchQueue(
        label: "com.viewport.recording.composite.state"
    )
    private var webFrame: LiveCaptureFrame?
    private var isRunning = false
    private var encodeTask: Task<Void, Never>?
    private var webCapture: WebPaneCaptureStream?
    private var startHostTime: CFTimeInterval = 0
    private var lastAppendedPTS: CMTime = .invalid

    private let temporaryURL: URL

    var outputURL: URL { temporaryURL }

    func seedWebFrame(_ frame: LiveCaptureFrame) {
        stateQueue.sync {
            webFrame = frame
        }
    }

    init(
        sources: [ViewerSource],
        sourceSizes: [CGSize],
        outputURL: URL,
        quality: RecordingQuality
    ) throws {
        guard sources.count == sourceSizes.count,
              !sources.isEmpty,
              let layout = CompositeScreenshotLayout.frames(
                for: sourceSizes,
                maximumHeight: quality.maximumOutputHeight,
                includeLabels: false
              ) else {
            throw WorkspaceRecordingError.writerSetupFailed
        }

        let width = max(2, Int(layout.canvas.width.rounded(.up)) & ~1)
        let height = max(2, Int(layout.canvas.height.rounded(.up)) & ~1)
        let scaleX = CGFloat(width) / max(layout.canvas.width, 1)
        let scaleY = CGFloat(height) / max(layout.canvas.height, 1)
        let scale = min(scaleX, scaleY)
        let scaledWidth = layout.canvas.width * scale
        let scaledHeight = layout.canvas.height * scale
        let offsetX = (CGFloat(width) - scaledWidth) / 2
        let offsetY = (CGFloat(height) - scaledHeight) / 2

        self.sources = sources
        self.layoutImages = layout.images.map { frame in
            CGRect(
                x: offsetX + frame.minX * scale,
                y: offsetY + frame.minY * scale,
                width: frame.width * scale,
                height: frame.height * scale
            )
        }
        self.temporaryURL = outputURL
        self.quality = quality
        self.frameInterval = 1 / CFTimeInterval(max(quality.frameRate, 1))
        self.compositor = try PaneFrameCompositor(
            width: width,
            height: height,
            pixelFormat: quality.pixelFormat
        )
        self.writer = try PixelBufferRecordingWriter(
            outputURL: outputURL,
            width: width,
            height: height,
            framesPerSecond: quality.frameRate,
            bitRate: quality.bitRate(width: width, height: height)
        )
    }

    @MainActor
    func start(
        workspace: WorkspaceStore,
        webCaptureTarget: WorkspaceRecordingTarget?
    ) async throws {
        let androidSlot = workspace.androidCapture.recordingFrameSlot
        let iosSlot = workspace.iOSCapture.recordingFrameSlot

        stateQueue.sync {
            guard !isRunning else { return }
            isRunning = true
            startHostTime = CACurrentMediaTime()
            lastAppendedPTS = .invalid
        }

        if sources.contains(.web) {
            guard let webCaptureTarget else {
                throw WorkspaceRecordingError.windowUnavailable
            }
            let capture = WebPaneCaptureStream()
            try await capture.start(
                target: webCaptureTarget,
                frameRate: quality.frameRate,
                pixelFormat: quality.pixelFormat,
                maximumHeight: quality.maximumOutputHeight
            ) { [weak self] buffer in
                // Retain the backing IOSurface so SCK can recycle its pool
                // without invalidating the frame we hold for compositing.
                if let surface = CVPixelBufferGetIOSurface(buffer)?
                    .takeUnretainedValue() {
                    self?.seedWebFrame(.surface(BorrowedIOSurface(surface)))
                } else {
                    self?.seedWebFrame(.pixelBuffer(buffer))
                }
            }
            webCapture = capture
        }

        encodeTask = Task { [weak self] in
            guard let self else { return }
            let sleepNanos = UInt64(max(frameInterval, 1 / 120) * 1_000_000_000)
            while !Task.isCancelled {
                // Read latest device / web frames off MainActor.
                self.tick(
                    androidFrame: androidSlot.load(),
                    iosFrame: iosSlot.load()
                )
                try? await Task.sleep(nanoseconds: sleepNanos)
            }
        }
    }

    func stop() async -> Bool {
        encodeTask?.cancel()
        encodeTask = nil
        let capture = webCapture
        webCapture = nil
        await capture?.stop()
        stateQueue.sync {
            isRunning = false
            webFrame = nil
        }
        return await writer.finish()
    }

    deinit {
        cancel()
    }

    func cancel() {
        encodeTask?.cancel()
        encodeTask = nil
        let capture = webCapture
        webCapture = nil
        Task {
            await capture?.stop()
        }
        stateQueue.sync {
            isRunning = false
            webFrame = nil
        }
        writer.cancel()
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    private func tick(
        androidFrame: LiveCaptureFrame?,
        iosFrame: LiveCaptureFrame?
    ) {
        let running = stateQueue.sync { isRunning }
        guard running else { return }

        let now = CACurrentMediaTime()
        let elapsed = now - startHostTime
        let pts = CMTime(
            seconds: elapsed,
            preferredTimescale: 600
        )
        let shouldAppend = stateQueue.sync { () -> Bool in
            if lastAppendedPTS.isValid {
                let delta = CMTimeGetSeconds(
                    CMTimeSubtract(pts, lastAppendedPTS)
                )
                if delta + 0.0005 < frameInterval {
                    return false
                }
            }
            lastAppendedPTS = pts
            return true
        }
        guard shouldAppend else { return }

        var panes: [(LiveCaptureFrame, CGRect)] = []
        panes.reserveCapacity(sources.count)

        for (index, source) in sources.enumerated() {
            let frame: LiveCaptureFrame?
            switch source {
            case .web:
                frame = stateQueue.sync { self.webFrame }
            case .android:
                frame = androidFrame
            case .iOS:
                frame = iosFrame
            }
            guard let frame else { continue }
            panes.append((frame, layoutImages[index]))
        }

        guard !panes.isEmpty else { return }

        writer.sampleQueue.async { [weak self] in
            guard let self,
                  let buffer = self.compositor.compose(panes: panes) else {
                return
            }
            self.writer.append(buffer, presentationTime: pts)
        }
    }
}

// MARK: - Compositor

private final class PaneFrameCompositor: @unchecked Sendable {
    private let ciContext: CIContext
    private let width: Int
    private let height: Int
    private let pixelFormat: OSType
    private let pool: CVPixelBufferPool
    private let canvasExtent: CGRect
    private let background: CIImage

    init(width: Int, height: Int, pixelFormat: OSType) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw WorkspaceRecordingError.writerSetupFailed
        }
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.canvasExtent = CGRect(
            x: 0,
            y: 0,
            width: width,
            height: height
        )
        self.background = CIImage(color: CIColor.black).cropped(to: canvasExtent)
        self.ciContext = CIContext(
            mtlDevice: device,
            options: [
                .cacheIntermediates: false,
                .workingColorSpace: NSNull()
            ]
        )

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            attrs as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let pool else {
            throw WorkspaceRecordingError.writerSetupFailed
        }
        self.pool = pool
    }

    func compose(panes: [(LiveCaptureFrame, CGRect)]) -> CVPixelBuffer? {
        var output = background
        for (frame, topLeftRect) in panes {
            guard let source = ciImage(from: frame) else { continue }
            let fitted = Self.aspectFit(
                source,
                into: topLeftRect,
                canvasHeight: height
            )
            output = fitted.composited(over: output)
        }

        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { return nil }

        ciContext.render(
            output,
            to: buffer,
            bounds: canvasExtent,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return buffer
    }

    private func ciImage(from frame: LiveCaptureFrame) -> CIImage? {
        switch frame {
        case let .pixelBuffer(buffer):
            return CIImage(cvPixelBuffer: buffer)
        case let .surface(borrowed):
            return CIImage(ioSurface: borrowed.surface)
        case let .image(image):
            return CIImage(cgImage: image)
        }
    }

    /// `topLeftRect` uses screenshot-style top-left origin; CI uses bottom-left.
    private static func aspectFit(
        _ image: CIImage,
        into topLeftRect: CGRect,
        canvasHeight: Int
    ) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0,
              topLeftRect.width > 0, topLeftRect.height > 0 else {
            return image
        }

        let scale = min(
            topLeftRect.width / extent.width,
            topLeftRect.height / extent.height
        )
        let drawnWidth = extent.width * scale
        let drawnHeight = extent.height * scale
        let x = topLeftRect.minX + (topLeftRect.width - drawnWidth) / 2
        let topY = topLeftRect.minY + (topLeftRect.height - drawnHeight) / 2
        let bottomLeftY = CGFloat(canvasHeight) - topY - drawnHeight

        return image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(
                by: CGAffineTransform(
                    translationX: x - extent.minX * scale,
                    y: bottomLeftY - extent.minY * scale
                )
            )
    }
}

// MARK: - Writer

private final class PixelBufferRecordingWriter: @unchecked Sendable {
    let sampleQueue = DispatchQueue(
        label: "com.viewport.recording.composite-writer",
        qos: .userInteractive
    )

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var hasStartedSession = false
    private var hasFinished = false

    init(
        outputURL: URL,
        width: Int,
        height: Int,
        framesPerSecond: Int32,
        bitRate: Int
    ) throws {
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: Int(framesPerSecond),
                AVVideoMaxKeyFrameIntervalKey: Int(framesPerSecond * 2),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
            ]
        )

        guard writer.canAdd(input) else {
            throw WorkspaceRecordingError.writerSetupFailed
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? WorkspaceRecordingError.writerSetupFailed
        }
    }

    func append(_ buffer: CVPixelBuffer, presentationTime: CMTime) {
        dispatchPrecondition(condition: .onQueue(sampleQueue))
        guard !hasFinished,
              writer.status == .writing,
              input.isReadyForMoreMediaData else {
            return
        }

        if !hasStartedSession {
            writer.startSession(atSourceTime: presentationTime)
            hasStartedSession = true
        }
        adaptor.append(buffer, withPresentationTime: presentationTime)
    }

    func finish() async -> Bool {
        await withCheckedContinuation { continuation in
            sampleQueue.async {
                guard !self.hasFinished else {
                    continuation.resume(returning: false)
                    return
                }
                self.hasFinished = true
                guard self.hasStartedSession else {
                    self.writer.cancelWriting()
                    continuation.resume(returning: false)
                    return
                }

                self.input.markAsFinished()
                self.writer.finishWriting {
                    continuation.resume(
                        returning: self.writer.status == .completed
                    )
                }
            }
        }
    }

    func cancel() {
        sampleQueue.sync {
            guard !hasFinished else { return }
            hasFinished = true
            writer.cancelWriting()
        }
    }
}

// MARK: - Layout helpers (testable)

enum CompositeRecordingLayout {
    /// Even pixel canvas from source sizes, capped by `maximumHeight`.
    static func outputCanvas(
        sourceSizes: [CGSize],
        maximumHeight: CGFloat
    ) -> CGSize? {
        guard let layout = CompositeScreenshotLayout.frames(
            for: sourceSizes,
            maximumHeight: maximumHeight,
            includeLabels: false
        ) else {
            return nil
        }
        let width = max(2, Int(layout.canvas.width.rounded(.up)) & ~1)
        let height = max(2, Int(layout.canvas.height.rounded(.up)) & ~1)
        return CGSize(width: width, height: height)
    }
}
