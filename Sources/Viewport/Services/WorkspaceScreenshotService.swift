import AppKit
import CoreGraphics
import CoreText
import Foundation
import UniformTypeIdentifiers

enum WorkspaceScreenshotError: LocalizedError {
    case noCapturablePanes
    case paneNotCapturable(ViewerSource)
    case imageCreationFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .noCapturablePanes:
            "Nothing to capture. Open a pane that has a live view."
        case let .paneNotCapturable(source):
            "Nothing to capture in the \(ScreenshotPlatformLabel.title(for: source)) pane."
        case .imageCreationFailed:
            "The screenshot could not be created."
        case .encodingFailed:
            "The screenshot could not be encoded as a PNG."
        }
    }
}

enum CompositeScreenshotLayout {
    static let labelBandHeight: CGFloat = 96
    static let labelToImageSpacing: CGFloat = 16
    static let labelFontSize: CGFloat = 64

    static func frames(
        for sizes: [CGSize],
        maximumHeight: CGFloat = 2_048,
        spacing: CGFloat = 16,
        includeLabels: Bool = false
    ) -> (canvas: CGSize, images: [CGRect], labels: [CGRect])? {
        guard !sizes.isEmpty,
              sizes.allSatisfy({ $0.width > 0 && $0.height > 0 }) else {
            return nil
        }

        let targetHeight = min(
            sizes.map(\.height).max() ?? maximumHeight,
            maximumHeight
        )
        let labelBand = includeLabels ? labelBandHeight : 0
        let labelGap = includeLabels ? labelToImageSpacing : 0
        var x: CGFloat = 0
        var images: [CGRect] = []
        var labels: [CGRect] = []

        for size in sizes {
            let width = targetHeight * size.width / size.height
            labels.append(
                CGRect(x: x, y: 0, width: width, height: labelBand)
            )
            images.append(
                CGRect(
                    x: x,
                    y: labelBand + labelGap,
                    width: width,
                    height: targetHeight
                )
            )
            x += width + spacing
        }

        return (
            CGSize(
                width: ceil(x - spacing),
                height: ceil(labelBand + labelGap + targetHeight)
            ),
            images,
            labels
        )
    }
}

struct ScreenshotPaneCapture: Identifiable {
    let id: UUID
    let source: ViewerSource
    let image: CGImage
    let label: String

    init(
        id: UUID = UUID(),
        source: ViewerSource,
        image: CGImage,
        label: String
    ) {
        self.id = id
        self.source = source
        self.image = image
        self.label = label
    }
}

enum ScreenshotPlatformLabel {
    static func title(for source: ViewerSource) -> String {
        switch source {
        case .web:
            "Web"
        case .android:
            "Android"
        case .iOS:
            "iOS"
        }
    }
}

enum WorkspaceScreenshotNaming {
    static func filename(
        source: ViewerSource? = nil,
        fileExtension: String = "png",
        date: Date = Date()
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = formatter.string(from: date)
        if let source {
            return "Viewport-\(ScreenshotPlatformLabel.title(for: source))-\(stamp).\(fileExtension)"
        }
        return "Viewport \(stamp).\(fileExtension)"
    }
}

@MainActor
struct WorkspaceScreenshotService {
    func createComposite(
        sources: [ViewerSource],
        web: WebViewModel,
        workspace: WorkspaceStore,
        includePlatformLabels: Bool,
        includeDeviceBezels: Bool = false
    ) async throws -> CGImage {
        let panes = await collectPanes(
            sources: sources,
            web: web,
            workspace: workspace,
            includeDeviceBezels: includeDeviceBezels
        )
        guard !panes.isEmpty else {
            throw WorkspaceScreenshotError.noCapturablePanes
        }
        return try compose(panes, includePlatformLabels: includePlatformLabels)
    }

    func createComposite(
        sources: [PaneGridNode],
        web: WebViewModel,
        workspace: WorkspaceStore,
        includePlatformLabels: Bool,
        includeDeviceBezels: Bool = false
    ) async throws -> CGImage {
        let panes = await collectPanes(
            nodes: sources,
            web: web,
            workspace: workspace,
            includeDeviceBezels: includeDeviceBezels
        )
        guard !panes.isEmpty else {
            throw WorkspaceScreenshotError.noCapturablePanes
        }
        return try compose(panes, includePlatformLabels: includePlatformLabels)
    }

    func captureWeb(_ web: WebViewModel) async throws -> CGImage {
        guard let image = await snapshotWeb(web) else {
            throw WorkspaceScreenshotError.paneNotCapturable(.web)
        }
        return image
    }

    func captureDevice(session: WindowCaptureSession) throws -> CGImage {
        guard let image = session.snapshotFrame() else {
            throw WorkspaceScreenshotError.paneNotCapturable(session.source)
        }
        return image
    }

