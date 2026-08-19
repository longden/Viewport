import AppKit
import SwiftUI

struct ScreenshotAnnotationSheet: View {
    let panes: [ScreenshotPaneCapture]
    var labelsEnabledByDefault: Bool = true
    var onSaved: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: ScreenshotAnnotationKind = .arrow
    @State private var annotations: [ScreenshotAnnotation] = []
    @State private var draftStart: CGPoint?
    @State private var draftEnd: CGPoint?
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var didSave = false
    @State private var labeledPaneIDs: Set<UUID> = []
    @State private var composedImage: CGImage?
    @State private var previewFittedSize: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if panes.count > 1 || !panes.isEmpty {
                labelToggles
                Divider()
            }
            canvas
            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 860, minHeight: 600, idealHeight: 660)
        .onAppear {
            if labelsEnabledByDefault {
                labeledPaneIDs = Set(panes.map(\.id))
            }
            rebuildComposite()
        }
        .onChange(of: labeledPaneIDs) { _, _ in
            rebuildComposite()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Annotate screenshot")
                    .font(.title3.weight(.semibold))
                Text("Draw arrows, boxes, or pixelate redaction regions, then save.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Tool", selection: $kind) {
                ForEach(ScreenshotAnnotationKind.allCases) { tool in
                    Label(tool.title, systemImage: tool.systemImage)
                        .tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            Button("Discard") {
                didSave = true
                dismiss()
            }
            .disabled(isSaving)

            Button("Close") {
                closeSavingOriginalIfNeeded()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(isSaving)
        }
        .padding(16)
    }

    private var labelToggles: some View {
        HStack(spacing: 14) {
            Text("Labels")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(panes) { pane in
                Toggle(isOn: binding(for: pane.id)) {
                    Text(pane.label)
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var canvas: some View {
        GeometryReader { proxy in
            let image = composedImage
            let fitted = image.map { fittedImageSize(for: $0, in: proxy.size) }
                ?? .zero
            ZStack {
                Color.black.opacity(0.88)
                if let image, fitted.width > 0 {
                    Image(
                        nsImage: NSImage(
                            cgImage: image,
                            size: NSSize(
                                width: image.width,
                                height: image.height
                            )
                        )
                    )
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fitted.width, height: fitted.height)

                    annotationOverlay(size: fitted, baseImage: image)
                        .frame(width: fitted.width, height: fitted.height)
                        .gesture(dragGesture(in: fitted))
                        .onAppear { previewFittedSize = fitted }
                        .onChange(of: fitted.width) { _, _ in
                            previewFittedSize = fitted
                        }
                        .onChange(of: fitted.height) { _, _ in
                            previewFittedSize = fitted
                        }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Button("Undo") {
                _ = annotations.popLast()
            }
            .disabled(annotations.isEmpty || isSaving)

            Button("Clear") {
                annotations.removeAll()
                draftStart = nil
                draftEnd = nil
            }
            .disabled(annotations.isEmpty && draftStart == nil)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()

            Button("Save without annotations") {
                save(annotated: false)
            }
            .disabled(isSaving)

            Button("Save PNG…") {
                save(annotated: true)
            }
            .disabled(isSaving)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func binding(for paneID: UUID) -> Binding<Bool> {
        Binding(
            get: { labeledPaneIDs.contains(paneID) },
            set: { isOn in
                if isOn {
                    labeledPaneIDs.insert(paneID)
                } else {
                    labeledPaneIDs.remove(paneID)
                }
            }
        )
    }

    private func rebuildComposite() {
        do {
            composedImage = try WorkspaceScreenshotService().compose(
                panes,
                labeledPaneIDs: labeledPaneIDs,
                reserveLabelBand: true
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private func annotationOverlay(size: CGSize, baseImage: CGImage) -> some View {
        Canvas { context, _ in
            for annotation in annotations {
                draw(
                    annotation,
                    in: context,
                    size: size,
                    baseImage: baseImage
                )
            }
            if let draftStart, let draftEnd {
                draw(
                    ScreenshotAnnotation(
                        kind: kind,
                        start: draftStart,
                        end: draftEnd
                    ),
                    in: context,
                    size: size,
                    baseImage: baseImage
                )
            }
        }
        .allowsHitTesting(true)
        .contentShape(Rectangle())
    }

    private func draw(
        _ annotation: ScreenshotAnnotation,
        in context: GraphicsContext,
        size: CGSize,
        baseImage: CGImage
    ) {
        let start = CGPoint(
            x: annotation.start.x * size.width,
            y: annotation.start.y * size.height
        )
        let end = CGPoint(
            x: annotation.end.x * size.width,
            y: annotation.end.y * size.height
        )
        switch annotation.kind {
        case .arrow:
            let geometry = ScreenshotAnnotationRenderer.arrowGeometry(
                from: start,
                to: end
            )
            var shaft = Path()
            shaft.move(to: start)
            shaft.addLine(to: geometry.shaftEnd)
            context.stroke(
                shaft,
                with: .color(.red),
                lineWidth: ScreenshotAnnotationRenderer.arrowLineWidth
            )
            var headPath = Path()
            headPath.move(to: geometry.tip)
            headPath.addLine(to: geometry.left)
            headPath.addLine(to: geometry.right)
            headPath.closeSubpath()
            context.fill(headPath, with: .color(.red))
        case .box:
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            context.stroke(
                Path(rect),
                with: .color(.yellow),
                lineWidth: ScreenshotAnnotationRenderer.boxLineWidth
            )
        case .redact:
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            let imageStart = ScreenshotAnnotationRenderer.denormalize(
                annotation.start,
                width: baseImage.width,
                height: baseImage.height
            )
            let imageEnd = ScreenshotAnnotationRenderer.denormalize(
                annotation.end,
                width: baseImage.width,
                height: baseImage.height
            )
            let crop = ScreenshotAnnotationRenderer.pixelCropRect(
                from: imageStart,
                to: imageEnd,
                imageWidth: baseImage.width,
                imageHeight: baseImage.height
            )
            if crop.width >= 1, crop.height >= 1,
               let mosaic = ScreenshotAnnotationRenderer.pixelatedImage(
                from: baseImage,
                cropRect: crop
               ) {
                context.draw(
                    Image(
                        nsImage: NSImage(
                            cgImage: mosaic,
                            size: NSSize(
                                width: mosaic.width,
                                height: mosaic.height
                            )
                        )
                    ),
                    in: rect
                )
            } else {
                context.fill(Path(rect), with: .color(.black))
            }
        }
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = normalize(value.startLocation, in: size)
                let end = normalize(value.location, in: size)
                draftStart = start
                draftEnd = end
            }
            .onEnded { value in
                let start = normalize(value.startLocation, in: size)
                let end = normalize(value.location, in: size)
                annotations.append(
                    ScreenshotAnnotation(kind: kind, start: start, end: end)
                )
                draftStart = nil
                draftEnd = nil
            }
    }

    private func normalize(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(point.x / max(size.width, 1), 0), 1),
            y: min(max(point.y / max(size.height, 1), 0), 1)
        )
    }

    private func fittedImageSize(for image: CGImage, in container: CGSize) -> CGSize {
        let imageSize = CGSize(width: image.width, height: image.height)
        let scale = min(
            container.width / max(imageSize.width, 1),
            container.height / max(imageSize.height, 1)
        )
        return CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
    }

    private func closeSavingOriginalIfNeeded() {
        guard !didSave else {
            dismiss()
            return
        }
        save(annotated: false)
    }

    private func save(annotated: Bool) {
        isSaving = true
        errorMessage = nil
        do {
            guard let base = composedImage else {
                throw WorkspaceScreenshotError.imageCreationFailed
            }
            let output: CGImage
            if annotated, !annotations.isEmpty {
                output = try ScreenshotAnnotationRenderer.render(
                    base,
                    annotations: annotations,
                    styleScale: ScreenshotAnnotationRenderer.styleScale(
                        imageWidth: base.width,
                        imageHeight: base.height,
                        previewSize: previewFittedSize
                    )
                )
            } else {
                output = base
            }
            let preferredName = WorkspaceScreenshotNaming.filename()
                .replacingOccurrences(
                    of: "Viewport",
                    with: annotated && !annotations.isEmpty
                        ? "Viewport-Annotated"
                        : "Viewport"
                )
            if let url = try WorkspaceScreenshotService().save(
                output,
                preferredName: preferredName,
                panelTitle: annotated && !annotations.isEmpty
                    ? "Save Annotated Screenshot"
                    : "Save Screenshot"
            ) {
                didSave = true
                onSaved(url)
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}
