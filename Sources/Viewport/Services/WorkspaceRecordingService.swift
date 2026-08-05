import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

enum WorkspaceRecordingError: LocalizedError {
    case nothingToRecord
    case alreadyRecording
    case notRecording
    case permissionRequired
    case windowUnavailable
    case writerSetupFailed
    case finalizeFailed

    var errorDescription: String? {
        switch self {
        case .nothingToRecord:
            "Nothing to record. Open a pane that has a live view."
        case .alreadyRecording:
            "A recording is already in progress."
        case .notRecording:
            "No recording is in progress."
        case .permissionRequired:
            "Screen Recording access is required. Allow Viewport in System Settings, then restart the app."
        case .windowUnavailable:
            "The Viewport workspace window could not be captured."
        case .writerSetupFailed:
            "The recording could not be started."
        case .finalizeFailed:
            "The recording could not be saved."
        }
    }
}

/// Records the rendered workspace with ScreenCaptureKit.
///
/// ScreenCaptureKit supplies GPU-backed frames at the display cadence, avoiding
/// the per-pane `CGImage` snapshots and CPU compositing that made interactions
/// stutter in the previous recorder.
@MainActor
final class WorkspaceRecordingService: ObservableObject {
    static let maxDuration: TimeInterval = 5 * 60
    static let maximumOutputHeight: CGFloat = 1_080

    @Published private(set) var isRecording = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastSavedURL: URL?

    private var stream: SCStream?
    private var streamOutput: WorkspaceRecordingStreamOutput?
    private var writer: ScreenCaptureRecordingWriter?
    private var temporaryURL: URL?
    private var elapsedTask: Task<Void, Never>?
    private var isStopping = false
    private var captureTarget: WorkspaceRecordingTarget?

    func updateCaptureTarget(_ target: WorkspaceRecordingTarget?) {
        captureTarget = target
    }

    func start(
        web: WebViewModel,
        workspace: WorkspaceStore
    ) async throws {
        guard !isRecording else {
            throw WorkspaceRecordingError.alreadyRecording
        }
        guard !workspace.orderedVisibleSources.isEmpty else {
            throw WorkspaceRecordingError.nothingToRecord
        }

        // Preserve the existing call shape while recording the already-rendered
        // WKWebView and device previews together.
        _ = web

        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw WorkspaceRecordingError.permissionRequired
        }
        guard let appWindow = NSApp.keyWindow ?? NSApp.mainWindow else {
            throw WorkspaceRecordingError.windowUnavailable
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        let target = captureTarget
        let windowID = target?.windowID ?? CGWindowID(appWindow.windowNumber)
        guard let captureWindow = content.windows.first(where: {
            $0.windowID == windowID
        }) else {
            throw WorkspaceRecordingError.windowUnavailable
        }

        guard let sourceRect = target?.sourceRect
            ?? WorkspaceRecordingGeometry.sourceRect(
                windowSize: captureWindow.frame.size,
                contentLayoutRect: appWindow.contentLayoutRect
            ) else {
            throw WorkspaceRecordingError.windowUnavailable
        }

        let outputSize = WorkspaceRecordingGeometry.outputSize(
            sourceSize: sourceRect.size,
            backingScale: target?.backingScale ?? appWindow.backingScaleFactor,
            maximumHeight: Self.maximumOutputHeight
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Viewport-Recording-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: url)

        let frameRate = workspace.performanceProfile.recordingFrameRate
        let writer: ScreenCaptureRecordingWriter
        do {
            writer = try ScreenCaptureRecordingWriter(
                outputURL: url,
                width: Int(outputSize.width),
                height: Int(outputSize.height),
                framesPerSecond: frameRate
            )
        } catch {
            throw WorkspaceRecordingError.writerSetupFailed
        }

        let output = WorkspaceRecordingStreamOutput(writer: writer)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = Int(outputSize.width)
        configuration.height = Int(outputSize.height)
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: frameRate
        )
        configuration.queueDepth = 6
        configuration.showsCursor = false
        configuration.capturesAudio = false
        // NV12 keeps frames in the encoder's native 4:2:0 layout: ~2.7x less
        // bandwidth than BGRA and no per-frame RGB-to-YUV conversion. Output
        // dimensions are already rounded to even values, keeping the chroma
        // plane aligned.
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        let stream = SCStream(
            filter: SCContentFilter(desktopIndependentWindow: captureWindow),
            configuration: configuration,
            delegate: output
        )