    func capturePane(
        source: ViewerSource,
        web: WebViewModel,
        workspace: WorkspaceStore
    ) async throws -> CGImage {
        switch source {
        case .web:
            try await captureWeb(web)
        case .android:
            try captureDevice(session: workspace.androidCapture)
        case .iOS:
            try captureDevice(session: workspace.iOSCapture)
        }
    }

    func collectPanes(
        sources: [ViewerSource],
        web: WebViewModel,
        workspace: WorkspaceStore,
        includeDeviceBezels: Bool = false
    ) async -> [ScreenshotPaneCapture] {
        var panes: [ScreenshotPaneCapture] = []

        for source in sources {
            switch source {
            case .web:
                guard let image = await snapshotWeb(web) else { continue }
                panes.append(
                    ScreenshotPaneCapture(
                        source: .web,
                        image: image,
                        label: ScreenshotPlatformLabel.title(for: .web)
                    )
                )
            case .android:
                if let image = framed(
                    workspace.androidCapture.snapshotFrame(),
                    includeDeviceBezels: includeDeviceBezels
                ) {
                    panes.append(
                        ScreenshotPaneCapture(
                            source: .android,
                            image: image,
                            label: ScreenshotPlatformLabel.title(for: .android)
                        )
                    )
                }
                if workspace.paneCount(of: .android) > 1,
                   let image = framed(
                    workspace.androidCaptureSecondary.snapshotFrame(),
                    includeDeviceBezels: includeDeviceBezels
                   ) {
                    panes.append(
                        ScreenshotPaneCapture(
                            source: .android,
                            image: image,
                            label: "Android 2"
                        )
                    )
                }
            case .iOS:
                if let image = framed(
                    workspace.iOSCapture.snapshotFrame(),
                    includeDeviceBezels: includeDeviceBezels
                ) {
                    panes.append(
                        ScreenshotPaneCapture(
                            source: .iOS,
                            image: image,
                            label: ScreenshotPlatformLabel.title(for: .iOS)
                        )
                    )
                }
                if workspace.paneCount(of: .iOS) > 1,
                   let image = framed(
                    workspace.iOSCaptureSecondary.snapshotFrame(),
                    includeDeviceBezels: includeDeviceBezels
                   ) {
                    panes.append(
                        ScreenshotPaneCapture(
                            source: .iOS,
                            image: image,
                            label: "iOS 2"
                        )
                    )
                }
            }
        }

        return panes
    }

    func collectPanes(
        nodes: [PaneGridNode],
        web: WebViewModel,
        workspace: WorkspaceStore,
        includeDeviceBezels: Bool = false
    ) async -> [ScreenshotPaneCapture] {
        var panes: [ScreenshotPaneCapture] = []

        for node in nodes {
            guard let source = node.viewerSource else { continue }
            switch source {
            case .web:
                guard let image = await snapshotWeb(web) else { continue }
                panes.append(
                    ScreenshotPaneCapture(
                        source: .web,
                        image: image,
                        label: ScreenshotPlatformLabel.title(for: .web)
                    )
                )
            case .android, .iOS:
                guard let session = workspace.captureSession(for: node),
                      let image = framed(
                        session.snapshotFrame(),
                        includeDeviceBezels: includeDeviceBezels
                      ) else {
                    continue
                }
                let base = ScreenshotPlatformLabel.title(for: source)
                let label = node.slot >= 1 ? "\(base) \(node.slot + 1)" : base
                panes.append(
                    ScreenshotPaneCapture(
                        source: source,
                        image: image,
                        label: label
                    )
                )
            }
        }

        return panes
    }

    private func framed(
        _ image: CGImage?,
        includeDeviceBezels: Bool
    ) -> CGImage? {
        guard let image else { return nil }
        guard includeDeviceBezels else { return image }
        return DeviceBezelRenderer.draw(image: image) ?? image
    }

    func compose(
        _ panes: [ScreenshotPaneCapture],
        includePlatformLabels: Bool
    ) throws -> CGImage {
        try compose(
            panes,
            labeledPaneIDs: includePlatformLabels
                ? Set(panes.map(\.id))
                : []
        )
    }

