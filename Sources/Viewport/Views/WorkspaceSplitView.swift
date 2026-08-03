import SwiftUI

struct WorkspaceSplitView: View {
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var web: WebViewModel
    @ObservedObject var favorites: FavoritesStore
    @State private var dragState: DividerDragState?

    private let minimumPaneWidth: CGFloat = 190
    private let dividerWidth: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let sources = workspace.orderedVisibleSources
            let contentWidth = max(
                proxy.size.width
                    - dividerWidth * CGFloat(max(sources.count - 1, 0)),
                1
            )
            let widths = paneWidths(
                for: sources,
                availableWidth: contentWidth
            )

            HStack(spacing: 0) {
                ForEach(Array(sources.enumerated()), id: \.element) {
                    index, source in
                    pane(for: source)
                        .frame(width: widths[source])
                        .frame(maxHeight: .infinity)
                        .id(source)

                    if index < sources.count - 1 {
                        PaneResizeHandle()
                            .frame(width: dividerWidth)
                            .gesture(
                                resizeGesture(
                                    leading: source,
                                    trailing: sources[index + 1],
                                    widths: widths
                                )
                            )
                    }
                }
            }
        }
    }

    private func paneWidths(
        for sources: [ViewerSource],
        availableWidth: CGFloat
    ) -> [ViewerSource: CGFloat] {
        guard !sources.isEmpty else { return [:] }

        let totalWeight = sources.reduce(0) {
            $0 + workspace.paneWeight(for: $1)
        }
        let unconstrained = Dictionary(uniqueKeysWithValues: sources.map {
            source in
            (
                source,
                availableWidth
                    * CGFloat(workspace.paneWeight(for: source) / totalWeight)
            )
        })

        guard availableWidth >= minimumPaneWidth * CGFloat(sources.count) else {
            let equalWidth = availableWidth / CGFloat(sources.count)
            return Dictionary(uniqueKeysWithValues: sources.map {
                ($0, equalWidth)
            })
        }

        var widths = unconstrained
        var flexibleSources = Set(sources)
        var remainingWidth = availableWidth
        var remainingWeight = totalWeight

        while let undersized = flexibleSources.first(where: {
            source in
            remainingWidth
                * CGFloat(workspace.paneWeight(for: source) / remainingWeight)
                < minimumPaneWidth
        }) {
            widths[undersized] = minimumPaneWidth
            flexibleSources.remove(undersized)
            remainingWidth -= minimumPaneWidth
            remainingWeight -= workspace.paneWeight(for: undersized)
        }

        for source in flexibleSources {
            widths[source] = remainingWidth
                * CGFloat(workspace.paneWeight(for: source) / remainingWeight)
        }
        return widths
    }

    private func resizeGesture(
        leading: ViewerSource,
        trailing: ViewerSource,
        widths: [ViewerSource: CGFloat]
    ) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let state: DividerDragState
                if let dragState,
                   dragState.leading == leading,
                   dragState.trailing == trailing {
                    state = dragState
                } else {
                    state = DividerDragState(
                        leading: leading,
                        trailing: trailing,
                        leadingWidth: widths[leading] ?? minimumPaneWidth,
                        trailingWidth: widths[trailing] ?? minimumPaneWidth
                    )
                    dragState = state
                }

                let combinedWidth = state.leadingWidth + state.trailingWidth
                let leadingWidth = min(
                    max(
                        state.leadingWidth + value.translation.width,
                        minimumPaneWidth
                    ),
                    combinedWidth - minimumPaneWidth
                )
                let combinedWeight = workspace.paneWeight(for: leading)
                    + workspace.paneWeight(for: trailing)
                let leadingWeight = combinedWeight
                    * Double(leadingWidth / combinedWidth)

                workspace.resizePanes(
                    leading: leading,
                    leadingWeight: leadingWeight,
                    trailing: trailing,
                    trailingWeight: combinedWeight - leadingWeight,
                    persist: false
                )
            }
            .onEnded { _ in
                dragState = nil
                workspace.persistPaneWeights()
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
                deviceManager: workspace.androidDevices
            )
        case .iOS:
            CaptureViewerPane(
                session: workspace.iOSCapture,
                deviceManager: workspace.iOSDevices
            )
        }
    }
}

private struct DividerDragState {
    let leading: ViewerSource
    let trailing: ViewerSource
    let leadingWidth: CGFloat
    let trailingWidth: CGFloat
}

private struct PaneResizeHandle: View {
    @State private var isHovered = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .overlay {
                Capsule()
                    .fill(.primary.opacity(isHovered ? 0.22 : 0.10))
                    .frame(width: isHovered ? 3 : 1, height: 42)
                    .animation(.easeOut(duration: 0.12), value: isHovered)
            }
            .onHover { isHovered = $0 }
            .help("Drag to resize panes")
    }
}