        do {
            try stream.addStreamOutput(
                output,
                type: .screen,
                sampleHandlerQueue: writer.sampleQueue
            )
            try await stream.startCapture()
        } catch {
            writer.cancel()
            try? FileManager.default.removeItem(at: url)
            throw WorkspaceRecordingError.writerSetupFailed
        }

        self.writer = writer
        self.stream = stream
        streamOutput = output
        temporaryURL = url
        startedAt = Date()
        elapsed = 0
        isRecording = true
        isStopping = false
        lastSavedURL = nil
        startElapsedTimer()
    }

    @discardableResult
    func stop() async throws -> URL? {
        guard isRecording, !isStopping else {
            if !isRecording {
                throw WorkspaceRecordingError.notRecording
            }
            return nil
        }
        isStopping = true

        elapsedTask?.cancel()
        elapsedTask = nil

        let stream = self.stream
        let writer = self.writer
        let temporaryURL = self.temporaryURL
        self.stream = nil
        streamOutput = nil
        self.writer = nil
        self.temporaryURL = nil

        if let stream {
            try? await stream.stopCapture()
        }

        guard let writer, let temporaryURL else {
            resetSessionState()
            throw WorkspaceRecordingError.finalizeFailed
        }

        let completed = await writer.finish()
        guard completed else {
            try? FileManager.default.removeItem(at: temporaryURL)
            resetSessionState()
            throw WorkspaceRecordingError.finalizeFailed
        }

        do {
            let saved = try presentSavePanel(for: temporaryURL)
            lastSavedURL = saved
            resetSessionState()
            return saved
        } catch {
            resetSessionState()
            throw error
        }
    }

    func cancel() {
        guard isRecording || isStopping else { return }

        elapsedTask?.cancel()
        elapsedTask = nil
        let stream = self.stream
        self.stream = nil
        streamOutput = nil

        Task {
            try? await stream?.stopCapture()
        }
        writer?.cancel()
        if let temporaryURL {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        resetSessionState()
    }

    private func startElapsedTimer() {
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled, let startedAt else { return }
                elapsed = Date().timeIntervalSince(startedAt)
                if elapsed >= Self.maxDuration {
                    _ = try? await stop()
                    return
                }
            }
        }
    }

    private func resetSessionState() {
        elapsedTask?.cancel()
        elapsedTask = nil
        stream = nil
        streamOutput = nil
        writer = nil
        temporaryURL = nil
        startedAt = nil
        elapsed = 0
        isStopping = false
        isRecording = false
    }

    private func presentSavePanel(for temporaryURL: URL) throws -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = WorkspaceScreenshotNaming.filename(
            fileExtension: "mp4"
        )
        panel.title = "Save Recording"

        guard panel.runModal() == .OK, let destination = panel.url else {
            try? FileManager.default.removeItem(at: temporaryURL)
            return nil
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }
}

struct WorkspaceRecordingTarget: Equatable {
    let windowID: CGWindowID
    let sourceRect: CGRect
    let backingScale: CGFloat
}

/// An invisible AppKit view that tracks the exact rendered pane region.
/// Attaching this directly to `WorkspaceSplitView` keeps toolbar, padding and
/// export toasts out of the ScreenCaptureKit recording.
struct WorkspaceRecordingAnchor: NSViewRepresentable {
    let onTargetChange: @MainActor (WorkspaceRecordingTarget?) -> Void

    func makeNSView(context: Context) -> WorkspaceRecordingAnchorView {
        let view = WorkspaceRecordingAnchorView()
        view.onTargetChange = onTargetChange
        return view
    }

    func updateNSView(
        _ nsView: WorkspaceRecordingAnchorView,
        context: Context
    ) {
        nsView.onTargetChange = onTargetChange
        nsView.reportTarget()
    }

    static func dismantleNSView(
        _ nsView: WorkspaceRecordingAnchorView,
        coordinator: Void
    ) {
        nsView.onTargetChange?(nil)
        nsView.onTargetChange = nil
    }
}

