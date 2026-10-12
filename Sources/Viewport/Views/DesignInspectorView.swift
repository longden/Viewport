import SwiftUI
import UniformTypeIdentifiers

/// Grids, design mock overlays, measuring, and colour picking.
struct DesignInspectorView: View {
    @ObservedObject var inspector: InspectorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            InspectorSection("Tool") {
                Picker("Tool", selection: $inspector.designTool) {
                    ForEach(DesignTool.allCases) { tool in
                        Label(tool.title, systemImage: tool.systemImage).tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(toolHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if inspector.designTool == .measure, let measurement = inspector.measurement,
               let metrics = inspector.metrics(for: measurement.paneID) {
                let size = metrics.size(of: measurement.rect.size)
                InspectorPropertyRow(
                    title: "Measured",
                    value: "\(PaneInspectionOverlay.format(size.width)) × \(PaneInspectionOverlay.format(size.height)) \(metrics.unit)",
                    copyable: true
                )
            }

            if inspector.designTool == .colorPicker {
                colors
            }

            gridSection
            overlaysSection
        }
    }

    private var toolHint: String {
        switch inspector.designTool {
        case .interact:
            "Panes stay interactive. Grids and mockups draw on top."
        case .measure:
            "Drag in a pane to measure. Click an element, then hover another to see the gap between them."
        case .colorPicker:
            "Hover to magnify; click to copy the hex value."
        }
    }

    private var colors: some View {
        InspectorSection("Colours") {
            if inspector.pickedColors.isEmpty {
                Text("Picked colours appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(inspector.pickedColors) { sample in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(nsColor: sample.nsColor))
                                .frame(width: 22, height: 22)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(sample.hex)
                                    .font(.caption.monospaced().weight(.semibold))
                                Text("\(sample.rgbText) · \(sample.source.title)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(sample.hex, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc").font(.caption2)
                            }
                            .buttonStyle(PaneToolbarButtonStyle())
                            .help("Copy \(sample.hex)")
                        }
                    }
                    Button("Clear") {
                        inspector.clearPickedColors()
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
            }
        }
    }

    private var gridSection: some View {
        InspectorSection("Grid") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Show grid on every pane", isOn: $inspector.grid.isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Group {
                    Stepper(
                        "Baseline: \(Int(inspector.grid.spacing)) pt",
                        value: $inspector.grid.spacing,
                        in: 2...64,
                        step: 2
                    )
                    Stepper(
                        inspector.grid.columns == 0 ? "Columns: off" : "Columns: \(inspector.grid.columns)",
                        value: $inspector.grid.columns,
                        in: 0...12
                    )
                    if inspector.grid.columns > 0 {
                        Stepper(
                            "Margin: \(Int(inspector.grid.margin)) pt",
                            value: $inspector.grid.margin,
                            in: 0...64,
                            step: 4
                        )
                        Stepper(
                            "Gutter: \(Int(inspector.grid.gutter)) pt",
                            value: $inspector.grid.gutter,
                            in: 0...48,
                            step: 4
                        )
                    }
                }
                .font(.caption)
                .controlSize(.small)
                .disabled(!inspector.grid.isEnabled)
                Text("Units follow each platform: pt on iOS, dp on Android, CSS px on web.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var overlaysSection: some View {
        InspectorSection("Design mockups") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Lay a PNG or JPEG export from Figma or Sketch over a pane to check spacing and colours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(inspector.panes) { pane in
                    DesignOverlayRow(inspector: inspector, pane: pane)
                }
                if let error = inspector.overlayError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

private struct DesignOverlayRow: View {
    @ObservedObject var inspector: InspectorStore
    let pane: InspectorPane
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: pane.source.systemImage)
                    .foregroundStyle(pane.source.accentColor)
                    .frame(width: 16)
                Text(pane.title)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                if let overlay {
                    Toggle("Visible", isOn: Binding(
                        get: { overlay.isVisible },
                        set: { value in inspector.updateOverlay(for: pane.id) { $0.isVisible = value } }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help("Show or hide the mockup")
                    Button {
                        inspector.removeOverlay(for: pane.id)
                    } label: {
                        Image(systemName: "trash").font(.caption)
                    }
                    .buttonStyle(PaneToolbarButtonStyle())
                    .help("Remove the mockup")
                }
                Button(overlay == nil ? "Choose…" : "Replace…") {
                    chooseImage()
                }
                .controlSize(.small)
            }

            if let overlay {
                Text(overlay.url.lastPathComponent + " · \(overlay.image.width)×\(overlay.image.height)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let size = inspector.metrics(for: pane.id)?.screenSize,
                   !overlay.matchesAspect(of: size) {
                    Label("The mockup’s aspect ratio differs from this pane; it’s stretched to fit.", systemImage: "aspectratio")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Picker("Mode", selection: Binding(
                    get: { overlay.mode },
                    set: { value in inspector.updateOverlay(for: pane.id) { $0.mode = value } }
                )) {
                    ForEach(DesignOverlayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                if overlay.mode != .difference {
                    LabeledSlider(
                        title: "Opacity",
                        value: Binding(
                            get: { overlay.opacity },
                            set: { value in inspector.updateOverlay(for: pane.id) { $0.opacity = value } }
                        )
                    )
                }
                if overlay.mode == .split {
                    LabeledSlider(
                        title: "Split",
                        value: Binding(
                            get: { overlay.split },
                            set: { value in inspector.updateOverlay(for: pane.id) { $0.split = value } }
                        )
                    )
                }
            }
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04))
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: Self.isImage) else { return false }
            inspector.setOverlay(from: url, for: pane.id)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .help("Drop an image here")
    }

    private var overlay: DesignOverlay? {
        inspector.overlays[pane.id]
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a design export for the \(pane.title) pane"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        inspector.setOverlay(from: url, for: pane.id)
    }

    private static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Slider(value: $value, in: 0...1)
                .controlSize(.small)
            Text("\(Int((value * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .frame(width: 36, alignment: .trailing)
        }
    }
}
