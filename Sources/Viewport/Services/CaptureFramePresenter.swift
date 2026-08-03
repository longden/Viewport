import CoreGraphics
import Foundation
import IOSurface

@MainActor
final class CaptureFramePresenter {
    private weak var previewView: CapturePreviewNSView?
    private(set) var latestFrame: CGImage?
    private(set) var frameSize: CGSize?

    func attach(_ view: CapturePreviewNSView) {
        previewView = view
    }

    func detach(_ view: CapturePreviewNSView) {
        guard previewView === view else { return }
        previewView = nil
    }

    func clear() {
        frameSize = nil
        latestFrame = nil
        previewView?.clear()
    }

    @discardableResult
    func display(_ image: CGImage, sourceSize: CGSize? = nil) -> CGSize? {
        let size = sourceSize
            ?? CGSize(width: image.width, height: image.height)
        let changedSize = updateSize(size)
        latestFrame = image
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
        if let image = CGImage.viewportImage(from: surface) {
            latestFrame = image
        }
        previewView?.display(surface: surface)
        return changedSize
    }

    private func updateSize(_ size: CGSize) -> CGSize? {
        guard frameSize != size else { return nil }
        frameSize = size
        previewView?.sourceSizeDidChange()
        return size
    }
}

private extension CGImage {
    static func viewportImage(from surface: IOSurfaceRef) -> CGImage? {
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
