import CoreGraphics
import Foundation

enum AndroidUIHierarchyError: LocalizedError, Equatable {
    case noHierarchy
    case unreadable

    var errorDescription: String? {
        switch self {
        case .noHierarchy:
            "Android didn’t return a UI hierarchy. Unlock the device and try again."
        case .unreadable:
            "The Android UI hierarchy couldn’t be read."
        }
    }
}

/// Parses `uiautomator dump` XML into inspector elements.
enum AndroidUIHierarchyParser {
    /// Extracts the `<hierarchy>` document from `uiautomator dump /dev/tty`,
    /// which appends a status line after the XML.
    static func hierarchyXML(from output: String) -> String? {
        guard let start = output.range(of: "<?xml") ?? output.range(of: "<hierarchy") else {
            return nil
        }
        guard let end = output.range(of: "</hierarchy>", options: .backwards) else {
            return nil
        }
        return String(output[start.lowerBound..<end.upperBound])
    }

    /// `displaySize` is `wm size` in natural (rotation 0) pixels. Without it the
    /// top-level window bounds stand in for the screen, which is wrong when a
    /// dialog or other non-fullscreen window is in front.
    static func parse(
        _ xml: String,
        density: Double? = nil,
        displaySize: CGSize? = nil,
        capturedAt: Date = Date()
    ) throws -> ElementSnapshot {
        let delegate = UIHierarchyDelegate()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        guard parser.parse() else {
            throw AndroidUIHierarchyError.unreadable
        }
        guard let windowBounds = delegate.screenBounds,
              windowBounds.width > 0, windowBounds.height > 0 else {
            throw AndroidUIHierarchyError.noHierarchy
        }
        let screen = displaySize.flatMap { size -> CGRect? in
            guard size.width > 0, size.height > 0 else { return nil }
            // `wm size` ignores rotation; quarter turns swap the axes.
            return delegate.rotation % 2 == 0
                ? CGRect(origin: .zero, size: size)
                : CGRect(x: 0, y: 0, width: size.height, height: size.width)
        } ?? windowBounds
        let scale = max((density ?? 160) / 160, 0.1)
        var elements: [InspectedElement] = []
        for node in delegate.nodes {
            guard node.bounds.width > 0, node.bounds.height > 0,
                  node.isMeaningful else { continue }
            let frame = CGRect(
                x: (node.bounds.minX - screen.minX) / screen.width,
                y: (node.bounds.minY - screen.minY) / screen.height,
                width: node.bounds.width / screen.width,
                height: node.bounds.height / screen.height
            )
            let role = role(for: node)
            elements.append(
                InspectedElement(
                    id: elements.count,
                    role: role,
                    platformRole: node.className,
                    label: node.contentDescription,
                    text: node.text,
                    identifier: node.resourceID,
                    value: node.checkable ? (node.checked ? "On" : "Off") : nil,
                    frame: frame,
                    size: CGSize(
                        width: node.bounds.width / scale,
                        height: node.bounds.height / scale
                    ),
                    isInteractive: node.isInteractive || role.isInteractive,
                    isEnabled: node.enabled,
                    depth: node.depth
                )
            )
        }
        return ElementSnapshot(
            source: .android,
            elements: elements,
            screenSize: CGSize(width: screen.width / scale, height: screen.height / scale),
            unit: "dp",
            capturedAt: capturedAt
        )
    }

    /// `[x1,y1][x2,y2]` → rect in device pixels.
    static func parseBounds(_ value: String) -> CGRect? {
        let numbers = value
            .split(whereSeparator: { "[],".contains($0) })
            .compactMap { Double($0) }
        guard numbers.count == 4 else { return nil }
        return CGRect(
            x: numbers[0],
            y: numbers[1],
            width: numbers[2] - numbers[0],
            height: numbers[3] - numbers[1]
        )
    }

