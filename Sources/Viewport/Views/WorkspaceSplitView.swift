import SwiftUI

struct WorkspaceSplitView: View {
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var web: WebViewModel
    @ObservedObject var favorites: FavoritesStore
    var onPaneScreenshot: ((ViewerSource) -> Void)?
    var onWebCaptureTargetChange: (@MainActor (WorkspaceRecordingTarget?) -> Void)?
    var squareWebContentCorners: Bool = false
    var showNetworkOverlay: Bool = false
    @State private var dragState: DividerDragState?
    @State private var transientPaneWidths: [UUID: CGFloat]?

    private let minimumPaneWidth: CGFloat = 190
    private let dividerWidth: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let panes = workspace.orderedVisiblePanes
            let contentWidth = max(
                proxy.size.width
                    - dividerWidth * CGFloat(max(panes.count - 1, 0)),
                1
            )
            let persistedWidths = paneWidths(
                for: panes,
                availableWidth: contentWidth
            )
            let widths = transientPaneWidths ?? persistedWidths

            HStack(spacing: 0) {
                ForEach(Array(panes.enumerated()), id: \.element.id) {
                    index, node in
                    pane(for: node)
                        .frame(width: widths[node.id])
                        .frame(maxHeight: .infinity)
                        .clipped()
                        .id(node.id)

                    if index < panes.count - 1 {
                        PaneResizeHandle()
                            .frame(width: dividerWidth)
                            .gesture(
                                resizeGesture(
                                    leading: node,
                                    trailing: panes[index + 1],
                                    widths: widths
                                )
                            )
                    }
                }
            }
            .frame(
                width: proxy.size.width,
                height: proxy.size.height,
                alignment: .topLeading
            )
            .clipped()
            .onChange(of: panes.map(\.id)) {
                dragState = nil
                transientPaneWidths = nil
            }
        }
    }

    private func paneWidths(
        for panes: [PaneGridNode],
        availableWidth: CGFloat
    ) -> [UUID: CGFloat] {
        guard !panes.isEmpty else { return [:] }

        let totalWeight = panes.reduce(0) { $0 + $1.weight }
        let unconstrained = Dictionary(uniqueKeysWithValues: panes.map {
            node in
            (
                node.id,
                availableWidth * CGFloat(node.weight / totalWeight)
            )
        })

        guard availableWidth >= minimumPaneWidth * CGFloat(panes.count) else {
            let equalWidth = availableWidth / CGFloat(panes.count)
            return Dictionary(uniqueKeysWithValues: panes.map {
                ($0.id, equalWidth)
            })
        }

        var widths = unconstrained
        var flexibleIDs = Set(panes.map(\.id))
        var remainingWidth = availableWidth
        var remainingWeight = totalWeight
        let weightByID = Dictionary(uniqueKeysWithValues: panes.map {
            ($0.id, $0.weight)
        })

        while let undersized = flexibleIDs.first(where: { id in
            remainingWidth
                * CGFloat((weightByID[id] ?? 1) / remainingWeight)
                < minimumPaneWidth
        }) {
            widths[undersized] = minimumPaneWidth
            flexibleIDs.remove(undersized)
            remainingWidth -= minimumPaneWidth
            remainingWeight -= weightByID[undersized] ?? 1
        }

        for id in flexibleIDs {
            widths[id] = remainingWidth
                * CGFloat((weightByID[id] ?? 1) / remainingWeight)
        }
        return widths
    }

    private func resizeGesture(
        leading: PaneGridNode,
        trailing: PaneGridNode,
        widths: [UUID: CGFloat]
    ) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let state: DividerDragState
                if let dragState,
                   dragState.leadingID == leading.id,
                   dragState.trailingID == trailing.id {
                    state = dragState
                } else {
                    state = DividerDragState(
                        leadingID: leading.id,
                        trailingID: trailing.id,
                        leadingWidth: widths[leading.id] ?? minimumPaneWidth,
                        trailingWidth: widths[trailing.id] ?? minimumPaneWidth
                    )
                    dragState = state
                    transientPaneWidths = widths
                }

                let combinedWidth = state.leadingWidth + state.trailingWidth
                let leadingWidth = min(
                    max(
                        state.leadingWidth + value.translation.width,
                        minimumPaneWidth
                    ),
                    combinedWidth - minimumPaneWidth
                )
                var updatedWidths = transientPaneWidths ?? widths
                updatedWidths[leading.id] = leadingWidth
                updatedWidths[trailing.id] = combinedWidth - leadingWidth
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    transientPaneWidths = updatedWidths
                }
            }
            .onEnded { _ in
                guard let state = dragState else {
                    transientPaneWidths = nil
                    return
                }
                let widths = transientPaneWidths ?? widths
                let leadingWidth = widths[state.leadingID] ?? state.leadingWidth
                let trailingWidth = widths[state.trailingID] ?? state.trailingWidth
                let combinedWidth = max(leadingWidth + trailingWidth, 1)
                let combinedWeight = workspace.paneWeight(forPaneID: state.leadingID)
                    + workspace.paneWeight(forPaneID: state.trailingID)
                let leadingWeight = combinedWeight
                    * Double(leadingWidth / combinedWidth)

                workspace.resizePanes(
                    leadingID: state.leadingID,
                    leadingWeight: leadingWeight,
                    trailingID: state.trailingID,
                    trailingWeight: combinedWeight - leadingWeight,
                    persist: true
                )
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    dragState = nil
                    transientPaneWidths = nil
                }
            }
    }

    @ViewBuilder
    private func pane(for node: PaneGridNode) -> some View {
        switch node.viewerSource {
        case .web:
            WebViewerPane(
                model: web,
                favorites: favorites,
                onScreenshot: onPaneScreenshot.map { handler in
                    { handler(.web) }
                },
                onCaptureTargetChange: onWebCaptureTargetChange,
                squareContentCorners: squareWebContentCorners,
                showNetworkOverlay: showNetworkOverlay
            )
        case .android, .iOS:
            if let session = workspace.captureSession(for: node) {
                CaptureViewerPane(
                    session: session,
                    deviceManager: node.viewerSource == .android
                        ? workspace.androidDevices
                        : workspace.iOSDevices,
                    workspace: workspace,
                    paneID: node.id,
                    paneTitleSuffix: node.slot >= 1 ? " \(node.slot + 1)" : nil,
                    isClosable: node.slot >= 1,
                    onScreenshot: onPaneScreenshot.map { handler in
                        { handler(node.viewerSource ?? .android) }
                    },
                    showPerfHUD: workspace.perfHUDEnabled,
                    showDeviceBezels: workspace.deviceBezelsEnabled
                )
            }
        case .none:
            EmptyView()
        }
    }
}

private struct DividerDragState {
    let leadingID: UUID
    let trailingID: UUID
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
