import AppKit
import SwiftUI

/// Inspector and design-QA layer drawn over one pane's displayed frame.
/// Passive (no hit testing) unless a tool needs the pane's clicks.
struct PaneInspectionOverlay: View {
    @ObservedObject var inspector: InspectorStore
    let paneID: UUID
    /// Pixel size of the streamed frame; nil when content fills the pane (web).
    let contentSize: CGSize?
    @State private var dragStart: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            let frame = InspectorOverlayGeometry.contentFrame(
                in: proxy.size,
                contentSize: contentSize
            )
            ZStack(alignment: .topLeading) {
                if let overlay = inspector.overlays[paneID], overlay.isVisible {
                    DesignOverlayLayer(overlay: overlay)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .allowsHitTesting(false)
                }

                if inspector.grid.isEnabled, let metrics = inspector.metrics(for: paneID) {
                    GridCanvas(grid: inspector.grid, metrics: metrics, frame: frame)
                        .allowsHitTesting(false)
                }

                if inspector.showsElementOverlay {
                    ElementHighlightCanvas(inspector: inspector, paneID: paneID, frame: frame)
                        .allowsHitTesting(false)
                    hoverLabel(in: frame, bounds: proxy.size)
                        .allowsHitTesting(false)
                }

                if let measurement = inspector.measurement, measurement.paneID == paneID {
                    MeasurementCanvas(
                        rect: InspectorOverlayGeometry.rect(measurement.rect, in: frame),
                        label: measurementLabel(measurement.rect)
                    )
                    .allowsHitTesting(false)
                }

                if inspector.isPresented, inspector.tab == .design,
                   inspector.designTool == .colorPicker,
                   let loupe = inspector.loupe, loupe.paneID == paneID {
                    ColorLoupe(image: loupe.image, sample: inspector.hoverColor)
                        .position(loupePosition(
                            for: InspectorOverlayGeometry.point(loupe.point, in: frame),
                            bounds: proxy.size
                        ))
                        .allowsHitTesting(false)
                }

                if inspector.interceptsPaneInput {
                    interactionLayer(frame: frame)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    private func interactionLayer(frame: CGRect) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case let .active(location):
                    inspector.hover(
                        paneID: paneID,
                        at: InspectorOverlayGeometry.normalized(location, in: frame)
                    )
                case .ended:
                    inspector.hover(paneID: paneID, at: nil)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard isMeasuring else { return }
                        let point = InspectorOverlayGeometry.clampedNormalized(value.location, in: frame)
                        if dragStart == nil {
                            dragStart = value.startLocation
                            inspector.beginMeasurement(
                                paneID: paneID,
                                at: InspectorOverlayGeometry.clampedNormalized(value.startLocation, in: frame)
                            )
                        }
                        inspector.updateMeasurement(to: point)
                    }
                    .onEnded { value in
                        defer { dragStart = nil }
                        if isMeasuring {
                            inspector.endMeasurement(
                                at: InspectorOverlayGeometry.clampedNormalized(value.location, in: frame)
                            )
                            return
                        }
                        let moved = hypot(
                            value.location.x - value.startLocation.x,
                            value.location.y - value.startLocation.y
                        )
                        guard moved < 4,
                              let point = InspectorOverlayGeometry.normalized(value.location, in: frame) else {
                            return
                        }
                        inspector.click(paneID: paneID, at: point)
                    }
            )
    }

    private var isMeasuring: Bool {
        inspector.tab == .design && inspector.designTool == .measure
    }

    @ViewBuilder
    private func hoverLabel(in frame: CGRect, bounds: CGSize) -> some View {
        if let hovered = inspector.hovered, hovered.paneID == paneID,
           let snapshot = inspector.snapshot(for: paneID),
           let element = snapshot.element(id: hovered.elementID) {
            let rect = InspectorOverlayGeometry.rect(element.frame, in: frame)
            let text = "\(element.role.title) · \(element.displayName) · \(Int(element.size.width.rounded()))×\(Int(element.size.height.rounded())) \(snapshot.unit)"
            Text(text)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .frame(maxWidth: max(bounds.width - 8, 40), alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .offset(
                    x: min(max(rect.minX, 4), max(bounds.width - 200, 4)),
                    y: rect.minY > 24 ? rect.minY - 22 : min(rect.maxY + 4, bounds.height - 22)
                )
        }
    }

    private func measurementLabel(_ rect: CGRect) -> String {
        guard let metrics = inspector.metrics(for: paneID) else {
            return "\(Int((rect.width * 100).rounded()))% × \(Int((rect.height * 100).rounded()))%"
        }
        let size = metrics.size(of: rect.size)
        return "\(Self.format(size.width)) × \(Self.format(size.height)) \(metrics.unit)"
    }

    private func loupePosition(for point: CGPoint, bounds: CGSize) -> CGPoint {
        let size: CGFloat = 112
        var x = point.x + size / 2 + 16
        var y = point.y - size / 2 - 16
        if x + size / 2 > bounds.width { x = point.x - size / 2 - 16 }
        if y - size / 2 < 0 { y = point.y + size / 2 + 16 }
        return CGPoint(x: x, y: y)
    }

    static func format(_ value: CGFloat) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.1f", Double(rounded))
    }
}