    /// Composes panes side-by-side. Label names are drawn for IDs in
    /// `labeledPaneIDs`. Pass `reserveLabelBand: true` to keep the band even
    /// when no names are selected (stable layout for annotation).
    func compose(
        _ panes: [ScreenshotPaneCapture],
        labeledPaneIDs: Set<UUID>,
        reserveLabelBand: Bool = false
    ) throws -> CGImage {
        guard !panes.isEmpty else {
            throw WorkspaceScreenshotError.noCapturablePanes
        }

        let includeLabelBand = reserveLabelBand || !labeledPaneIDs.isEmpty
        guard let layout = CompositeScreenshotLayout.frames(
            for: panes.map {
                CGSize(width: $0.image.width, height: $0.image.height)
            },
            includeLabels: includeLabelBand
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

        if includeLabelBand {
            for (pane, frame) in zip(panes, layout.labels)
            where labeledPaneIDs.contains(pane.id) {
                context.setFillColor(CGColor.black)
                context.fill(cgRect(frame, canvasHeight: layout.canvas.height))
            }
        }

        for (pane, frame) in zip(panes, layout.images) {
            context.interpolationQuality = .high
            context.draw(
                pane.image,
                in: cgRect(frame, canvasHeight: layout.canvas.height)
            )
        }

        if includeLabelBand {
            for (pane, frame) in zip(panes, layout.labels)
            where labeledPaneIDs.contains(pane.id) {
                drawLabel(
                    pane.label,
                    in: frame,
                    canvasHeight: layout.canvas.height,
                    context: context
                )
            }
        }

        guard let result = context.makeImage() else {
            throw WorkspaceScreenshotError.imageCreationFailed
        }
        return result
    }

    /// Draws panes into a fixed canvas (for recording). Scales each strip into
    /// equal-width slots when the source count matches `slotCount`.
    func compose(
        _ panes: [ScreenshotPaneCapture],
        into canvasSize: CGSize,
        background: CGColor = NSColor.windowBackgroundColor.cgColor
    ) throws -> CGImage {
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            throw WorkspaceScreenshotError.imageCreationFailed
        }
        guard !panes.isEmpty else {
            throw WorkspaceScreenshotError.noCapturablePanes
        }

        guard let context = CGContext(
            data: nil,
            width: Int(canvasSize.width),
            height: Int(canvasSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw WorkspaceScreenshotError.imageCreationFailed
        }

        context.setFillColor(background)
        context.fill(CGRect(origin: .zero, size: canvasSize))

        guard let layout = CompositeScreenshotLayout.frames(
            for: panes.map {
                CGSize(width: $0.image.width, height: $0.image.height)
            },
            maximumHeight: canvasSize.height,
            includeLabels: false
        ) else {
            throw WorkspaceScreenshotError.imageCreationFailed
        }

        let scaleX = canvasSize.width / max(layout.canvas.width, 1)
        let scaleY = canvasSize.height / max(layout.canvas.height, 1)
        let scale = min(scaleX, scaleY)
        let scaledWidth = layout.canvas.width * scale
        let scaledHeight = layout.canvas.height * scale
        let offsetX = (canvasSize.width - scaledWidth) / 2
        let offsetY = (canvasSize.height - scaledHeight) / 2

        for (pane, frame) in zip(panes, layout.images) {
            let dest = CGRect(
                x: offsetX + frame.minX * scale,
                y: offsetY + frame.minY * scale,
                width: frame.width * scale,
                height: frame.height * scale
            )
            context.interpolationQuality = .medium
            context.draw(
                pane.image,
                in: cgRect(dest, canvasHeight: canvasSize.height)
            )
        }

        guard let result = context.makeImage() else {
            throw WorkspaceScreenshotError.imageCreationFailed
        }
        return result
    }

    func save(
        _ image: CGImage,
        preferredName: String,
        panelTitle: String
    ) throws -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = preferredName
        panel.title = panelTitle

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }

        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(
            using: .png,
            properties: [:]
        ) else {
            throw WorkspaceScreenshotError.encodingFailed
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    func saveCombined(_ image: CGImage) throws -> URL? {
        try save(
            image,
            preferredName: WorkspaceScreenshotNaming.filename(),
            panelTitle: "Save Combined Screenshot"
        )
    }

    func savePane(_ image: CGImage, source: ViewerSource) throws -> URL? {
        try save(
            image,
            preferredName: WorkspaceScreenshotNaming.filename(source: source),
            panelTitle: "Save \(ScreenshotPlatformLabel.title(for: source)) Screenshot"
        )
    }

    func snapshotWeb(_ web: WebViewModel) async -> CGImage? {
        guard web.webView.url != nil,
              let snapshot = try? await web.webView.takeSnapshot(
                  configuration: nil
              ) else {
            return nil
        }
        return snapshot.cgImage(
            forProposedRect: nil,
            context: nil,
            hints: nil
        )
    }

    private func drawLabel(
        _ text: String,
        in topDownFrame: CGRect,
        canvasHeight: CGFloat,
        context: CGContext
    ) {
        guard topDownFrame.height > 0, !text.isEmpty else { return }

        let frame = cgRect(topDownFrame, canvasHeight: canvasHeight)
        let font = CTFontCreateWithName(
            "Helvetica-Bold" as CFString,
            CompositeScreenshotLayout.labelFontSize,
            nil
        )
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor.white
        ]
        let attributed = CFAttributedStringCreate(
            nil,
            text as CFString,
            attributes as CFDictionary
        )!
        let line = CTLineCreateWithAttributedString(attributed)

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(
            line,
            &ascent,
            &descent,
            nil
        )
        let textHeight = ascent + descent
        let x = frame.minX + (frame.width - width) / 2
        let y = frame.minY + (frame.height - textHeight) / 2 + descent

        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func cgRect(
        _ rect: CGRect,
        canvasHeight: CGFloat
    ) -> CGRect {
        CGRect(
            x: rect.minX,
            y: canvasHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
