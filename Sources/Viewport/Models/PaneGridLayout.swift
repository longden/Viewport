import Foundation

/// Layout model for the workspace row of panes.
///
/// Supports optional Web plus up to two Android and two iOS panes, capped at
/// ``maximumPaneCount`` total. Nested vertical splits remain future work.
struct PaneGridNode: Identifiable, Codable, Equatable {
    var id: UUID
    var source: String
    var weight: Double
    /// 0 = primary capture session, 1 = secondary (second Android / iOS pane).
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

    static let maximumPaneCount = 4
    static let maximumDevicePanesPerSource = 2

    static let defaultTriple = PaneGridLayout(
        axis: .horizontal,
        nodes: ViewerSource.allCases.map { PaneGridNode(source: $0, slot: 0) }
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
        let slot = count(of: source)
        let node = PaneGridNode(source: source, weight: weight, slot: slot)
        nodes.append(node)
        return node
    }

    mutating func removePanes(of source: ViewerSource) {
        nodes.removeAll { $0.source == source.rawValue }
    }

    mutating func removePane(id: UUID) {
        nodes.removeAll { $0.id == id }
        reindexSlots()
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
        reindexSlots()
        return true
    }

    private mutating func reindexSlots() {
        for source in [ViewerSource.android, .iOS, .web] {
            var slot = 0
            for index in nodes.indices where nodes[index].source == source.rawValue {
                nodes[index].slot = slot
                slot += 1
            }
        }
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