/// Outlines for hovered, selected, matched, and flagged elements.
private struct ElementHighlightCanvas: View {
    @ObservedObject var inspector: InspectorStore
    let paneID: UUID
    let frame: CGRect

    var body: some View {
        Canvas { context, _ in
            guard let snapshot = inspector.snapshot(for: paneID) else { return }

            if inspector.showsAllOutlines {
                for element in snapshot.elements {
                    let rect = InspectorOverlayGeometry.rect(element.frame, in: frame)
                    context.stroke(
                        Path(rect),
                        with: .color(element.isInteractive ? .cyan.opacity(0.7) : .white.opacity(0.35)),
                        lineWidth: 1
                    )
                }
            }

            if inspector.showsIssues, inspector.tab == .elements {
                let flagged = Set(inspector.issues(for: paneID).map(\.elementID))
                for element in snapshot.elements where flagged.contains(element.id) {
                    let rect = InspectorOverlayGeometry.rect(element.frame, in: frame)
                    context.stroke(
                        Path(roundedRect: rect, cornerRadius: 2),
                        with: .color(.red.opacity(0.85)),
                        style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])
                    )
                }
            }

            if inspector.tab == .elements, let match = inspector.matches[paneID] {
                let rect = InspectorOverlayGeometry.rect(match.element.frame, in: frame)
                context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(.green.opacity(0.16)))
                context.stroke(
                    Path(roundedRect: rect, cornerRadius: 3),
                    with: .color(.green),
                    style: StrokeStyle(lineWidth: 2.5, dash: [6, 3])
                )
            }

            if let selection = inspector.selection, selection.paneID == paneID,
               let element = snapshot.element(id: selection.elementID) {
                let rect = InspectorOverlayGeometry.rect(element.frame, in: frame)
                context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(.orange.opacity(0.14)))
                context.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(.orange), lineWidth: 2.5)

                if inspector.tab == .design,
                   let hovered = inspector.hovered, hovered.paneID == paneID,
                   hovered.elementID != selection.elementID,
                   let other = snapshot.element(id: hovered.elementID) {
                    drawSpacing(from: element.frame, to: other.frame, snapshot: snapshot, in: &context)
                }
            }

            if let hovered = inspector.hovered, hovered.paneID == paneID,
               let element = snapshot.element(id: hovered.elementID) {
                let rect = InspectorOverlayGeometry.rect(element.frame, in: frame)
                context.fill(Path(rect), with: .color(.accentColor.opacity(0.18)))
                context.stroke(Path(rect), with: .color(.accentColor), lineWidth: 1.5)
            }
        }
    }

    private func drawSpacing(
        from a: CGRect,
        to b: CGRect,
        snapshot: ElementSnapshot,
        in context: inout GraphicsContext
    ) {
        let spacing = ElementSpacing.between(a, b)
        let color = Color.pink
        if let gap = spacing.horizontal {
            let leftRect = a.maxX <= b.minX ? a : b
            let y = (max(a.minY, b.minY) + min(a.maxY, b.maxY)) / 2
            let startX = leftRect.maxX
            let line = CGRect(x: startX, y: y.isFinite ? y : a.midY, width: gap, height: 0)
            drawDimension(
                from: InspectorOverlayGeometry.point(CGPoint(x: line.minX, y: line.minY), in: frame),
                to: InspectorOverlayGeometry.point(CGPoint(x: line.maxX, y: line.minY), in: frame),
                label: "\(PaneInspectionOverlay.format(gap * snapshot.screenSize.width))",
                color: color,
                in: &context
            )
        }
        if let gap = spacing.vertical {
            let topRect = a.maxY <= b.minY ? a : b
            let x = (max(a.minX, b.minX) + min(a.maxX, b.maxX)) / 2
            let startY = topRect.maxY
            drawDimension(
                from: InspectorOverlayGeometry.point(CGPoint(x: x.isFinite ? x : a.midX, y: startY), in: frame),
                to: InspectorOverlayGeometry.point(CGPoint(x: x.isFinite ? x : a.midX, y: startY + gap), in: frame),
                label: "\(PaneInspectionOverlay.format(gap * snapshot.screenSize.height))",
                color: color,
                in: &context
            )
        }
    }

    private func drawDimension(
        from start: CGPoint,
        to end: CGPoint,
        label: String,
        color: Color,
        in context: inout GraphicsContext
    ) {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        context.stroke(path, with: .color(color), lineWidth: 1.5)
        let resolved = context.resolve(
            Text(label).font(.caption2.weight(.bold)).foregroundColor(.white)
        )
        let size = resolved.measure(in: CGSize(width: 200, height: 40))
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let badge = CGRect(
            x: mid.x - size.width / 2 - 4,
            y: mid.y - size.height / 2 - 2,
            width: size.width + 8,
            height: size.height + 4
        )
        context.fill(Path(roundedRect: badge, cornerRadius: 4), with: .color(color))
        context.draw(resolved, at: mid)
    }
}

