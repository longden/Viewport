import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Pick native projects, build once, and launch on every visible device pane.
struct BuildPlaySheet: View {
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var developerLogs: DeveloperLogStore
    @Binding var showDeveloperLogs: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var settings = ProjectBuildPlaySettings()
    @State private var schemes: [String] = []
    @State private var isLoadingSchemes = false
    @State private var isRunning = false
    @State private var statusMessage: String?
    @State private var lastError: String?
    @State private var runTask: Task<Void, Never>?
    @State private var schemesTask: Task<Void, Never>?

    private let service = ProjectBuildPlayService()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                iosSection
                androidSection
                targetsSection
            }
            .formStyle(.grouped)
            .padding(.horizontal, 8)
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 560, minHeight: 460, idealHeight: 500)
        .task {
            settings = await service.loadSettings()
            await refreshSchemes()
        }
        .onChange(of: settings.iosProjectPath) {
            schemesTask?.cancel()
            schemesTask = Task { await refreshSchemes() }
        }
        .onDisappear {
            schemesTask?.cancel()
            runTask?.cancel()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Build & Play")
                    .font(.title3.weight(.semibold))
                Text(
                    "Build once, then install and launch on every visible simulator or emulator."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private var iosSection: some View {
        Section("iOS (Xcode project or workspace)") {
            HStack {
                TextField(
                    "Path",
                    text: Binding(
                        get: { settings.iosProjectPath ?? "" },
                        set: { settings.iosProjectPath = $0.isEmpty ? nil : $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())

                Button("Choose…") {
                    chooseIOSProject()
                }
            }

            if isLoadingSchemes {
                ProgressView("Loading schemes…")
                    .controlSize(.small)
            } else if !schemes.isEmpty {
                Picker(
                    "Scheme",
                    selection: Binding(
                        get: { settings.iosScheme ?? "" },
                        set: { settings.iosScheme = $0.isEmpty ? nil : $0 }
                    )
                ) {
                    Text("Select a scheme").tag("")
                    ForEach(schemes, id: \.self) { scheme in
                        Text(scheme).tag(scheme)
                    }
                }
            } else if settings.iosProjectPath != nil {
                Text("No schemes found — pick a valid .xcodeproj or .xcworkspace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var androidSection: some View {
        Section("Android (Gradle project directory)") {
            HStack {
                TextField(
                    "Path",
                    text: Binding(
                        get: { settings.androidProjectPath ?? "" },
                        set: { settings.androidProjectPath = $0.isEmpty ? nil : $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())

                Button("Choose…") {
                    chooseAndroidProject()
                }
            }
            Text("Uses `./gradlew assembleDebug`, then installs the debug APK on each visible Android pane.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var targetsSection: some View {
        Section("Visible targets") {
            if workspace.isVisible(.iOS), workspace.iOSCapture.selectedDevice != nil {
                Label(
                    workspace.iOSCapture.selectedDevice?.displayName ?? "iOS",
                    systemImage: "iphone"
                )
            } else if workspace.isVisible(.iOS) {
                Text("Show iOS and select a Simulator.")
                    .foregroundStyle(.secondary)
            }

            if workspace.isVisible(.android),
               workspace.androidCapture.selectedDevice != nil {
                Label(
                    workspace.androidCapture.selectedDevice?.displayName ?? "Android",
                    systemImage: "apps.iphone"
                )
            } else if workspace.isVisible(.android) {
                Text("Show Android and select a device or emulator.")
                    .foregroundStyle(.secondary)
            }

            if !workspace.isVisible(.iOS) && !workspace.isVisible(.android) {
                Text("Show Android and/or iOS to deploy builds.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let lastError {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(isRunning)

            Button(isRunning ? "Building…" : "Build & Play") {
                startBuild()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isRunning || !canBuild)
        }
        .padding(16)
    }

    private var canBuild: Bool {
        let hasIOSTarget = workspace.isVisible(.iOS)
            && workspace.iOSCapture.selectedDevice != nil
        let hasAndroidTarget = workspace.isVisible(.android)
            && workspace.androidCapture.selectedDevice != nil
        let iosReady = !hasIOSTarget || (
            settings.iosProjectPath != nil
                && settings.iosScheme != nil
                && !settings.iosScheme!.isEmpty
        )
        let androidReady = !hasAndroidTarget || settings.androidProjectPath != nil
        return (hasIOSTarget || hasAndroidTarget) && iosReady && androidReady
    }

    private func chooseIOSProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "xcodeproj")!,
            UTType(filenameExtension: "xcworkspace")!
        ]
        panel.message = "Choose an Xcode project or workspace."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.iosProjectPath = url.path
        settings.iosScheme = nil
    }

    private func chooseAndroidProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.message = "Choose the Android Gradle project root (contains gradlew)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.androidProjectPath = url.path
    }

    private func refreshSchemes() async {
        guard let path = settings.iosProjectPath,
              ProjectBuildPlayService.isXcodeProject(URL(fileURLWithPath: path)) else {
            schemes = []
            return
        }
        isLoadingSchemes = true
        defer { isLoadingSchemes = false }
        do {
            let discovered = try await service.discoverSchemes(projectPath: path)
            guard !Task.isCancelled else { return }
            schemes = discovered
            if let current = settings.iosScheme,
               !schemes.contains(current) {
                settings.iosScheme = schemes.first
            } else if settings.iosScheme == nil {
                settings.iosScheme = schemes.first
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            schemes = []
            lastError = error.localizedDescription
        }
    }

    private func startBuild() {
        lastError = nil
        statusMessage = nil
        isRunning = true
        showDeveloperLogs = true
        developerLogs.setEnabled(true)
        developerLogs.setBuildStatus(.streaming)
        developerLogs.clear(.build)

        runTask = Task { @MainActor in
            await service.saveSettings(settings)
            do {
                try await service.buildAndPlay(
                    workspace: workspace,
                    settings: settings,
                    onLog: { output, line in
                        Task { @MainActor in
                            developerLogs.appendBuild(
                                level: output == .standardError ? .error : .info,
                                message: line
                            )
                        }
                    },
                    onStatus: { message in
                        Task { @MainActor in
                            statusMessage = message
                        }
                    }
                )
                developerLogs.setBuildStatus(.idle)
            } catch is CancellationError {
                statusMessage = "Cancelled"
                developerLogs.setBuildStatus(.idle)
            } catch {
                lastError = error.localizedDescription
                statusMessage = nil
                developerLogs.appendBuild(level: .error, message: error.localizedDescription)
                developerLogs.setBuildStatus(.failed(error.localizedDescription))
            }
            isRunning = false
        }
    }
}
