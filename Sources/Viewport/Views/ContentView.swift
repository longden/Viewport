import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var workspace = WorkspaceStore()
    @StateObject private var web = WebViewModel()
    @StateObject private var favorites = FavoritesStore()
    @State private var isTakingScreenshot = false
    @State private var screenshotError: String?

    var body: some View {
        ZStack {
            workspaceBackground

            WorkspaceSplitView(
                workspace: workspace,
                web: web,
                favorites: favorites
            )
            .padding(16)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
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
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Viewport settings")
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
                    workspace: workspace
                )
                _ = try service.save(image)
            } catch {
                screenshotError = error.localizedDescription
            }
            isTakingScreenshot = false
        }
    }
}
