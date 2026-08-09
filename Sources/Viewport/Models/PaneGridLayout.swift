import Foundation

/// Future-facing layout model for custom multi-pane grids.
///
/// Today Viewport uses a fixed `ViewerSource` trio (web / android / iOS) with
/// horizontal `WorkspaceSplitView` weights. A full grid rewrite would replace
/// that with an ordered array of pane nodes plus nested split descriptors.
///
/// This type is intentionally unused by runtime UI — it documents the
/// incremental path without destabilizing `WorkspaceStore`.
struct PaneGridNode: Identifiable, Codable, Equatable {
    var id: UUID
    var source: String
    var weight: Double

    init(
        id: UUID = UUID(),
        source: ViewerSource,
        weight: Double = 1
    ) {
        self.id = id
        self.source = source.rawValue
        self.weight = max(weight, 0.01)
    }
}

enum PaneGridSplitAxis: String, Codable {
    case horizontal
    case vertical
}

struct PaneGridLayout: Codable, Equatable {
    var axis: PaneGridSplitAxis
    var nodes: [PaneGridNode]

    static let defaultTriple = PaneGridLayout(
        axis: .horizontal,
        nodes: ViewerSource.allCases.map { PaneGridNode(source: $0) }
    )
}

enum PaneGridMigration {
    /// Suggested steps when product commits to arbitrary grids:
    /// 1. Persist `PaneGridLayout` beside `visibleSources` / `paneWeights`.
    /// 2. Teach `WorkspaceSplitView` to render nested H/V stacks from nodes.
    /// 3. Allow duplicate sources (e.g. two web panes) via pane instances.
    /// 4. Keep capture sessions keyed by pane id, not only by `ViewerSource`.
    static let roadmapNote = """
    Custom multi-pane grids require evolving WorkspaceStore from a fixed \
    web/android/iOS trio toward pane-node arrays + nested splits. Prefer that \
    rewrite only when multi-env monitoring is a committed product goal.
    """
}
