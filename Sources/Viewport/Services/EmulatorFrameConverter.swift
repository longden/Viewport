import Accelerate
import CoreGraphics
import CoreVideo
import Foundation
import IOSurface

/// Swizzles emulator RGBA8888 rows into pooled, IOSurface-backed BGRA buffers
/// so Core Animation presents them without a main-thread image copy and
/// color conversion. Not thread-safe; use from one serial queue.
final class EmulatorFrameConverter {
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        .flatMap { $0.copyPropertyList() }

    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var taggedSurfaceIDs: Set<IOSurfaceID> = []

    func makePixelBuffer(
        rgba: UnsafeRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> CVPixelBuffer? {
        guard width > 0, height > 0, bytesPerRow >= width * 4,
              let pool = pool(width: width, height: height) else {
            return nil
        }
        var created: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
            == kCVReturnSuccess,
            let buffer = created else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let destinationBase = CVPixelBufferGetBaseAddress(buffer) else {
            return nil
        }
        var source = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: rgba),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: bytesPerRow
        )
        var destination = vImage_Buffer(
            data: destinationBase,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(buffer)
        )
        // RGBA → BGRA, forcing the last byte opaque: the emulator's alpha
        // channel is not guaranteed to be 0xFF.
        let status = vImagePermuteChannelsWithMaskedInsert_ARGB8888(
            &source,
            &destination,
            [2, 1, 0, 3],
            0x1,
            [0, 0, 0, 0xFF],
            vImage_Flags(kvImageNoFlags)
        )
        guard status == kvImageNoError else { return nil }
        tagColorSpace(of: buffer)
        return buffer
    }

    private func pool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let pool, poolWidth == width, poolHeight == height {
            return pool
        }
        pool = nil
        taggedSurfaceIDs.removeAll()
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        var created: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            nil,
            nil,
            attributes as CFDictionary,
            &created
        ) == kCVReturnSuccess else {
            return nil
        }
        pool = created
        poolWidth = width
        poolHeight = height
        return created
    }

    /// Core Animation reads color space from the IOSurface, not CVBuffer
    /// attachments. Pool buffers are recycled, so tag each surface once.
    private func tagColorSpace(of buffer: CVPixelBuffer) {
        guard let colorSpace = Self.colorSpace,
              let surface = CVPixelBufferGetIOSurface(buffer)?
                .takeUnretainedValue(),
              taggedSurfaceIDs.insert(IOSurfaceGetID(surface)).inserted else {
            return
        }
        IOSurfaceSetValue(surface, kIOSurfaceColorSpace, colorSpace)
    }
}

/// File-backed shared memory the emulator writes frames into when the stream
/// requests `ImageTransport.MMAP`. Unmapped on deinit.
final class EmulatorSharedFrameBuffer: @unchecked Sendable {
    let byteCount: Int
    let baseAddress: UnsafeRawPointer
    let handle: String
    private let path: String

    init?(
        byteCount: Int,
        directory: URL = FileManager.default.temporaryDirectory
    ) {
        guard byteCount > 0 else { return nil }
        let url = directory.appendingPathComponent(
            "viewport-emulator-\(UUID().uuidString).rgba"
        )
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(byteCount)) == 0 else {
            unlink(url.path)
            return nil
        }
        let mapped = mmap(nil, byteCount, PROT_READ, MAP_SHARED, descriptor, 0)
        guard let mapped, mapped != MAP_FAILED else {
            unlink(url.path)
            return nil
        }
        self.byteCount = byteCount
        baseAddress = UnsafeRawPointer(mapped)
        path = url.path
        handle = "file://" + url.path
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: baseAddress), byteCount)
        removeFile()
    }

    /// The mapping stays valid after unlink; this only drops the temp file.
    func removeFile() {
        unlink(path)
    }
}
