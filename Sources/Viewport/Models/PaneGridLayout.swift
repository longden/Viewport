import Foundation

/// Layout model for the workspace row of panes.
///
/// Supports optional Web plus up to five Android and five iOS panes, capped at
/// ``maximumPaneCount`` total. Nested vertical splits remain future work.
struct PaneGridNode: Identifiable, Codable, Equatable {
    var id: UUID
    var source: String
    var weight: Double
    /// Stable capture-session slot for this platform.
    var slot: Int

    var viewerSource: ViewerSource? {
        ViewerSource(rawValue: source)
    }

    init(
        id: UUID = UUID(),
        source: ViewerSource,
        weight: Double = 1,
        slot: Int = 0
    ) {
        self.id = id
        self.source = source.rawValue
        self.weight = max(weight, 0.01)
        self.slot = max(slot, 0)
    }
}

enum PaneGridSplitAxis: String, Codable {
    case horizontal
    case vertical
}

struct PaneGridLayout: Codable, Equatable {
    var axis: PaneGridSplitAxis
    var nodes: [PaneGridNode]

    static let maximumDevicePanesPerSource = 5
    static let maximumPaneCount = 1 + 2 * maximumDevicePanesPerSource

    /// Matches ``WorkspaceSplitView`` divider / clamp metrics.
    static let splitDividerWidth: Double = 12
    static func minimumPaneWidth(forPaneCount count: Int) -> Double {
        120 + Double(max(count - 1, 0)) * 15
    }
    /// Title + controls + padding above the live preview inside a pane.
    static let paneChromeHeight: Double = 140
    /// Typical modern phone width÷height when no live frame is available.
    static let fallbackDeviceAspect: Double = 9.0 / 19.5

    /// Default desk used for first-launch weights before GeometryReader reports.
    static let defaultSplitContentSize = CGSize(width: 1_596, height: 860)

    static func preferredWeight(for source: ViewerSource) -> Double {
        preferredSourceWeights[source] ?? minimumPaneWidth(forPaneCount: 1)
    }

    /// Source-level defaults derived from the aspect-fit layout at the default desk.
    static var preferredSourceWeights: [ViewerSource: Double] {
        let nodes = ViewerSource.allCases.map {
            PaneGridNode(source: $0, weight: 1, slot: 0)
        }
        let widths = balancedPaneWidths(
            nodes: nodes,
            contentSize: defaultSplitContentSize,
            deviceAspectByNodeID: [:]
        )
        var weights: [ViewerSource: Double] = [:]
        for node in nodes {
            guard let source = node.viewerSource else { continue }
            weights[source] = widths[node.id] ?? preferredWeight(for: source)
        }
        return weights
    }

    /// Sizes device panes to fill preview height at phone aspect; web gets the rest.
    static func balancedPaneWidths(
        nodes: [PaneGridNode],
        contentSize: CGSize,
        deviceAspectByNodeID: [UUID: Double]
    ) -> [UUID: Double] {
        guard !nodes.isEmpty else { return [:] }

        let minimumPaneWidth = minimumPaneWidth(forPaneCount: nodes.count)

        let dividerTotal = splitDividerWidth * Double(max(nodes.count - 1, 0))
        let availableWidth = max(Double(contentSize.width) - dividerTotal, minimumPaneWidth)
        let previewHeight = max(
            Double(contentSize.height) - paneChromeHeight,
            minimumPaneWidth
        )

        let deviceNodes = nodes.filter {
            $0.viewerSource == .android || $0.viewerSource == .iOS
        }
        let webNodes = nodes.filter { $0.viewerSource == .web }
        let otherNodes = nodes.filter {
            $0.viewerSource != .android
                && $0.viewerSource != .iOS
                && $0.viewerSource != .web
        }

        var widths: [UUID: Double] = [:]

        for node in deviceNodes {
            let aspect = deviceAspectByNodeID[node.id] ?? fallbackDeviceAspect
            let clampedAspect = min(max(aspect, 0.35), 0.75)
            widths[node.id] = previewHeight * clampedAspect
        }
        for node in otherNodes {
            widths[node.id] = minimumPaneWidth
        }

        let reservedNonWeb = deviceNodes.reduce(0.0) { $0 + (widths[$1.id] ?? 0) }
            + Double(otherNodes.count) * minimumPaneWidth
        let webFloor = minimumPaneWidth * Double(webNodes.count)
        let deviceFloor = minimumPaneWidth * Double(deviceNodes.count)

        if webNodes.isEmpty {
            // Spread leftover across device panes so the row still fills.
            let leftover = max(availableWidth - reservedNonWeb, 0)
            let bonus = deviceNodes.isEmpty
                ? 0
                : leftover / Double(deviceNodes.count)
            for node in deviceNodes {
                widths[node.id, default: minimumPaneWidth] += bonus
            }
        } else if reservedNonWeb + webFloor > availableWidth {
            // Shrink devices (and others) so web keeps a usable column.
            let shrinkable = max(reservedNonWeb, 0.01)
            let target = max(availableWidth - webFloor, deviceFloor)
            let scale = target / shrinkable
            for node in deviceNodes + otherNodes {
                widths[node.id] = max(
                    (widths[node.id] ?? minimumPaneWidth) * scale,
                    minimumPaneWidth
                )
            }
            let used = nodes.reduce(0.0) { partial, node in
                if node.viewerSource == .web { return partial }
                return partial + (widths[node.id] ?? minimumPaneWidth)
            }
            let webShare = max(availableWidth - used, webFloor) / Double(webNodes.count)
            for node in webNodes {
                widths[node.id] = webShare
            }
        } else {
            let webShare = (availableWidth - reservedNonWeb) / Double(webNodes.count)
            for node in webNodes {
                widths[node.id] = max(webShare, minimumPaneWidth)
            }
        }

        // Final pass: if rounding left a gap or overflow, leave as relative weights.
        for node in nodes where widths[node.id] == nil {
            widths[node.id] = minimumPaneWidth
        }
        return widths
    }

