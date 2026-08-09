import AppKit
import SwiftUI

struct BatchURLSnapshotSheet: View {
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var web: WebViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = """
        https://example.com
        https://example.com/about
        """
    @State private var alsoOpenOnDevices = false
    @State private var isRunning = false
    @State private var progress: BatchURLSnapshotProgress?
    @State private var statusMessage: String?
    @State private var runTask: Task<Void, Never>?
    @State private var outputFolder: URL?

    private let service = BatchURLSnapshotService()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 460, idealHeight: 500)
        .onDisappear {
            runTask?.cancel()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Batch URL snapshots")
                    .font(.title3.weight(.semibold))
                Text("Load each URL, wait for settle, then save a multi-pane screenshot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") {
                runTask?.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("URL list (one per line)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $urlText)
                .font(.body.monospaced())
                .frame(minHeight: 180)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.separator, lineWidth: 1)
                )
                .disabled(isRunning)

            Toggle(
                "Also open each URL on visible devices",
                isOn: $alsoOpenOnDevices
            )
            .disabled(isRunning)

            if let progress {
                ProgressView(
                    value: Double(progress.index),
                    total: Double(max(progress.total, 1))
                ) {
                    Text("\(progress.index) / \(progress.total)")
                } currentValueLabel: {
                    Text(progress.url)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack {
            if isRunning {
                Button("Cancel") {
                    runTask?.cancel()
                }
            }

            Spacer()

            Button(isRunning ? "Running…" : "Choose folder & run") {
                start()
            }
            .disabled(isRunning || service.parseURLList(urlText).isEmpty)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func start() {
        let urls = service.parseURLList(urlText)
        guard !urls.isEmpty else {
            statusMessage = BatchURLSnapshotError.noURLs.localizedDescription
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save snapshots here"
        panel.message = "Choose an output folder for \(urls.count) snapshot(s)."
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        outputFolder = folder
        isRunning = true
        statusMessage = nil
        progress = nil

        runTask = Task { @MainActor in
            do {
                let saved = try await service.run(
                    urls: urls,
                    web: web,
                    workspace: workspace,
                    includePlatformLabels: workspace.screenshotPlatformLabelsEnabled,
                    alsoOpenOnDevices: alsoOpenOnDevices,
                    outputDirectory: folder
                ) { update in
                    progress = update
                }
                statusMessage =
                    "Saved \(saved.count) snapshot(s) to \(folder.path)"
                NSWorkspace.shared.activateFileViewerSelecting(saved)
            } catch is CancellationError {
                statusMessage = "Cancelled"
            } catch {
                statusMessage = error.localizedDescription
            }
            isRunning = false
        }
    }
}
