import CoreGraphics
import Foundation
import IndigoTouch

enum ElementSnapshotError: LocalizedError, Equatable {
    case unsupported(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .unsupported(message), let .failed(message):
            message
        }
    }
}

/// Element trees for the inspector: `uiautomator` on Android, the
/// accessibility translator on Simulator.
actor ElementSnapshotService {
    private let shell: DeviceCommandShell
    private var androidDensityCache: [String: Double] = [:]
    private var androidDisplaySizeCache: [String: CGSize] = [:]

    init(shell: DeviceCommandShell = DeviceCommandShell()) {
        self.shell = shell
    }

    func snapshot(of device: StreamedDevice) async throws -> ElementSnapshot {
        switch device.kind {
        case .androidEmulator, .androidDevice:
            return try await androidSnapshot(serial: device.id)
        case .iOSSimulator:
            return try await Self.simulatorSnapshot(udid: device.id)
        case .iOSDevice:
            throw ElementSnapshotError.unsupported(
                "Physical iPhones are view-only; inspect a Simulator instead."
            )
        }
    }

    func androidDensity(for device: StreamedDevice) async -> Double? {
        guard device.source == .android else { return nil }
        return try? await androidDensity(serial: device.id)
    }

    private func androidSnapshot(serial: String) async throws -> ElementSnapshot {
        let density = try await androidDensity(serial: serial)
        let displaySize = await androidDisplaySize(serial: serial)
        let dumped = try await shell.adbData(
            serial: serial,
            ["exec-out", "uiautomator", "dump", "/dev/tty"],
            label: "Read Android UI"
        )
        if let xml = AndroidUIHierarchyParser.hierarchyXML(
            from: String(decoding: dumped, as: UTF8.self)
        ) {
            return try AndroidUIHierarchyParser.parse(
                xml,
                density: density,
                displaySize: displaySize
            )
        }
        // Some images refuse /dev/tty; dump to a file and read it back.
        let path = "/sdcard/viewport-ui-dump.xml"
        try await shell.adb(
            serial: serial,
            ["shell", "uiautomator", "dump", path],
            label: "Read Android UI",
            timeout: 20
        )
        let file = try await shell.adbData(
            serial: serial,
            ["exec-out", "cat", path],
            label: "Read Android UI"
        )
        _ = try? await shell.adbAllowingFailure(serial: serial, ["shell", "rm", "-f", path])
        guard let xml = AndroidUIHierarchyParser.hierarchyXML(
            from: String(decoding: file, as: UTF8.self)
        ) else {
            throw AndroidUIHierarchyError.noHierarchy
        }
        return try AndroidUIHierarchyParser.parse(
            xml,
            density: density,
            displaySize: displaySize
        )
    }

    private func androidDensity(serial: String) async throws -> Double? {
        if let cached = androidDensityCache[serial] { return cached }
        let result = try? await shell.adb(
            serial: serial,
            ["shell", "wm", "density"],
            label: "Read density"
        )
        guard let density = result.flatMap({
            AndroidUIHierarchyParser.parseDensity($0.standardOutput)
        }) else {
            return nil
        }
        androidDensityCache[serial] = density
        return density
    }

    private func androidDisplaySize(serial: String) async -> CGSize? {
        if let cached = androidDisplaySizeCache[serial] { return cached }
        let result = try? await shell.adb(
            serial: serial,
            ["shell", "wm", "size"],
            label: "Read display size"
        )
        guard let size = result.flatMap({
            AndroidUIHierarchyParser.parseDisplaySize($0.standardOutput)
        }) else {
            return nil
        }
        androidDisplaySizeCache[serial] = size
        return size
    }

    private static func simulatorSnapshot(udid: String) async throws -> ElementSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = [CChar](repeating: 0, count: 512)
                let raw = buffer.withUnsafeMutableBufferPointer { pointer in
                    ViewportAccessibilitySnapshot(
                        udid,
                        8,
                        2_000,
                        pointer.baseAddress!,
                        pointer.count
                    )
                }
                guard let raw else {
                    let message = String(cString: buffer)
                    continuation.resume(throwing: ElementSnapshotError.failed(
                        message.isEmpty ? "The Simulator accessibility tree is unavailable." : message
                    ))
                    return
                }
                continuation.resume(returning: IOSAccessibilityMapper.snapshot(from: raw))
            }
        }
    }
}

