import SwiftUI

private struct PaneResizingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the user is dragging a pane divider. Panes should avoid
    /// expensive per-frame work (glass HUDs, live buffer swaps) until it ends.
    var isPaneResizing: Bool {
        get { self[PaneResizingKey.self] }
        set { self[PaneResizingKey.self] = newValue }
    }
}

struct WorkspaceSplitView: View {
    @ObservedObject var workspace: WorkspaceStore
    var web: WebViewModel
    var favorites: FavoritesStore
    var onPaneScreenshot: ((ViewerSource, WindowCaptureSession?) -> Void)?
    var onWebCaptureTargetChange: (@MainActor (WorkspaceRecordingTarget?) -> Void)?
    var squareWebContentCorners: Bool = false
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
            let isResizing = transientPaneWidths != nil

            HStack(spacing: 0) {
                ForEach(Array(panes.enumerated()), id: \.element.id) {
                    index, node in
                    pane(for: node)
                        .frame(width: widths[node.id])
                        .frame(maxHeight: .infinity)
                        .clipped()
                        .id(node.id)

                    if index < panes.count - 1 {
                        SplitResizeHandle(
                            axis: .horizontal,
                            help: "Drag to resize panes",
                            onDeltaChanged: { delta in
                                applyResizeDelta(
                                    leading: node,
                                    trailing: panes[index + 1],
                                    widths: widths,
                                    delta: delta
                                )
                            },
                            onEnded: {
                                commitResize(
                                    widths: widths
                                )
                            }
                        )
                        .frame(width: dividerWidth)
                    }
                }
            }
            .frame(
                width: proxy.size.width,
                height: proxy.size.height,
                alignment: .topLeading
            )
            .clipped()
            .environment(\.isPaneResizing, isResizing)
            .transaction { transaction in
                if isResizing {
                    transaction.disablesAnimations = true
                    transaction.animation = nil
                }
            }
            .onAppear {
                workspace.noteSplitContentSize(proxy.size)
            }
            .onChange(of: proxy.size) { _, newSize in
                workspace.noteSplitContentSize(newSize)
            }
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

    private func applyResizeDelta(
        leading: PaneGridNode,
        trailing: PaneGridNode,
        widths: [UUID: CGFloat],
        delta: CGFloat
    ) {
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
                (state.leadingWidth + delta).rounded(),
                minimumPaneWidth
            ),
            combinedWidth - minimumPaneWidth
        ).rounded()
        let trailingWidth = (combinedWidth - leadingWidth).rounded()

        var updatedWidths = transientPaneWidths ?? widths
        if updatedWidths[leading.id] == leadingWidth,
           updatedWidths[trailing.id] == trailingWidth {
            return
        }
        updatedWidths[leading.id] = leadingWidth
        updatedWidths[trailing.id] = trailingWidth
        var transaction = Transaction()
        transaction.disablesAnimations = true
        transaction.animation = nil
        withTransaction(transaction) {
            transientPaneWidths = updatedWidths
        }
    }

    private func commitResize(widths: [UUID: CGFloat]) {
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
        transaction.animation = nil
        withTransaction(transaction) {
            dragState = nil
            transientPaneWidths = nil
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
                    { handler(.web, nil) }
                },
                onCaptureTargetChange: onWebCaptureTargetChange,
                squareContentCorners: squareWebContentCorners,
                onClose: {
                    workspace.setVisible(false, for: .web)
                }
            )
        case .android, .iOS:
            if let session = workspace.captureSession(for: node) {
                CaptureViewerPane(
                    session: session,
                    deviceManager: node.viewerSource == .android
                        ? workspace.androidDevices
                        : workspace.iOSDevices,
                    host: CapturePaneHost(
                        onFocus: {
                            workspace.focusCapture(
                                source: session.source,
                                paneID: node.id
                            )
                        },
                        onClose: {
                            _ = workspace.closePane(id: node.id)
                        },
                        onLaunch: { device in
                            workspace.launch(device, into: session)
                        },
                        onShutdown: { device in
                            workspace.shutdownGuest(device)
                        },
                        rotate: {
                            workspace.focusCapture(
                                source: session.source,
                                paneID: node.id
                            )
                            try await workspace.rotateFocusedDevice()
                        },
                        pressHome: {
                            workspace.focusCapture(
                                source: session.source,
                                paneID: node.id
                            )
                            try await workspace.pressHomeOnFocusedDevice()
                        },
                        pressBack: {
                            workspace.focusCapture(
                                source: session.source,
                                paneID: node.id
                            )
                            try await workspace.pressBackOnFocusedDevice()
                        }
                    ),
                    paneID: node.id,
                    paneTitleSuffix: node.slot >= 1 ? " \(node.slot + 1)" : nil,
                    isClosable: node.slot >= 1,
                    isExtraPane: node.slot >= 1,
                    onScreenshot: onPaneScreenshot.map { handler in
                        { handler(node.viewerSource ?? .android, session) }
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

