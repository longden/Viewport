import SwiftUI

struct ContentView: View {
    @StateObject private var workspace = WorkspaceStore()
    @StateObject private var web = WebViewModel()
    @StateObject private var favorites = FavoritesStore()

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
                HStack(spacing: 8) {
                    Image(systemName: "viewfinder")
                    Text("Viewport")
                        .fontWeight(.semibold)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    refreshAll()
                } label: {
                    Label("Refresh all clients", systemImage: "arrow.clockwise")
                }
                .help("Refresh all clients (⇧⌘R)")
            }

            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }

            ToolbarItem(placement: .primaryAction) {
                SourceVisibilityButton(
                    workspace: workspace,
                    source: .web
                )
            }

            ToolbarItem(placement: .primaryAction) {
                SourceVisibilityButton(
                    workspace: workspace,
                    source: .android
                )
            }

            ToolbarItem(placement: .primaryAction) {
                SourceVisibilityButton(
                    workspace: workspace,
                    source: .iOS
                )
            }
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
}
