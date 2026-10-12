import CoreGraphics
import Foundation

/// Platform-neutral role so elements can be compared across iOS, Android, and web.
enum ElementRole: String, CaseIterable, Sendable {
    case button
    case link
    case text
    case heading
    case textField
    case toggle
    case slider
    case image
    case picker
    case tab
    case cell
    case container
    case other

    var title: String {
        switch self {
        case .button: "Button"
        case .link: "Link"
        case .text: "Text"
        case .heading: "Heading"
        case .textField: "Text field"
        case .toggle: "Toggle"
        case .slider: "Slider"
        case .image: "Image"
        case .picker: "Picker"
        case .tab: "Tab"
        case .cell: "Cell"
        case .container: "Container"
        case .other: "Element"
        }
    }

    var systemImage: String {
        switch self {
        case .button: "button.horizontal"
        case .link: "link"
        case .text: "textformat"
        case .heading: "textformat.size"
        case .textField: "character.cursor.ibeam"
        case .toggle: "switch.2"
        case .slider: "slider.horizontal.3"
        case .image: "photo"
        case .picker: "filemenu.and.selection"
        case .tab: "menubar.rectangle"
        case .cell: "list.bullet.rectangle"
        case .container: "square.dashed"
        case .other: "square"
        }
    }

    /// Roles a user is expected to act on.
    var isInteractive: Bool {
        switch self {
        case .button, .link, .textField, .toggle, .slider, .picker, .tab: true
        case .text, .heading, .image, .cell, .container, .other: false
        }
    }
}

struct InspectedElement: Identifiable, Equatable, Sendable {
    let id: Int
    var role: ElementRole
    /// Platform class / role (`android.widget.Button`, `AXButton`, `button`).
    var platformRole: String
    /// Accessible name announced by VoiceOver / TalkBack / screen readers.
    var label: String?
    /// Visible text when it differs from the label.
    var text: String?
    /// Test hook: `resource-id`, `accessibilityIdentifier`, `id` / `data-testid`.
    var identifier: String?
    var value: String?
    /// Top-left normalized 0…1 rect in the pane's displayed frame.
    var frame: CGRect
    /// Size in platform units (pt, dp, or CSS px).
    var size: CGSize
    var isInteractive: Bool
    var isEnabled: Bool
    var depth: Int

    var displayName: String {
        for candidate in [label, text, identifier] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return role.title
    }

    var hasAccessibleName: Bool {
        [label, text].contains { !($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
    }
}

struct ElementSnapshot: Equatable, Sendable {
    let source: ViewerSource
    let elements: [InspectedElement]
    /// Screen (or web viewport) size in platform units.
    let screenSize: CGSize
    /// `pt`, `dp`, or `px`.
    let unit: String
    let capturedAt: Date

    func element(id: Int) -> InspectedElement? {
        elements.first { $0.id == id }
    }

    /// Smallest element containing `point`, preferring interactive elements of
    /// similar size so taps land on the control rather than its label.
    func hitTest(_ point: CGPoint) -> InspectedElement? {
        let containing = elements.filter { $0.frame.contains(point) && $0.frame.width < 1.0001 }
        guard let smallest = containing.min(by: { area($0) < area($1) }) else { return nil }
        let interactive = containing
            .filter { $0.isInteractive && area($0) <= area(smallest) * 4 }
            .min(by: { area($0) < area($1) })
        return interactive ?? smallest
    }

    /// Converts a normalized distance into platform units.
    func platformDistance(dx: CGFloat, dy: CGFloat) -> CGSize {
        CGSize(width: abs(dx) * screenSize.width, height: abs(dy) * screenSize.height)
    }

    private func area(_ element: InspectedElement) -> CGFloat {
        element.frame.width * element.frame.height
    }
}
