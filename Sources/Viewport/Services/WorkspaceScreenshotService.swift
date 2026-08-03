import AppKit
import CoreGraphics
import Foundation

enum WorkspaceScreenshotError: LocalizedError {
    case missingFrame(ViewerSource)
    case webSnapshotUnavailable
    case imageCreationFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case let .missingFrame(source):
            source.title + " does not have a frame to capture yet."
        case .webSnapshotUnavailable:
            "The web view could not be captured."
        case .imageCreationFailed:
            "The combined screenshot could not be created."
        case .encodingFailed:
            "The combined screenshot could not be encoded as a PNG."
        }
    }
}

enum CompositeScreenshotLayout {
    static func frames(
        for sizes: [CGSize],
        maximumHeight: CGFloat = 2_048,
        spacing: CGFloat = 16
    ) -> (canvas: CGSize, images: [CGRect])? {
        guard !sizes.isEmpty,
              sizes.allSatisfy({ $0.width > 0 && $0.height > 0 }) else {
            return nil
        }

        let targetHeight = min(
            sizes.map(\.height).max() ?? maximumHeight,
            maximumHeight
        )
        var x: CGFloat = 0
        var frames: [CGRect] = []

        for size in sizes {
            let width = targetHeight * size.width / size.height
            frames.append(
                CGRect(x: x, y: 0, width: width, height: targetHeight)
            )
            x += width + spacing
        }

        return (
            CGSize(
                width: ceil(x - spacing),
                height: ceil(targetHeight)
            ),
            frames
        )
    }
}

@MainActor
struct WorkspaceScreenshotService {
    func createComposite(
        sources: [ViewerSource],
        web: WebViewModel,
        workspace: WorkspaceStore
    ) async throws -> CGImage {
        var images: [CGImage] = []

        for source in sources {
            switch source {
            case .web:
                let snapshot = try await web.webView.takeSnapshot(
                    configuration: nil
                )
                guard let image = snapshot.cgImage(
                    forProposedRect: nil,
                    context: nil,
                    hints: nil
                ) else {
                    throw WorkspaceScreenshotError.webSnapshotUnavailable
                }
                images.append(image)
            case .android:
                guard let image = workspace.androidCapture.snapshotFrame() else {
                    throw WorkspaceScreenshotError.missingFrame(.android)
                }
                images.append(image)
            case .iOS:
                guard let image = workspace.iOSCapture.snapshotFrame() else {
                    throw WorkspaceScreenshotError.missingFrame(.iOS)
                }
                images.append(image)
            }
        }

        guard let layout = CompositeScreenshotLayout.frames(
            for: images.map {
                CGSize(width: $0.width, height: $0.height)
            }
        ),
        let context = CGContext(
            data: nil,
            width: Int(layout.canvas.width),
            height: Int(layout.canvas.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw WorkspaceScreenshotError.imageCreationFailed
        }

        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(
            CGRect(origin: .zero, size: layout.canvas)
        )
        for (image, frame) in zip(images, layout.images) {
            context.interpolationQuality = .high
            context.draw(image, in: frame)
        }

        guard let result = context.makeImage() else {
            throw WorkspaceScreenshotError.imageCreationFailed
        }
        return result
    }

    func save(_ image: CGImage) throws -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultFilename
        panel.title = "Save Combined Screenshot"

        guard panel.runModal() == .OK, let url = panel.url else {
            return false
        }

        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(
            using: .png,
            properties: [:]
        ) else {
            throw WorkspaceScreenshotError.encodingFailed
        }
        try data.write(to: url, options: .atomic)
        return true
    }

    private var defaultFilename: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Viewport \(formatter.string(from: Date())).png"
    }
}
