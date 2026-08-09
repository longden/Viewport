import CoreGraphics
import Foundation

enum PointerEventPhase: String, Codable {
    case began
    case moved
    case ended
}

/// Bridges capture-pane pointer events into prototype web scroll sync.
@MainActor
final class PointerEventBridge {
    weak var workspace: WorkspaceStore?
    weak var web: WebViewModel?

    private var lastPoint: [ViewerSource: CGPoint] = [:]
    /// Maps normalized pane Y delta into CSS pixels (prototype scale).
    private let scrollScale: CGFloat = 900

    func install(on session: WindowCaptureSession) {
        let source = session.source
        session.pointerEventSink = { [weak self] phase, point, duration in
            self?.handle(
                source: source,
                phase: phase,
                point: point,
                duration: duration
            )
        }
    }

    private func handle(
        source: ViewerSource,
        phase: PointerEventPhase,
        point: CGPoint,
        duration: TimeInterval?
    ) {
        _ = duration
        guard workspace?.synchronizedScrollingEnabled == true,
              workspace?.isVisible(.web) == true else { return }

        switch phase {
        case .began:
            lastPoint[source] = point
        case .moved:
            guard let previous = lastPoint[source] else {
                lastPoint[source] = point
                return
            }
            lastPoint[source] = point
            // Touch: finger up (y decreases) should scroll the page down (positive).
            let deltaY = (previous.y - point.y) * scrollScale
            if abs(deltaY) > 0.5 {
                web?.scrollBy(deltaY: deltaY)
            }
        case .ended:
            defer { lastPoint[source] = nil }
            guard let previous = lastPoint[source] else { return }
            let deltaY = (previous.y - point.y) * scrollScale
            if abs(deltaY) > 0.5 {
                web?.scrollBy(deltaY: deltaY)
            }
        }
    }
}
