import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var workspace = WorkspaceStore()
    @StateObject private var web: WebViewModel
    /// Held without `@StateObject` so streaming log updates don't rebuild the
    /// toolbar menu (which dismissed the Logs item on hover).
    @State private var developerLogs: DeveloperLogStore
    @StateObject private var favorites = FavoritesStore()
    @StateObject private var recording = WorkspaceRecordingService()
    @State private var pointerBridge = PointerEventBridge()
    @State private var isTakingScreenshot = false
    @State private var isExportingBugReport = false
    @State private var exportError: String?
    @State private var exportErrorTitle = "Export Failed"
    @State private var savedExportURL: URL?
    @State private var showHelp = false
    @State private var showSettings = false
    @State private var showBatchSnapshots = false
    @State private var showBuildPlay = false
    @State private var annotationItem: AnnotatableScreenshot?
    @AppStorage("developerLogsVisible") private var showDeveloperLogs = false
    @AppStorage("appAppearance") private var appearanceRaw = AppAppearance.system.rawValue
    @State private var dismissExportTask: Task<Void, Never>?

    private var preferredAppearance: ColorScheme? {
        (AppAppearance(rawValue: appearanceRaw) ?? .system).colorScheme
    }

    init() {
        let developerLogs = DeveloperLogStore()
        _developerLogs = State(wrappedValue: developerLogs)
        _web = StateObject(
            wrappedValue: WebViewModel {
                [weak developerLogs] level, message, timestamp in
                developerLogs?.appendWeb(
                    level: level,
                    message: message,
                    timestamp: timestamp
                )
            }
        )
    }

    var body: some View {
        workspaceChrome
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification
                )
            ) { _ in
                workspace.refreshHighFrameRateCaptureAvailability()
            }
            .onChange(of: workspace.androidDevices.lastLaunchToken) {
                workspace.reconnectAfterDeviceLaunch()
            }
            .onChange(of: workspace.iOSDevices.lastLaunchToken) {
                workspace.reconnectAfterDeviceLaunch()
            }
            .onChange(of: workspace.androidDevices.lastLaunchFailureToken) {
                workspace.clearPendingLaunch(
                    for: .android,
                    deviceID: workspace.androidDevices.lastLaunchFailureDeviceID
                )
            }
            .onChange(of: workspace.iOSDevices.lastLaunchFailureToken) {
                workspace.clearPendingLaunch(
                    for: .iOS,
                    deviceID: workspace.iOSDevices.lastLaunchFailureDeviceID
                )
            }
            .modifier(LogStreamSyncTriggers(
                workspace: workspace,
                showDeveloperLogs: showDeveloperLogs,
                sync: syncLogStreams
            ))
            .onChange(of: workspace.captureMode) {
                finalizeRecordingIfNeeded()
            }
            .onChange(of: recording.lastSavedURL) { _, url in
                if let url {
                    presentExportToast(url)
                }
            }
    }

    private var workspaceChrome: some View {
        ZStack(alignment: .top) {
            workspaceLayout
                .padding(12)

            if let savedExportURL {
                ScreenshotSavedToast(url: savedExportURL) {
                    clearExportToast()
                }
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .animation(.snappy(duration: 0.22), value: savedExportURL)
        // One continuous window surface — no opaque fill under the panes,
        // and no separate toolbar plate (avoids the color/shadow seam).
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                workspaceUtilityToolbar
            }

            ToolbarItemGroup(placement: .principal) {
                workspaceActionToolbar
            }

            ToolbarItem(placement: .primaryAction) {
                SourceVisibilityControls(workspace: workspace)
            }
        }
        .sheet(isPresented: $showHelp) {
            HelpSheet(androidDevices: workspace.androidDevices)
        }
        .preferredColorScheme(preferredAppearance)
        .sheet(isPresented: $showSettings) {
            SettingsSheet(workspace: workspace)
        }
        .onChange(of: workspace.experimentalFeaturesEnabled) { _, isEnabled in
            guard !isEnabled else { return }
            showBatchSnapshots = false
            workspace.setSynchronizedScrollingEnabled(false)
        }
        .sheet(isPresented: $showBatchSnapshots) {
            BatchURLSnapshotSheet(workspace: workspace, web: web)
        }
        .sheet(isPresented: $showBuildPlay) {
            BuildPlaySheet(
                workspace: workspace,
                developerLogs: developerLogs,
                showDeveloperLogs: $showDeveloperLogs
            )
        }
        .sheet(item: $annotationItem) { item in
            ScreenshotAnnotationSheet(
                panes: item.panes,
                labelsEnabledByDefault: item.labelsEnabledByDefault
            ) { url in
                presentExportToast(url)
            }
        }
        .alert(
            exportErrorTitle,
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                exportError = nil
            }
        } message: {
            Text(exportError ?? "The export could not be saved.")
        }
        .focusedSceneValue(
            \.workspaceCommandActions,
            WorkspaceCommandActions(
                refreshAll: refreshAll,
                clearCookies: web.clearCookies,
                clearAllWebsiteData: web.clearAllWebsiteData
            )
        )
        .task {
            workspace.refreshAll()
            syncLogStreams()
            installPointerEventSinks()
        }
        .onDisappear {
            dismissExportTask?.cancel()
            developerLogs.stopAll()
            let shouldFinalize = recording.isRecording
            Task { @MainActor in
                if shouldFinalize {
                    _ = try? await recording.stop()
                }
                workspace.stopCaptures()
            }
        }
    }

    private var recordingHelp: String {
        if recording.isRecording {
            let seconds = Int(recording.elapsed.rounded())
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

    @ViewBuilder
    private var workspaceUtilityToolbar: some View {
        WorkspaceUtilityToolbar(
            workspace: workspace,
            recording: recording,
            showDeveloperLogs: $showDeveloperLogs,
            showSettings: $showSettings,
            showHelp: $showHelp,
            showBatchSnapshots: $showBatchSnapshots,
            showBuildPlay: $showBuildPlay,
            isExportingBugReport: isExportingBugReport,
            isTakingScreenshot: isTakingScreenshot,
            onExportBugReport: exportBugReport
        )
    }

    private var workspaceActionToolbar: some View {
        WorkspaceActionToolbar(
            recording: recording,
            isTakingScreenshot: isTakingScreenshot,
            recordingHelp: recordingHelp,
            onRefresh: refreshAll,
            onCombinedScreenshot: takeCombinedScreenshot,
            onToggleRecording: toggleRecording
        )
    }

    @ViewBuilder
    private var workspaceLayout: some View {
        if showDeveloperLogs {
            ResizableDeveloperConsoleLayout {
                workspaceView
            } console: {
                DeveloperLogPanel(store: developerLogs)
            }
        } else {
            workspaceView
        }
    }

    private var workspaceView: some View {
        WorkspaceSplitView(
            workspace: workspace,
            web: web,
            favorites: favorites,
            onPaneScreenshot: takePaneScreenshot,
            onWebCaptureTargetChange: { target in
                recording.updateWebCaptureTarget(target)
            },
            squareWebContentCorners: recording.squareWebContentCorners
        )
        .background {
            WorkspaceRecordingAnchor { target in
                recording.updateCaptureTarget(target)
            }
        }
    }

    private func refreshAll() {
        web.reload()
        workspace.refreshAll()
        syncLogStreams()
    }

    private func syncLogStreams() {
        developerLogs.setEnabled(showDeveloperLogs)
        web.setConsoleCaptureEnabled(showDeveloperLogs)

        let activeAndroidSession = workspace.focusedCaptureSession(for: .android) ?? workspace.androidCapture
        let activeIOSSession = workspace.focusedCaptureSession(for: .iOS) ?? workspace.iOSCapture

        developerLogs.updateAndroidDevice(
            id: activeAndroidSession.selectedDeviceID,
            isVisible: showDeveloperLogs && workspace.isVisible(.android)
        )
        developerLogs.updateIOSDevice(
            activeIOSSession.selectedDevice,
            isVisible: showDeveloperLogs && workspace.isVisible(.iOS)
        )
    }

    private func takeCombinedScreenshot() {
        guard !isTakingScreenshot else { return }
        isTakingScreenshot = true
        exportError = nil

        Task { @MainActor in
            do {
                let service = WorkspaceScreenshotService()
                let panes = await service.collectPanes(
                    nodes: workspace.orderedVisiblePanes,
                    web: web,
                    workspace: workspace,
                    includeDeviceBezels: workspace.deviceBezelsEnabled
                )
                guard !panes.isEmpty else {
                    throw WorkspaceScreenshotError.noCapturablePanes
                }
                annotationItem = AnnotatableScreenshot(
                    panes: panes,
                    labelsEnabledByDefault: workspace.screenshotPlatformLabelsEnabled
                )
            } catch {
                presentExportError(
                    title: "Screenshot Failed",
                    message: error.localizedDescription
                )
            }
            isTakingScreenshot = false
        }
    }

    private func exportBugReport() {
        guard !isExportingBugReport else { return }
        isExportingBugReport = true
        exportError = nil
        Task { @MainActor in
            do {
                if let url = try await BugReportService().export(
                    web: web,
                    workspace: workspace,
                    logs: developerLogs,
                    includePlatformLabels: workspace.screenshotPlatformLabelsEnabled
                ) {
                    presentExportToast(url)
                }
            } catch {
                presentExportError(
                    title: "Bug Report Failed",
                    message: error.localizedDescription
                )
            }
            isExportingBugReport = false
        }
    }

    private func installPointerEventSinks() {
        pointerBridge.workspace = workspace
        pointerBridge.web = web
        for session in workspace.allCaptureSessions {
            let source = session.source
            // Single fan-out sink avoids nested wrappers when reinstalling.
            session.pointerEventSink = { [weak pointerBridge] phase, point, duration in
                pointerBridge?.handle(
                    source: source,
                    phase: phase,
                    point: point,
                    duration: duration
                )
            }
        }
    }

    private func takePaneScreenshot(_ source: ViewerSource, session: WindowCaptureSession? = nil) {
        guard !isTakingScreenshot else { return }
        isTakingScreenshot = true
        exportError = nil

        Task { @MainActor in
            do {
                let service = WorkspaceScreenshotService()
                let image = try await service.capturePane(
                    source: source,
                    session: session,
                    web: web,
                    workspace: workspace
                )
                if let url = try service.savePane(image, source: source) {
                    presentExportToast(url)
                }
            } catch {
                presentExportError(
                    title: "Screenshot Failed",
                    message: error.localizedDescription
                )
            }
            isTakingScreenshot = false
        }
    }

    private func toggleRecording() {
        if recording.isRecording {
            finalizeRecordingIfNeeded()
            return
        }

        exportError = nil
        Task { @MainActor in
            do {
                try await recording.start(web: web, workspace: workspace)
            } catch let error as WorkspaceRecordingError where error == .permissionRequired {
                ScreenRecordingPermission.openSystemSettings()
                presentExportError(
                    title: "Recording Failed",
                    message: error.localizedDescription
                )
            } catch {
                presentExportError(
                    title: "Recording Failed",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func finalizeRecordingIfNeeded() {
        guard recording.isRecording else { return }
        Task { @MainActor in
            do {
                _ = try await recording.stop()
                // Toast is presented via onChange(of: lastSavedURL).
            } catch {
                presentExportError(
                    title: "Recording Failed",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func presentExportError(title: String, message: String) {
        exportErrorTitle = title
        exportError = message
    }

    private func presentExportToast(_ url: URL) {
        dismissExportTask?.cancel()
        savedExportURL = url
        dismissExportTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            clearExportToast()
        }
    }

    private func clearExportToast() {
        dismissExportTask?.cancel()
        dismissExportTask = nil
        savedExportURL = nil
    }
}

private struct AnnotatableScreenshot: Identifiable {
    let id = UUID()
    let panes: [ScreenshotPaneCapture]
    let labelsEnabledByDefault: Bool
}

private struct ResizableDeveloperConsoleLayout<
    WorkspaceContent: View,
    ConsoleContent: View
>: View {
    private let workspace: WorkspaceContent
    private let console: ConsoleContent
    @AppStorage("developerLogPanelHeight") private var storedHeight = 240.0
    @State private var dragStartHeight: CGFloat?
    @State private var transientHeight: CGFloat?

    private let minimumWorkspaceHeight: CGFloat = 320
    private let minimumConsoleHeight: CGFloat = 160
    private let handleHeight: CGFloat = 10

    init(
        @ViewBuilder workspace: () -> WorkspaceContent,
        @ViewBuilder console: () -> ConsoleContent
    ) {
        self.workspace = workspace()
        self.console = console()
    }

    var body: some View {
        GeometryReader { proxy in
            let maximumConsoleHeight = max(
                proxy.size.height - minimumWorkspaceHeight - handleHeight,
                minimumConsoleHeight
            )
            let consoleHeight = min(
                max(
                    transientHeight ?? CGFloat(storedHeight),
                    minimumConsoleHeight
                ),
                maximumConsoleHeight
            )

            VStack(spacing: 0) {
                workspace
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(
                        height: max(
                            proxy.size.height - consoleHeight - handleHeight,
                            0
                        )
                    )

                DeveloperConsoleResizeHandle()
                    .frame(height: handleHeight)
                    .gesture(
                        resizeGesture(
                            currentHeight: consoleHeight,
                            maximumHeight: maximumConsoleHeight
                        )
                    )

                console
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(height: consoleHeight)
            }
        }
    }

    private func resizeGesture(
        currentHeight: CGFloat,
        maximumHeight: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStartHeight ?? currentHeight
                if dragStartHeight == nil {
                    dragStartHeight = start
                }
                let updated = min(
                    max(
                        start - value.translation.height,
                        minimumConsoleHeight
                    ),
                    maximumHeight
                )
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    transientHeight = updated
                }
            }
            .onEnded { _ in
                storedHeight = Double(transientHeight ?? currentHeight)
                dragStartHeight = nil
                transientHeight = nil
            }
    }
}

private struct LogStreamSyncTriggers: ViewModifier {
    @ObservedObject var workspace: WorkspaceStore
    var showDeveloperLogs: Bool
    var sync: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: workspace.androidCapture.selectedDeviceID) { _, _ in
                sync()
            }
            .onChange(of: workspace.androidCaptureSecondary.selectedDeviceID) { _, _ in
                sync()
            }
            .onChange(of: workspace.iOSCapture.selectedDeviceID) { _, _ in
                sync()
            }
            .onChange(of: workspace.iOSCaptureSecondary.selectedDeviceID) { _, _ in
                sync()
            }
            .onChange(of: workspace.focusedCapturePaneID) { _, _ in
                sync()
            }
            .onChange(of: workspace.visibleSources) { _, _ in
                sync()
            }
            .onChange(of: showDeveloperLogs) { _, _ in
                sync()
            }
    }
}

private struct DeveloperConsoleResizeHandle: View {
    @State private var isHovered = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .overlay {
                Capsule()
                    .fill(.primary.opacity(isHovered ? 0.20 : 0.08))
                    .frame(width: 42, height: isHovered ? 2 : 1)
            }
            .onHover { isHovered = $0 }
            .help("Drag to resize device logs")
    }
}
