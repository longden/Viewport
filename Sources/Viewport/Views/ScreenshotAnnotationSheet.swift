import AppKit
import SwiftUI

struct ScreenshotAnnotationSheet: View {
    let image: CGImage
    var onSaved: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: ScreenshotAnnotationKind = .arrow
    @State private var annotations: [ScreenshotAnnotation] = []
    @State private var draftStart: CGPoint?
    @State private var draftEnd: CGPoint?
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var didSave = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            canvas
            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 560, idealHeight: 620)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Annotate screenshot")
                    .font(.title3.weight(.semibold))
                Text("Draw arrows, boxes, or redaction regions, then save.")
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

    private var canvas: some View {
        GeometryReader { proxy in
            let fitted = fittedImageSize(in: proxy.size)
            ZStack {
                Color.black.opacity(0.88)
                Image(
                    nsImage: NSImage(
                        cgImage: image,
                        size: NSSize(width: image.width, height: image.height)
                    )
                )
                .resizable()
                .interpolation(.high)
                .frame(width: fitted.width, height: fitted.height)

                annotationOverlay(size: fitted)
                    .frame(width: fitted.width, height: fitted.height)
                    .gesture(dragGesture(in: fitted))
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

    @ViewBuilder
    private func annotationOverlay(size: CGSize) -> some View {
        Canvas { context, _ in
            for annotation in annotations {
                draw(annotation, in: context, size: size)
            }
            if let draftStart, let draftEnd {
                draw(
                    ScreenshotAnnotation(
                        kind: kind,
                        start: draftStart,
                        end: draftEnd
                    ),
                    in: context,
                    size: size
                )
            }
        }
        .allowsHitTesting(true)
        .contentShape(Rectangle())
    }

    private func draw(
        _ annotation: ScreenshotAnnotation,
        in context: GraphicsContext,
        size: CGSize
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
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            context.stroke(
                path,
                with: .color(.red),
                lineWidth: ScreenshotAnnotationRenderer.arrowLineWidth
            )
            // Match export arrowhead for WYSIWYG preview.
            let angle = atan2(end.y - start.y, end.x - start.x)
            let head: CGFloat = 18
            var headPath = Path()
            headPath.move(to: end)
            headPath.addLine(
                to: CGPoint(
                    x: end.x - head * cos(angle - .pi / 6),
                    y: end.y - head * sin(angle - .pi / 6)
                )
            )
            headPath.addLine(
                to: CGPoint(
                    x: end.x - head * cos(angle + .pi / 6),
                    y: end.y - head * sin(angle + .pi / 6)
                )
            )
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
            context.fill(
                Path(rect),
                with: .color(
                    .black.opacity(ScreenshotAnnotationRenderer.redactFillAlpha)
                )
            )
            context.stroke(
                Path(rect),
                with: .color(
                    .white.opacity(ScreenshotAnnotationRenderer.redactStrokeAlpha)
                ),
                lineWidth: 1
            )
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

    private func fittedImageSize(in container: CGSize) -> CGSize {
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
            let output: CGImage
            if annotated, !annotations.isEmpty {
                output = try ScreenshotAnnotationRenderer.render(
                    image,
                    annotations: annotations
                )
            } else {
                output = image
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
