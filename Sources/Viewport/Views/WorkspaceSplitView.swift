import SwiftUI

struct WorkspaceSplitView: View {
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var web: WebViewModel
    @ObservedObject var favorites: FavoritesStore

    var body: some View {
        HSplitView {
            ForEach(workspace.orderedVisibleSources) { source in
                pane(for: source)
                    .frame(
                        minWidth: 190,
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
                    .id(source)
            }
        }
    }

    @ViewBuilder
    private func pane(for source: ViewerSource) -> some View {
        switch source {
        case .web:
            WebViewerPane(model: web, favorites: favorites)
        case .android:
            CaptureViewerPane(
                session: workspace.androidCapture,
                deviceManager: workspace.androidDevices,
                onRequestScreenAccess: workspace.requestScreenRecordingAccess
            )
        case .iOS:
            CaptureViewerPane(
                session: workspace.iOSCapture,
                deviceManager: workspace.iOSDevices,
                onRequestScreenAccess: workspace.requestScreenRecordingAccess
            )
        }
    }
}