private struct GridCanvas: View {
    let grid: GridSettings
    let metrics: PaneMetrics
    let frame: CGRect

    var body: some View {
        Canvas { context, _ in
            let spacing = metrics.normalizedSpacing(grid.spacing)
            var lines = Path()
            for x in InspectorOverlayGeometry.gridLines(
                spacing: spacing.width,
                length: frame.width,
                origin: frame.minX
            ) {
                lines.move(to: CGPoint(x: x, y: frame.minY))
                lines.addLine(to: CGPoint(x: x, y: frame.maxY))
            }
            for y in InspectorOverlayGeometry.gridLines(
                spacing: spacing.height,
                length: frame.height,
                origin: frame.minY
            ) {
                lines.move(to: CGPoint(x: frame.minX, y: y))
                lines.addLine(to: CGPoint(x: frame.maxX, y: y))
            }
            context.stroke(lines, with: .color(.cyan.opacity(0.28)), lineWidth: 0.5)

            for column in InspectorOverlayGeometry.columns(
                count: grid.columns,
                margin: grid.margin,
                gutter: grid.gutter,
                screenWidth: metrics.screenSize.width
            ) {
                let rect = CGRect(
                    x: frame.minX + column.lowerBound * frame.width,
                    y: frame.minY,
                    width: (column.upperBound - column.lowerBound) * frame.width,
                    height: frame.height
                )
                context.fill(Path(rect), with: .color(.pink.opacity(0.10)))
            }
        }
    }
}

private struct MeasurementCanvas: View {
    let rect: CGRect
    let label: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                context.fill(Path(rect), with: .color(.pink.opacity(0.14)))
                context.stroke(Path(rect), with: .color(.pink), lineWidth: 1.5)
            }
            Text(label)
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.pink, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .offset(x: rect.minX, y: rect.maxY + 4)
        }
    }
}

private struct ColorLoupe: View {
    let image: CGImage
    let sample: ColorSample?

    var body: some View {
        VStack(spacing: 4) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .frame(width: 96, height: 96)
                .overlay {
                    Rectangle()
                        .stroke(Color.white, lineWidth: 1.5)
                        .frame(width: 96 / CGFloat(max(image.width, 1)), height: 96 / CGFloat(max(image.height, 1)))
                        .shadow(color: .black.opacity(0.6), radius: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.white.opacity(0.8), lineWidth: 1)
                }
            if let sample {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(nsColor: sample.nsColor))
                        .frame(width: 10, height: 10)
                    Text(sample.hex)
                        .font(.caption2.monospaced().weight(.semibold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.75), in: Capsule())
                .foregroundStyle(.white)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 6)
    }
}

/// Design mock layer. Difference blending uses a Core Animation compositing
/// filter so it blends against the live stream drawn underneath.
struct DesignOverlayLayer: NSViewRepresentable {
    let overlay: DesignOverlay

    func makeNSView(context: Context) -> DesignOverlayNSView {
        let view = DesignOverlayNSView()
        view.apply(overlay)
        return view
    }

    func updateNSView(_ nsView: DesignOverlayNSView, context: Context) {
        nsView.apply(overlay)
    }
}

final class DesignOverlayNSView: NSView {
    private let imageLayer = CALayer()
    private let maskLayer = CALayer()
    private var split: Double = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        maskLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func apply(_ overlay: DesignOverlay) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = overlay.image
        switch overlay.mode {
        case .overlay:
            imageLayer.opacity = Float(overlay.opacity)
            imageLayer.compositingFilter = nil
            imageLayer.mask = nil
            split = 1
        case .difference:
            imageLayer.opacity = 1
            imageLayer.compositingFilter = "differenceBlendMode"
            imageLayer.mask = nil
            split = 1
        case .split:
            imageLayer.opacity = Float(max(overlay.opacity, 0.05))
            imageLayer.compositingFilter = nil
            imageLayer.mask = maskLayer
            split = overlay.split
        }
        CATransaction.commit()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        // AppKit layers are bottom-left; the mask grows from the left edge.
        maskLayer.frame = CGRect(x: 0, y: 0, width: bounds.width * split, height: bounds.height)
        CATransaction.commit()
    }
}
