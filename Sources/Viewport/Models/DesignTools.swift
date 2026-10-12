import AppKit
import CoreGraphics
import Foundation

enum InspectorTab: String, CaseIterable, Identifiable {
    case elements
    case design
    case location
    case apps
    case network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .elements: "Elements"
        case .design: "Design"
        case .location: "Location"
        case .apps: "Apps"
        case .network: "Network"
        }
    }

    var systemImage: String {
        switch self {
        case .elements: "cursorarrow.and.square.on.square.dashed"
        case .design: "ruler"
        case .location: "location"
        case .apps: "app.badge"
        case .network: "network"
        }
    }
}

/// What a click in a pane does while the Design tab is open.
enum DesignTool: String, CaseIterable, Identifiable {
    case interact
    case measure
    case colorPicker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .interact: "Interact"
        case .measure: "Measure"
        case .colorPicker: "Colors"
        }
    }

    var systemImage: String {
        switch self {
        case .interact: "hand.point.up.left"
        case .measure: "ruler"
        case .colorPicker: "eyedropper"
        }
    }
}

enum DesignOverlayMode: String, CaseIterable, Identifiable {
    case overlay
    case difference
    case split

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overlay: "Overlay"
        case .difference: "Difference"
        case .split: "Split"
        }
    }
}

/// A design mock laid over one pane for pixel comparison.
struct DesignOverlay: Equatable {
    let url: URL
    let image: CGImage
    var opacity: Double = 0.5
    var mode: DesignOverlayMode = .overlay
    /// Fraction of the pane (from the left) that shows the design in split mode.
    var split: Double = 0.5
    var isVisible = true

    static func == (lhs: DesignOverlay, rhs: DesignOverlay) -> Bool {
        lhs.url == rhs.url
            && lhs.image === rhs.image
            && lhs.opacity == rhs.opacity
            && lhs.mode == rhs.mode
            && lhs.split == rhs.split
            && lhs.isVisible == rhs.isVisible
    }

    static func load(from url: URL) throws -> DesignOverlay {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw DesignOverlayError.unreadable
        }
        return DesignOverlay(url: url, image: image)
    }

    /// True when the mock's aspect is within 3% of the pane's.
    func matchesAspect(of size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0, image.height > 0 else { return false }
        let mock = Double(image.width) / Double(image.height)
        let pane = Double(size.width / size.height)
        return abs(mock - pane) / pane < 0.03
    }
}

enum DesignOverlayError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        "That file isn’t an image Viewport can read."
    }
}

struct GridSettings: Equatable {
    var isEnabled = false
    /// Baseline grid spacing in platform units (pt / dp / px).
    var spacing: Double = 8
    /// Layout columns; 0 hides them.
    var columns = 4
    var margin: Double = 16
    var gutter: Double = 16
}

/// Screen size of a pane in platform units, for grid and measurement maths.
struct PaneMetrics: Equatable {
    let screenSize: CGSize
    let unit: String

    func normalizedSpacing(_ value: Double) -> CGSize {
        CGSize(
            width: screenSize.width > 0 ? value / screenSize.width : 0,
            height: screenSize.height > 0 ? value / screenSize.height : 0
        )
    }

    func size(of normalized: CGSize) -> CGSize {
        CGSize(
            width: abs(normalized.width) * screenSize.width,
            height: abs(normalized.height) * screenSize.height
        )
    }

    /// Simulator pixels → points. iPhones are 3× (or 2× for SE-class), iPads 2×.
    static func estimatedIOSScale(pixelSize: CGSize) -> CGFloat {
        let shortSide = min(pixelSize.width, pixelSize.height)
        guard shortSide > 0 else { return 1 }
        let atThreeX = shortSide / 3
        return (320...450).contains(atThreeX) ? 3 : 2
    }

    static func estimated(for source: ViewerSource, pixelSize: CGSize, androidDensity: Double?) -> PaneMetrics {
        switch source {
        case .iOS:
            let scale = estimatedIOSScale(pixelSize: pixelSize)
            return PaneMetrics(
                screenSize: CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale),
                unit: "pt"
            )
        case .android:
            guard let androidDensity, androidDensity > 0 else {
                return PaneMetrics(screenSize: pixelSize, unit: "px")
            }
            let scale = androidDensity / 160
            return PaneMetrics(
                screenSize: CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale),
                unit: "dp"
            )
        case .web:
            return PaneMetrics(screenSize: pixelSize, unit: "px")
        }
    }
}

struct ColorSample: Equatable, Identifiable {
    let id = UUID()
    let source: ViewerSource
    let red: Int
    let green: Int
    let blue: Int

    var hex: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    var rgbText: String {
        "rgb(\(red), \(green), \(blue))"
    }

    var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        )
    }

    static func == (lhs: ColorSample, rhs: ColorSample) -> Bool {
        lhs.source == rhs.source && lhs.red == rhs.red
            && lhs.green == rhs.green && lhs.blue == rhs.blue
    }
}

/// Live measurement drawn in one pane (normalized, top-left origin).
struct PaneMeasurement: Equatable {
    let paneID: UUID
    var start: CGPoint
    var end: CGPoint

    var rect: CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }
}

/// Gaps between two element frames, in normalized units; nil when they overlap on that axis.
struct ElementSpacing: Equatable {
    var horizontal: CGFloat?
    var vertical: CGFloat?

    static func between(_ a: CGRect, _ b: CGRect) -> ElementSpacing {
        var spacing = ElementSpacing()
        if a.maxX <= b.minX {
            spacing.horizontal = b.minX - a.maxX
        } else if b.maxX <= a.minX {
            spacing.horizontal = a.minX - b.maxX
        }
        if a.maxY <= b.minY {
            spacing.vertical = b.minY - a.maxY
        } else if b.maxY <= a.minY {
            spacing.vertical = a.minY - b.maxY
        }
        return spacing
    }
}