    /// `wm size` prints `Physical size: 1080x2400` and optionally `Override size: …`.
    static func parseDisplaySize(_ output: String) -> CGSize? {
        var physical: CGSize?
        var override: CGSize?
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let dimensions = parts[1].trimmingCharacters(in: .whitespaces)
                .split(separator: "x")
                .compactMap { Double($0) }
            guard dimensions.count == 2 else { continue }
            let size = CGSize(width: dimensions[0], height: dimensions[1])
            if parts[0].lowercased().contains("override") {
                override = size
            } else if parts[0].lowercased().contains("physical") {
                physical = size
            }
        }
        return override ?? physical
    }

    /// `wm density` prints `Physical density: 420` and optionally `Override density: 480`.
    static func parseDensity(_ output: String) -> Double? {
        var physical: Double?
        var override: Double?
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  let value = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            if parts[0].lowercased().contains("override") {
                override = value
            } else if parts[0].lowercased().contains("physical") {
                physical = value
            }
        }
        return override ?? physical
    }

    static func role(for node: UIHierarchyNode) -> ElementRole {
        let className = node.className.lowercased()
        let shortName = className.split(separator: ".").last.map(String.init) ?? className
        if shortName.contains("edittext") || shortName.contains("autocomplete") { return .textField }
        if shortName.contains("switch") || shortName.contains("checkbox")
            || shortName.contains("radiobutton") || shortName.contains("togglebutton")
            || (node.checkable && !shortName.contains("button")) {
            return .toggle
        }
        if shortName.contains("seekbar") || shortName.contains("slider") { return .slider }
        if shortName.contains("spinner") { return .picker }
        if shortName.contains("button") { return .button }
        if shortName.contains("imageview") || shortName == "image" { return .image }
        if shortName.contains("textview") || shortName == "text" {
            return node.clickable ? .button : .text
        }
        if node.clickable || node.longClickable { return .button }
        if node.text != nil { return .text }
        return node.contentDescription != nil ? .other : .container
    }
}

struct UIHierarchyNode: Equatable {
    var className = ""
    var text: String?
    var contentDescription: String?
    var resourceID: String?
    var bounds: CGRect = .zero
    var clickable = false
    var longClickable = false
    var checkable = false
    var checked = false
    var enabled = true
    var focusable = false
    var scrollable = false
    var depth = 0

    var isInteractive: Bool {
        clickable || longClickable || checkable
    }

    /// Skips anonymous layout containers so hit testing finds real content.
    var isMeaningful: Bool {
        isInteractive || text != nil || contentDescription != nil
            || className.lowercased().contains("image")
            || className.lowercased().contains("edittext")
    }
}

private final class UIHierarchyDelegate: NSObject, XMLParserDelegate {
    var nodes: [UIHierarchyNode] = []
    var screenBounds: CGRect?
    /// `<hierarchy rotation="…">`: 0–3 quarter turns from the natural orientation.
    var rotation = 0
    private var depth = 0

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "hierarchy" {
            rotation = attributeDict["rotation"].flatMap(Int.init) ?? 0
            return
        }
        guard elementName == "node" else { return }
        depth += 1
        var node = UIHierarchyNode()
        node.className = attributeDict["class"] ?? ""
        node.text = Self.nonEmpty(attributeDict["text"])
        node.contentDescription = Self.nonEmpty(attributeDict["content-desc"])
        node.resourceID = Self.nonEmpty(attributeDict["resource-id"])
        node.bounds = attributeDict["bounds"].flatMap(AndroidUIHierarchyParser.parseBounds) ?? .zero
        node.clickable = attributeDict["clickable"] == "true"
        node.longClickable = attributeDict["long-clickable"] == "true"
        node.checkable = attributeDict["checkable"] == "true"
        node.checked = attributeDict["checked"] == "true"
        node.enabled = attributeDict["enabled"] != "false"
        node.focusable = attributeDict["focusable"] == "true"
        node.scrollable = attributeDict["scrollable"] == "true"
        node.depth = depth - 1
        if depth == 1 {
            // The first top-level node spans the display in the current rotation.
            screenBounds = screenBounds.map { $0.union(node.bounds) } ?? node.bounds
        }
        nodes.append(node)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "node" {
            depth -= 1
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
