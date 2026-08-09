import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import IOSurface

/// Retained IOSurface handle that releases on deinit. Safe to hop off MainActor
/// for GPU compositing without forcing a CPU bitmap readback.
final class BorrowedIOSurface: @unchecked Sendable {
    let surface: IOSurfaceRef

    init(_ surface: IOSurfaceRef) {
        self.surface = Unmanaged.passUnretained(surface).retain()
            .takeUnretainedValue()
    }

    deinit {
        Unmanaged.passUnretained(surface).release()
    }
}

/// Latest live frame from a capture presenter, preferring GPU-backed forms.
enum LiveCaptureFrame: @unchecked Sendable {
    case pixelBuffer(CVPixelBuffer)
    case surface(BorrowedIOSurface)
    case image(CGImage)

    var size: CGSize {
        switch self {
        case let .pixelBuffer(buffer):
            CGSize(
                width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer)
            )
        case let .surface(borrowed):
            CGSize(
                width: IOSurfaceGetWidth(borrowed.surface),
                height: IOSurfaceGetHeight(borrowed.surface)
            )
        case let .image(image):
            CGSize(width: image.width, height: image.height)
        }
    }
}

/// Thread-safe latest-frame slot for composite encode off the MainActor.
final class LatestLiveFrameSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: LiveCaptureFrame?

    func store(_ frame: LiveCaptureFrame?) {
        lock.lock()
        self.frame = frame
        lock.unlock()
    }

    func load() -> LiveCaptureFrame? {
        lock.lock()
        defer { lock.unlock() }
        return frame
    }

    func clear() {
        store(nil)
    }
}

@MainActor
final class CaptureFramePresenter {
    /// Updated on every display; readable from the encode loop without MainActor.
    nonisolated let recordingFrameSlot = LatestLiveFrameSlot()

    private weak var previewView: CapturePreviewNSView?
    /// Cached CGImage for screenshots. Produced lazily from the live buffer /
    /// surface so streaming never pays for a GPU→CPU readback.
    // Cleared from `deinit` / `clearStoredFrames()` off the MainActor.
    private nonisolated(unsafe) var cachedSnapshot: CGImage?
    private nonisolated(unsafe) var latestPixelBuffer: CVPixelBuffer?
    private nonisolated(unsafe) var latestSurface: IOSurfaceRef?
    private(set) var frameSize: CGSize?

    private let snapshotContext = CIContext(options: [.cacheIntermediates: false])

    deinit {
        // Release retained surfaces without hopping to MainActor.
        cachedSnapshot = nil
        latestPixelBuffer = nil
        if let surface = latestSurface {
            Unmanaged.passUnretained(surface).release()
            latestSurface = nil
        }
        recordingFrameSlot.clear()
    }

    var latestFrame: CGImage? {
        if let cachedSnapshot { return cachedSnapshot }
        if let buffer = latestPixelBuffer,
           let image = snapshotContext.createCGImage(
            CIImage(cvPixelBuffer: buffer),
            from: CIImage(cvPixelBuffer: buffer).extent
           ) {
            cachedSnapshot = image
            return image
        }
        if let surface = latestSurface,
           let image = snapshotImage(from: surface) {
            cachedSnapshot = image
            return image
        }
        return nil
    }

    /// Zero-copy when a pixel buffer or IOSurface is available; falls back to
    /// the screenshot CGImage path for host-window / polling transports.
    var liveFrame: LiveCaptureFrame? {
        if let buffer = latestPixelBuffer {
            return .pixelBuffer(buffer)
        }
        if let surface = latestSurface {
            return .surface(BorrowedIOSurface(surface))
        }
        if let image = latestFrame {
            return .image(image)
        }
        return nil
    }

    func attach(_ view: CapturePreviewNSView) {
        previewView = view
    }

    func detach(_ view: CapturePreviewNSView) {
        guard previewView === view else { return }
        previewView = nil
    }

    func clear() {
        frameSize = nil
        clearStoredFrames()
        previewView?.clear()
    }

    @discardableResult
    func display(_ image: CGImage, sourceSize: CGSize? = nil) -> CGSize? {
        let size = sourceSize
            ?? CGSize(width: image.width, height: image.height)
        let changedSize = updateSize(size)
        releaseStoredFrames()
        cachedSnapshot = image
        publishRecordingFrame(.image(image))
        previewView?.display(image)
        return changedSize
    }

    @discardableResult
    func display(surface: IOSurfaceRef) -> CGSize? {
        let size = CGSize(
            width: IOSurfaceGetWidth(surface),
            height: IOSurfaceGetHeight(surface)
        )
        let changedSize = updateSize(size)
        releaseStoredFrames()
        latestSurface = Unmanaged.passUnretained(surface).retain()
            .takeUnretainedValue()
        publishRecordingFrame(.surface(BorrowedIOSurface(surface)))
        previewView?.display(surface: surface)
        return changedSize
    }

    /// Zero-copy display of a VideoToolbox / AVFoundation pixel buffer.
    /// Prefers the backing IOSurface when present so CALayer never sees a
    /// CPU bitmap.
    @discardableResult
    func display(pixelBuffer: CVPixelBuffer) -> CGSize? {
        let size = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        let changedSize = updateSize(size)
        releaseStoredFrames()
        latestPixelBuffer = pixelBuffer
        if let surface = CVPixelBufferGetIOSurface(pixelBuffer)?
            .takeUnretainedValue() {
            publishRecordingFrame(.surface(BorrowedIOSurface(surface)))
            previewView?.display(surface: surface)
        } else {
            publishRecordingFrame(.pixelBuffer(pixelBuffer))
            previewView?.display(pixelBuffer: pixelBuffer)
        }
        return changedSize
    }

    private func publishRecordingFrame(_ frame: LiveCaptureFrame) {
        recordingFrameSlot.store(frame)
    }

    private func clearStoredFrames() {
        releaseStoredFrames()
        recordingFrameSlot.clear()
    }

    private func releaseStoredFrames() {
        cachedSnapshot = nil
        latestPixelBuffer = nil
        if let surface = latestSurface {
            Unmanaged.passUnretained(surface).release()
            latestSurface = nil
        }
    }

    private func updateSize(_ size: CGSize) -> CGSize? {
        guard frameSize != size else { return nil }
        frameSize = size
        previewView?.sourceSizeDidChange()
        return size
    }

    /// Prefer Core Image's IOSurface path; fall back to a CPU copy only if CI fails.
    private func snapshotImage(from surface: IOSurfaceRef) -> CGImage? {
        let ciImage = CIImage(ioSurface: surface)
        if let image = snapshotContext.createCGImage(
            ciImage,
            from: ciImage.extent
        ) {
            return image
        }
        return CGImage.viewportImageFromCPUCopy(from: surface)
    }
}

private extension CGImage {
    static func viewportImageFromCPUCopy(from surface: IOSurfaceRef) -> CGImage? {
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        guard width > 0, height > 0 else { return nil }
        IOSurfaceLock(surface, [.readOnly], nil)
        defer { IOSurfaceUnlock(surface, [.readOnly], nil) }
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        let data = Data(
            bytes: IOSurfaceGetBaseAddress(surface),
            count: bytesPerRow * height
        )
        guard let provider = CGDataProvider(data: data as CFData) else {
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
