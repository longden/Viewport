import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var workspace = WorkspaceStore()
    @StateObject private var web = WebViewModel()
    @StateObject private var favorites = FavoritesStore()
    @State private var isTakingScreenshot = false
    @State private var screenshotError: String?
    @State private var screenshotSavedURL: URL?
    @State private var showHelp = false
    @State private var showScreenshotSettings = false
    @State private var dismissScreenshotTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .top) {
            workspaceBackground

            WorkspaceSplitView(
                workspace: workspace,
                web: web,
                favorites: favorites
            )
            .padding(16)

            if let screenshotSavedURL {
                ScreenshotSavedToast(url: screenshotSavedURL) {
                    clearScreenshotToast()
                }
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .animation(.snappy(duration: 0.22), value: screenshotSavedURL)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
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

                    Button("Screenshot settings…") {
                        showScreenshotSettings = true
                    }
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Viewport settings")

                Button {
                    showHelp = true
                } label: {
                    Label("Help", systemImage: "questionmark.circle")
                }
                .help("Check Android setup and create an emulator")
            }

            ToolbarItemGroup(placement: .principal) {
                ControlGroup {
                    Button {
                        refreshAll()
                    } label: {
                        Label(
                            "Refresh all clients",
                            systemImage: "arrow.clockwise"
                        )
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 24, minHeight: 24)
                        .contentShape(Rectangle())
                    }
                    .help("Refresh all clients (⇧⌘R)")

                    Button {
                        takeScreenshot()
                    } label: {
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
                    .disabled(isTakingScreenshot)
                    .help("Save all visible clients in one row")
                }
                .controlSize(.regular)
                .fixedSize()
            }

            ToolbarItem(placement: .primaryAction) {
                SourceVisibilityControls(workspace: workspace)
            }
        }
        .sheet(isPresented: $showHelp) {
            HelpSheet(androidDevices: workspace.androidDevices)
        }
        .sheet(isPresented: $showScreenshotSettings) {
            ScreenshotSettingsSheet(workspace: workspace)
        }
        .alert(
            "Screenshot Failed",
            isPresented: Binding(
                get: { screenshotError != nil },
                set: { if !$0 { screenshotError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                screenshotError = nil
            }
        } message: {
            Text(screenshotError ?? "The screenshot could not be saved.")
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
        }
        .onDisappear {
            dismissScreenshotTask?.cancel()
            workspace.stopCaptures()
        }
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
    }

    private var workspaceBackground: some View {
        ZStack {
            Rectangle()
                .fill(.background)

            LinearGradient(
                colors: [
                    ViewerSource.web.accentColor.opacity(0.08),
                    Color.clear,
                    ViewerSource.iOS.accentColor.opacity(0.07)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }

    private func refreshAll() {
        web.reload()
        workspace.refreshAll()
    }

    private func takeScreenshot() {
        guard !isTakingScreenshot else { return }
        isTakingScreenshot = true
        screenshotError = nil

        Task { @MainActor in
            do {
                let service = WorkspaceScreenshotService()
                let image = try await service.createComposite(
                    sources: workspace.orderedVisibleSources,
                    web: web,
                    workspace: workspace,
                    includePlatformLabels: workspace.screenshotPlatformLabelsEnabled
                )
                if let url = try service.save(image) {
                    presentScreenshotToast(url)
                }
            } catch {
                screenshotError = error.localizedDescription
            }
            isTakingScreenshot = false
        }
    }

    private func presentScreenshotToast(_ url: URL) {
        dismissScreenshotTask?.cancel()
        screenshotSavedURL = url
        dismissScreenshotTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            clearScreenshotToast()
        }
    }

    private func clearScreenshotToast() {
        dismissScreenshotTask?.cancel()
        dismissScreenshotTask = nil
        screenshotSavedURL = nil
    }
}