/// Maps translator dictionaries (see `ViewportSimulatorAccessibility.h`).
enum IOSAccessibilityMapper {
    static func snapshot(
        from entries: [[String: Any]],
        capturedAt: Date = Date()
    ) -> ElementSnapshot {
        guard let root = entries.first,
              let rootFrame = frame(of: root),
              rootFrame.width > 0, rootFrame.height > 0 else {
            return ElementSnapshot(
                source: .iOS,
                elements: [],
                screenSize: .zero,
                unit: "pt",
                capturedAt: capturedAt
            )
        }
        var elements: [InspectedElement] = []
        for entry in entries.dropFirst() {
            guard let frame = frame(of: entry), frame.width > 0, frame.height > 0 else { continue }
            let axRole = entry[ViewportAXRoleKey] as? String ?? ""
            let subrole = entry[ViewportAXSubroleKey] as? String
            let role = role(for: axRole, subrole: subrole)
            let label = entry[ViewportAXLabelKey] as? String
            let title = entry[ViewportAXTitleKey] as? String
            let value = entry[ViewportAXValueKey] as? String
            // Skip anonymous groups; they swallow hits meant for their children.
            if role == .container, label == nil, title == nil,
               entry[ViewportAXIdentifierKey] == nil {
                continue
            }
            elements.append(
                InspectedElement(
                    id: elements.count,
                    role: role,
                    platformRole: subrole.map { "\(axRole) (\($0))" } ?? axRole,
                    label: label ?? title,
                    text: role == .text || role == .heading ? nil : title.flatMap { $0 == label ? nil : $0 },
                    identifier: (entry[ViewportAXIdentifierKey] as? String).flatMap {
                        // UIKit falls back to the label; only show real identifiers.
                        $0 == label ? nil : $0
                    },
                    value: value,
                    frame: CGRect(
                        x: (frame.minX - rootFrame.minX) / rootFrame.width,
                        y: (frame.minY - rootFrame.minY) / rootFrame.height,
                        width: frame.width / rootFrame.width,
                        height: frame.height / rootFrame.height
                    ),
                    size: frame.size,
                    isInteractive: role.isInteractive,
                    isEnabled: entry[ViewportAXEnabledKey] as? Bool ?? true,
                    depth: entry[ViewportAXDepthKey] as? Int ?? 0
                )
            )
        }
        return ElementSnapshot(
            source: .iOS,
            elements: elements,
            screenSize: rootFrame.size,
            unit: "pt",
            capturedAt: capturedAt
        )
    }

    static func role(for axRole: String, subrole: String?) -> ElementRole {
        switch axRole {
        case "AXButton", "AXMenuButton", "AXPopUpButton", "AXMenuItem", "AXIncrementor":
            return subrole == "AXTabButton" ? .tab : .button
        case "AXLink": return .link
        case "AXStaticText": return .text
        case "AXHeading": return .heading
        case "AXTextField", "AXSecureTextField", "AXTextArea", "AXSearchField", "AXComboBox":
            return .textField
        case "AXCheckBox", "AXSwitch", "AXRadioButton", "AXToggle": return .toggle
        case "AXSlider", "AXValueIndicator": return .slider
        case "AXImage": return .image
        case "AXPicker", "AXPickerWheel": return .picker
        case "AXTab", "AXTabButton": return .tab
        case "AXCell", "AXRow": return .cell
        case "AXGroup", "AXScrollArea", "AXList", "AXTable", "AXOutline", "AXWindow",
             "AXCollectionView", "AXToolbar", "AXTabGroup", "AXLayoutArea", "AXSplitGroup":
            return .container
        default:
            return .other
        }
    }

    private static func frame(of entry: [String: Any]) -> CGRect? {
        if let value = entry[ViewportAXFrameKey] as? NSValue {
            return value.rectValue
        }
        return nil
    }
}
