import SwiftUI

struct OverlayDiffSheet: View {
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var web: WebViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var baseSource: ViewerSource = .android
    @State private var overlaySource: ViewerSource = .iOS
    @State private var opacity = 0.45
    @State private var cachedBase: CGImage?
    @State private var cachedOverlay: CGImage?
    @State private var preview: NSImage?
    @State private var errorMessage: String?
    @State private var isBusy = false
    @State private var savedURL: URL?

    private var captureIdentity: String {
        "\(baseSource.rawValue)|\(overlaySource.rawValue)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 520, idealHeight: 580)
        .onChange(of: baseSource) { _, newValue in
            if newValue == overlaySource {
                overlaySource = ViewerSource.allCases.first { $0 != newValue } ?? .iOS
            }
        }
        .onChange(of: overlaySource) { _, newValue in
            if newValue == baseSource {
                baseSource = ViewerSource.allCases.first { $0 != newValue } ?? .android
            }
        }
        .task(id: captureIdentity) {
            await capturePanes()
        }
        .task(id: Int((opacity * 100).rounded())) {
            // Debounce slider rebuilds to whole-percent steps.
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            await composePreview()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Onion-skin overlay")
                    .font(.title3.weight(.semibold))
                Text("Stack two panes and fade the top layer for layout comparison.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                sourcePicker("Base", selection: $baseSource)
                sourcePicker("Overlay", selection: $overlaySource)
            }

            if baseSource == overlaySource {
                Text("Base and overlay must be different panes.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Overlay opacity \(Int((opacity * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $opacity, in: 0...1)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.85))
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else if isBusy {
                    ProgressView()
                } else {
                    Text(errorMessage ?? "No preview yet")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let savedURL {
                Text("Saved \(savedURL.lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Button("Refresh") {
                Task { await capturePanes() }
            }
            .disabled(isBusy)

            Spacer()

            Button("Save PNG…") {
                Task { await savePreview() }
            }
            .disabled(preview == nil || isBusy || baseSource == overlaySource)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func sourcePicker(
        _ title: String,
        selection: Binding<ViewerSource>
    ) -> some View {
        Picker(title, selection: selection) {
            ForEach(ViewerSource.allCases) { source in
                Text(source.title).tag(source)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: .infinity)
    }

    @MainActor
    private func capturePanes() async {
        guard baseSource != overlaySource else {
            errorMessage = "Base and overlay must be different panes."
            preview = nil
            return
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let service = WorkspaceScreenshotService()
            let base = try await service.capturePane(
                source: baseSource,
                web: web,
                workspace: workspace
            )
            try Task.checkCancellation()
            let overlay = try await service.capturePane(
                source: overlaySource,
                web: web,
                workspace: workspace
            )
            try Task.checkCancellation()
            cachedBase = base
            cachedOverlay = overlay
            await composePreview()
        } catch is CancellationError {
            return
        } catch {
            cachedBase = nil
            cachedOverlay = nil
            preview = nil
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func composePreview() async {
        guard let cachedBase, let cachedOverlay else { return }
        do {
            let composed = try OverlayDiffComposer.compose(
                base: cachedBase,
                overlay: cachedOverlay,
                opacity: opacity
            )
            try Task.checkCancellation()
            preview = NSImage(
                cgImage: composed,
                size: NSSize(width: composed.width, height: composed.height)
            )
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            preview = nil
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func savePreview() async {
        guard let preview,
              let cgImage = preview.cgImage(
                  forProposedRect: nil,
                  context: nil,
                  hints: nil
              ) else { return }
        do {
            let url = try WorkspaceScreenshotService().save(
                cgImage,
                preferredName: WorkspaceScreenshotNaming.filename(
                    fileExtension: "png"
                ).replacingOccurrences(
                    of: "Viewport",
                    with: "Viewport-Overlay"
                ),
                panelTitle: "Save Onion-skin Overlay"
            )
            savedURL = url
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