    static let defaultTriple = PaneGridLayout(
        axis: .horizontal,
        nodes: ViewerSource.allCases.map {
            PaneGridNode(
                source: $0,
                weight: preferredWeight(for: $0),
                slot: 0
            )
        }
    )

    static func fromVisibleSources(
        _ sources: Set<ViewerSource>,
        weights: [ViewerSource: Double]
    ) -> PaneGridLayout {
        let ordered = ViewerSource.allCases.filter(sources.contains)
        return PaneGridLayout(
            axis: .horizontal,
            nodes: ordered.map { source in
                PaneGridNode(
                    source: source,
                    weight: weights[source] ?? 1,
                    slot: 0
                )
            }
        )
    }

    func count(of source: ViewerSource) -> Int {
        nodes.filter { $0.source == source.rawValue }.count
    }

    func canAddPane(source: ViewerSource) -> Bool {
        guard nodes.count < Self.maximumPaneCount else { return false }
        switch source {
        case .web:
            return count(of: .web) == 0
        case .android, .iOS:
            return count(of: source) < Self.maximumDevicePanesPerSource
        }
    }

    mutating func addPane(source: ViewerSource, weight: Double = 1) -> PaneGridNode? {
        guard canAddPane(source: source) else { return nil }
        let occupiedSlots = Set(nodes.filter { $0.source == source.rawValue }.map(\.slot))
        guard let slot = (0..<Self.maximumDevicePanesPerSource).first(where: {
            !occupiedSlots.contains($0)
        }) else { return nil }
        let node = PaneGridNode(source: source, weight: weight, slot: slot)
        nodes.insert(node, at: insertionIndex(for: source))
        nodes.sort(by: Self.canonicalPaneOrder)
        return node
    }

    mutating func removePanes(of source: ViewerSource) {
        nodes.removeAll { $0.source == source.rawValue }
    }

    mutating func removePane(id: UUID) {
        nodes.removeAll { $0.id == id }
    }

    /// Drops the highest-slot secondary pane for a source.
    /// Returns `false` when there is no slot ≥ 1 (never removes the primary).
    mutating func removeExtraPane(of source: ViewerSource) -> Bool {
        guard let secondary = nodes.last(where: {
            $0.source == source.rawValue && $0.slot >= 1
        }) else {
            return false
        }
        nodes.removeAll { $0.id == secondary.id }
        return true
    }

    /// Stable left-to-right order: Web, Android, iOS (by slot within a source).
    mutating func normalizeCanonicalOrder() {
        nodes.sort(by: Self.canonicalPaneOrder)
    }

    var canonicallyOrderedNodes: [PaneGridNode] {
        nodes.sorted(by: Self.canonicalPaneOrder)
    }

    nonisolated static func canonicalPaneOrder(
        _ lhs: PaneGridNode,
        _ rhs: PaneGridNode
    ) -> Bool {
        let left = sourceOrderIndex(lhs.viewerSource)
        let right = sourceOrderIndex(rhs.viewerSource)
        if left != right {
            return left < right
        }
        return lhs.slot < rhs.slot
    }

    private func insertionIndex(for source: ViewerSource) -> Int {
        let newOrder = Self.sourceOrderIndex(source)
        if let lastSame = nodes.lastIndex(where: { $0.source == source.rawValue }) {
            return lastSame + 1
        }
        if let next = nodes.firstIndex(where: {
            Self.sourceOrderIndex($0.viewerSource) > newOrder
        }) {
            return next
        }
        return nodes.endIndex
    }

    private nonisolated static func sourceOrderIndex(_ source: ViewerSource?) -> Int {
        guard let source,
              let index = ViewerSource.allCases.firstIndex(of: source) else {
            return ViewerSource.allCases.count
        }
        return index
    }

}

enum PaneGridMigration {
    /// Incremental path notes for nested grids beyond the flat 4-pane row.
    static let roadmapNote = """
    Custom multi-pane grids require evolving WorkspaceStore from a fixed \
    web/android/iOS trio toward pane-node arrays + nested splits. Prefer that \
    rewrite only when multi-env monitoring is a committed product goal.
    """
}
