import SwiftUI

/// Navigation utility chrome: settings menu, device tools, help.
struct WorkspaceUtilityToolbar: View {
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var recording: WorkspaceRecordingService
    @Binding var showDeveloperLogs: Bool
    @Binding var showSettings: Bool
    @Binding var showHelp: Bool
    @Binding var showBatchSnapshots: Bool
    @Binding var showBuildPlay: Bool
    var isExportingBugReport: Bool
    var isTakingScreenshot: Bool
    var onExportBugReport: () -> Void

    var body: some View {
        Menu {
            Picker(
                "Capture mode",
                selection: Binding(
                    get: { workspace.captureMode },
                    set: { workspace.setCaptureMode($0) }
                )
            ) {
                ForEach(CaptureMode.allCases) { mode in
                    Label {
                        VStack(alignment: .leading) {
                            Text(mode.title)
                            Text(mode.detail)
                        }
                    } icon: {
                        Image(systemName: mode.systemImage)
                    }
                    .tag(mode)
                }
            }
            .disabled(recording.isRecording)

            Divider()

            Picker(
                "Streaming performance",
                selection: Binding(
                    get: { workspace.performanceProfile },
                    set: { workspace.setPerformanceProfile($0) }
                )
            ) {
                ForEach(CapturePerformanceProfile.allCases) { profile in
                    Label {
                        VStack(alignment: .leading) {
                            Text(profile.title)
                            Text(profile.detail)
                        }
                    } icon: {
                        Image(systemName: profile.systemImage)
                    }
                    .tag(profile)
                }
            }

            Divider()

            Picker(
                "Recording quality",
                selection: Binding(
                    get: { workspace.recordingQuality },
                    set: { workspace.setRecordingQuality($0) }
                )
            ) {
                ForEach(RecordingQuality.allCases) { quality in
                    Label {
                        VStack(alignment: .leading) {
                            Text(quality.title)
                            Text(quality.detail)
                        }
                    } icon: {
                        Image(systemName: quality.systemImage)
                    }
                    .tag(quality)
                }
            }
            .disabled(recording.isRecording)

            if workspace.captureMode == .classic {
                Divider()

                if workspace.highFrameRateCaptureAvailable {
                    Label(
                        "Fast window capture enabled",
                        systemImage: "checkmark.circle"
                    )
                } else {
                    Button {
                        workspace.requestHighFrameRateCapture()
                    } label: {
                        Label(
                            "Enable fast Simulator capture…",
                            systemImage: "rectangle.inset.filled.and.person.filled"
                        )
                    }
                    .help(
                        "If Screen Recording already lists Viewport, toggle it off and on after a rebuild, then return here."
                    )
                }
            }

            Divider()

            Picker(
                "Devlogs",
                selection: $showDeveloperLogs
            ) {
                Text("On").tag(true)
                Text("Off").tag(false)
            }

            Divider()

            Button {
                workspace.resetPaneWindows()
            } label: {
                Label("Reset Windows", systemImage: "rectangle.split.3x1")
            }
            .help(
                "Size Android/iOS panes to the live phone aspect and give leftover width to web."
            )

            Divider()

            Button(action: onExportBugReport) {
                Label(
                    isExportingBugReport
                        ? "Preparing bug report…"
                        : "Report a bug…",
                    systemImage: "ladybug"
                )
            }
            .disabled(
                isExportingBugReport
                    || isTakingScreenshot
                    || recording.isRecording
            )

            Button {
                showSettings = true
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
        } label: {
            Label("Settings", systemImage: "gearshape")
        }
        .help("Viewport settings")

        DeviceToolsMenu(
            workspace: workspace,
            showBatchSnapshots: $showBatchSnapshots,
            showBuildPlay: $showBuildPlay
        )

        Button {
            showHelp = true
        } label: {
            Label("Help", systemImage: "questionmark.circle")
        }
        .help("Setup checks, install guides, and create an emulator")
    }
}

/// Principal action chrome: refresh, combined screenshot, record.
struct WorkspaceActionToolbar: View {
    @ObservedObject var recording: WorkspaceRecordingService
    @ObservedObject var elapsedClock: RecordingElapsedClock
    var isTakingScreenshot: Bool
    var onRefresh: () -> Void
    var onCombinedScreenshot: () -> Void
    var onToggleRecording: () -> Void

    private var recordingHelp: String {
        if recording.isRecording {
            let seconds = Int(elapsedClock.elapsed.rounded())
            let minutes = seconds / 60
            let remainder = seconds % 60
            return String(
                format: "Recording… %d:%02d — click to stop",
                minutes,
                remainder
            )
        }
        return "Record all visible clients"
    }

    var body: some View {
        ControlGroup {
            Button(action: onRefresh) {
                Label(
                    "Refresh all clients",
                    systemImage: "arrow.clockwise"
                )
                .labelStyle(.iconOnly)
                .frame(minWidth: 24, minHeight: 24)
                .contentShape(Rectangle())
            }
            .help("Refresh all clients (⇧⌘R)")

            Button(action: onCombinedScreenshot) {
                Group {
                    if isTakingScreenshot {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(
                            "Combined screenshot",
                            systemImage: "camera.viewfinder"
                        )
                    }
                }
                .labelStyle(.iconOnly)
                .frame(minWidth: 24, minHeight: 24)
                .contentShape(Rectangle())
            }
            .disabled(isTakingScreenshot || recording.isRecording)
            .help("Save all visible clients in one row")

            Button(action: onToggleRecording) {
                Label(
                    recording.isRecording ? "Stop recording" : "Record",
                    systemImage: recording.isRecording
                        ? "stop.circle.fill"
                        : "record.circle"
                )
                .labelStyle(.iconOnly)
                .frame(minWidth: 24, minHeight: 24)
                .contentShape(Rectangle())
                .foregroundStyle(recording.isRecording ? .red : .primary)
            }
            .help(recordingHelp)
        }
        .controlSize(.regular)
        .fixedSize()
    }
}
