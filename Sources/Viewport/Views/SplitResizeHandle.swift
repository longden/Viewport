import AppKit
import SwiftUI

enum SplitResizeAxis {
    /// Vertical bar; drag left and right.
    case horizontal
    /// Horizontal bar; drag up and down.
    case vertical

    var cursor: NSCursor {
        switch self {
        case .horizontal:
            .resizeLeftRight
        case .vertical:
            .resizeUpDown
        }
    }
}

/// Split-view handle that tracks the mouse in window space.
///
/// SwiftUI `DragGesture` is attached to the moving divider, so the translation
/// jumps and the gesture is easy to lose to window-dragging or the live panes.
/// AppKit keeps mouse-dragged events on the view that received mouse-down.
struct SplitResizeHandle: View {
    var axis: SplitResizeAxis
    var help: String
    var onDeltaChanged: (CGFloat) -> Void
    var onEnded: () -> Void

    @State private var isHovered = false

    var body: some View {
        SplitResizeTrackingView(
            axis: axis,
            onDeltaChanged: onDeltaChanged,
            onEnded: onEnded,
            onHoverChanged: { hovered in
                isHovered = hovered
            }
        )
        .overlay {
            Capsule()
                .fill(.primary.opacity(isHovered ? 0.22 : 0.10))
                .frame(
                    width: axis == .horizontal ? (isHovered ? 3 : 1) : 42,
                    height: axis == .horizontal ? 42 : (isHovered ? 3 : 1)
                )
                .allowsHitTesting(false)
        }
        .help(help)
    }
}

private struct SplitResizeTrackingView: NSViewRepresentable {
    var axis: SplitResizeAxis
    var onDeltaChanged: (CGFloat) -> Void
    var onEnded: () -> Void
    var onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> SplitResizeTrackingNSView {
        let view = SplitResizeTrackingNSView()
        view.axis = axis
        view.onDeltaChanged = onDeltaChanged
        view.onEnded = onEnded
        view.onHoverChanged = onHoverChanged
        return view
    }

    func updateNSView(_ nsView: SplitResizeTrackingNSView, context: Context) {
        nsView.axis = axis
        nsView.onDeltaChanged = onDeltaChanged
        nsView.onEnded = onEnded
        nsView.onHoverChanged = onHoverChanged
    }
}

private final class SplitResizeTrackingNSView: NSView {
    var axis: SplitResizeAxis = .horizontal
    var onDeltaChanged: ((CGFloat) -> Void)?
    var onEnded: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private var startWindowPoint: CGPoint?
    private var didPushCursor = false

    override var mouseDownCanMoveWindow: Bool { false }

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [
                    .mouseEnteredAndExited,
                    .activeInKeyWindow,
                    .inVisibleRect
                ],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: axis.cursor)
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        if startWindowPoint == nil {
            onHoverChanged?(false)
        }
    }

    override func mouseDown(with event: NSEvent) {
        startWindowPoint = event.locationInWindow
        window?.disableCursorRects()
        axis.cursor.push()
        didPushCursor = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startWindowPoint else { return }
        let current = event.locationInWindow
        let delta: CGFloat
        switch axis {
        case .horizontal:
            delta = current.x - startWindowPoint.x
        case .vertical:
            delta = current.y - startWindowPoint.y
        }
        onDeltaChanged?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        finishDrag()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, startWindowPoint != nil {
            finishDrag()
        }
    }

    private func finishDrag() {
        guard startWindowPoint != nil || didPushCursor else { return }
        startWindowPoint = nil
        if didPushCursor {
            NSCursor.pop()
            didPushCursor = false
        }
        window?.enableCursorRects()
        window?.invalidateCursorRects(for: self)
        onHoverChanged?(false)
        onEnded?()
    }
}
