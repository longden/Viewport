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

    private var gestureStarts: [ViewerSource: CGPoint] = [:]

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
        guard workspace?.synchronizedScrollingEnabled == true else { return }
        switch phase {
        case .began:
            gestureStarts[source] = point
        case .moved:
            break
        case .ended:
            defer { gestureStarts[source] = nil }
            guard let start = gestureStarts[source] else { return }
            let deltaY = (point.y - start.y) * 900
            if abs(deltaY) > 8 {
                web?.scrollBy(deltaY: deltaY)
            }
        }
    }
}