@MainActor
final class WorkspaceRecordingAnchorView: NSView {
    var onTargetChange: (@MainActor (WorkspaceRecordingTarget?) -> Void)?
    private var lastTarget: WorkspaceRecordingTarget?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportTarget()
    }

    override func layout() {
        super.layout()
        reportTarget()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportTarget()
    }

    func reportTarget() {
        guard let window else {
            publish(nil)
            return
        }

        let windowRect = convert(bounds, to: nil)
        let screenRect = window.convertToScreen(windowRect)
        guard let sourceRect = WorkspaceRecordingGeometry.sourceRect(
            windowFrame: window.frame,
            captureRect: screenRect
        ) else {
            publish(nil)
            return
        }

        publish(
            WorkspaceRecordingTarget(
                windowID: CGWindowID(window.windowNumber),
                sourceRect: sourceRect,
                backingScale: window.backingScaleFactor
            )
        )
    }

    private func publish(_ target: WorkspaceRecordingTarget?) {
        guard target != lastTarget else { return }
        lastTarget = target
        onTargetChange?(target)
    }
}

enum WorkspaceRecordingGeometry {
    /// Converts AppKit's bottom-left window coordinates to ScreenCaptureKit's
    /// top-left window-local coordinates and clamps the crop to the window.
    static func sourceRect(
        windowSize: CGSize,
        contentLayoutRect: CGRect
    ) -> CGRect? {
        guard windowSize.width > 0,
              windowSize.height > 0,
              contentLayoutRect.width > 0,
              contentLayoutRect.height > 0 else {
            return nil
        }

        let rect = CGRect(
            x: contentLayoutRect.minX,
            y: windowSize.height - contentLayoutRect.maxY,
            width: contentLayoutRect.width,
            height: contentLayoutRect.height
        ).intersection(CGRect(origin: .zero, size: windowSize))

        guard !rect.isNull, rect.width > 0, rect.height > 0 else {
            return nil
        }
        return rect
    }

    static func sourceRect(
        windowFrame: CGRect,
        captureRect: CGRect
    ) -> CGRect? {
        guard windowFrame.width > 0,
              windowFrame.height > 0,
              captureRect.width > 0,
              captureRect.height > 0 else {
            return nil
        }

        let rect = CGRect(
            x: captureRect.minX - windowFrame.minX,
            y: windowFrame.maxY - captureRect.maxY,
            width: captureRect.width,
            height: captureRect.height
        ).intersection(CGRect(origin: .zero, size: windowFrame.size))

        guard !rect.isNull, rect.width > 0, rect.height > 0 else {
            return nil
        }
        return rect
    }

    static func outputSize(
        sourceSize: CGSize,
        backingScale: CGFloat,
        maximumHeight: CGFloat
    ) -> CGSize {
        let pixelScale = max(backingScale, 1)
        let scaledHeight = sourceSize.height * pixelScale
        let downscale = min(1, maximumHeight / max(scaledHeight, 1))
        let width = max(2, Int(sourceSize.width * pixelScale * downscale) & ~1)
        let height = max(2, Int(scaledHeight * downscale) & ~1)
        return CGSize(width: width, height: height)
    }
}

private final class WorkspaceRecordingStreamOutput:
    NSObject,
    SCStreamOutput,
    SCStreamDelegate,
    @unchecked Sendable
{
    private let writer: ScreenCaptureRecordingWriter

    init(writer: ScreenCaptureRecordingWriter) {
        self.writer = writer
        super.init()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let statusRawValue = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRawValue) == .complete else {
            return
        }
        writer.append(sampleBuffer)
    }
}

private final class ScreenCaptureRecordingWriter: @unchecked Sendable {
    let sampleQueue = DispatchQueue(
        label: "com.viewport.recording.screen-capture",
        qos: .userInteractive
    )

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var hasStartedSession = false
    private var hasFinished = false

    init(
        outputURL: URL,
        width: Int,
        height: Int,
        framesPerSecond: Int32
    ) throws {
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let bitRate = max(5_000_000, width * height * 6)
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

        guard writer.canAdd(input) else {
            throw WorkspaceRecordingError.writerSetupFailed
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? WorkspaceRecordingError.writerSetupFailed
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(sampleQueue))
        guard !hasFinished,
              writer.status == .writing,
              input.isReadyForMoreMediaData else {
            return
        }

        if !hasStartedSession {
            let presentationTime = sampleBuffer.presentationTimeStamp
            guard presentationTime.isValid else { return }
            writer.startSession(atSourceTime: presentationTime)
            hasStartedSession = true
        }
        input.append(sampleBuffer)
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
