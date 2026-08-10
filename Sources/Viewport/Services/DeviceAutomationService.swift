import AppKit
import Foundation

enum DeviceAppearance: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum DeviceOrientation: String, CaseIterable, Identifiable {
    case portrait
    case landscape

    var id: String { rawValue }

    var title: String {
        switch self {
        case .portrait: "Portrait"
        case .landscape: "Landscape"
        }
    }

    /// Android `settings put system user_rotation` value (0 = portrait, 1 = landscape).
    var androidUserRotation: String {
        switch self {
        case .portrait: "0"
        case .landscape: "1"
        }
    }
}

enum DeviceFontScale: String, CaseIterable, Identifiable {
    case small
    case defaultScale
    case large
    case extraLarge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: "Small"
        case .defaultScale: "Default"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }

    /// Android `settings put system font_scale` value.
    var androidValue: String {
        switch self {
        case .small: "0.85"
        case .defaultScale: "1.0"
        case .large: "1.15"
        case .extraLarge: "1.3"
        }
    }
}

enum DeviceAutomationError: LocalizedError {
    case noTarget(String = "No device is selected in that pane.")
    case unsupported(String)
    case commandFailed(String)
    /// iOS Simulator menu automation needs Privacy → Accessibility for Viewport.
    case accessibilityRequired(String)

    var errorDescription: String? {
        switch self {
        case let .noTarget(message):
            message
        case let .unsupported(message):
            message
        case let .commandFailed(message):
            message
        case let .accessibilityRequired(message):
            message
        }
    }

    var isAccessibilityRequired: Bool {
        if case .accessibilityRequired = self {
            return true
        }
        return false
    }
}

struct DeviceInjectionTargets: OptionSet, Sendable {
    let rawValue: Int

    static let android = DeviceInjectionTargets(rawValue: 1 << 0)
    static let iOS = DeviceInjectionTargets(rawValue: 1 << 1)
    static let both: DeviceInjectionTargets = [.android, .iOS]
}

struct DeviceInjectionResult: Sendable, Equatable {
    var succeeded: [String] = []
    var skipped: [String] = []

    func summary(verb: String) -> String {
        var parts: [String] = []
        if !succeeded.isEmpty {
            parts.append("\(verb) on \(succeeded.joined(separator: ", "))")
        }
        if !skipped.isEmpty {
            parts.append(skipped.joined(separator: " · "))
        }
        if parts.isEmpty {
            return "Nothing to do."
        }
        return parts.joined(separator: ". ")
    }

    var didSucceed: Bool { !succeeded.isEmpty }
}

/// Cross-device helpers for compare workflows: open URL, appearance,
/// font scale, and clean status bars.
actor DeviceAutomationService {
    private let runner: CommandRunner
    private let adb: URL?
    private let toolchains: ToolchainLocator
    private let developerEnvironment: [String: String]

    init(
        runner: CommandRunner = CommandRunner(),
        toolchains: ToolchainLocator = ToolchainLocator()
    ) {
        self.runner = runner
        adb = toolchains.adb
        self.toolchains = toolchains
        developerEnvironment = toolchains.developerEnvironment
    }

    func openURL(_ rawURL: String, on device: StreamedDevice) async throws {
        let url = Self.normalizedURL(rawURL)
        guard let url else {
            throw DeviceAutomationError.commandFailed("Enter a valid URL.")
        }

        switch device.kind {
        case .androidEmulator, .androidDevice:
            try await runADB(
                serial: device.id,
                arguments: [
                    "shell", "am", "start",
                    "-a", "android.intent.action.VIEW",
                    "-d", url
                ],
                label: "Open URL"
            )
        case .iOSSimulator:
            try await runXcrun(
                arguments: ["simctl", "openurl", device.id, url],
                label: "Open URL"
            )
        case .iOSDevice:
            throw DeviceAutomationError.unsupported(
                "Deep links on physical iPhones need a signed app that handles the URL. Use Simulator for open-URL compares."
            )
        }
    }

    func setAppearance(
        _ appearance: DeviceAppearance,
        on device: StreamedDevice
    ) async throws {
        switch device.kind {
        case .androidEmulator, .androidDevice:
            try await runADB(
                serial: device.id,
                arguments: [
                    "shell", "cmd", "uimode", "night",
                    appearance == .dark ? "yes" : "no"
                ],
                label: "Set appearance"
            )
        case .iOSSimulator:
            try await runXcrun(
                arguments: [
                    "simctl", "ui", device.id, "appearance", appearance.rawValue
                ],
                label: "Set appearance"
            )
        case .iOSDevice:
            throw DeviceAutomationError.unsupported(
                "Appearance can be toggled on Simulator and Android. Change it in Settings on a physical iPhone."
            )
        }
    }

    func setFontScale(
        _ scale: DeviceFontScale,
        on device: StreamedDevice
    ) async throws {
        switch device.kind {
        case .androidEmulator, .androidDevice:
            try await runADB(
                serial: device.id,
                arguments: [
                    "shell", "settings", "put", "system", "font_scale",
                    scale.androidValue
                ],
                label: "Set font scale"
            )
        case .iOSSimulator, .iOSDevice:
            throw DeviceAutomationError.unsupported(
                "Font scale is Android-only for now. Use Settings ▸ Display on iOS."
            )
        }
    }

    func applyCleanStatusBar(on device: StreamedDevice) async throws {
        switch device.kind {
        case .androidEmulator, .androidDevice:
            try await runADB(
                serial: device.id,
                arguments: [
                    "shell", "settings", "put", "global",
                    "sysui_demo_allowed", "1"
                ],
                label: "Enable demo mode"
            )
            for args in Self.androidDemoModeCommands {
                try await runADB(
                    serial: device.id,
                    arguments: args,
                    label: "Demo mode"
                )
            }
        case .iOSSimulator:
            try await runXcrun(
                arguments: [
                    "simctl", "status_bar", device.id, "override",
                    "--time", "9:41",
                    "--dataNetwork", "wifi",
                    "--wifiMode", "active",
                    "--wifiBars", "3",
                    "--cellularMode", "active",
                    "--cellularBars", "4",
                    "--batteryState", "charged",
                    "--batteryLevel", "100"
                ],
                label: "Status bar"
            )
        case .iOSDevice:
            throw DeviceAutomationError.unsupported(
                "Clean status bars work on Simulator and Android. Physical iPhones need Control Center / Focus tricks."
            )
        }
    }

    func clearStatusBar(on device: StreamedDevice) async throws {
        switch device.kind {
        case .androidEmulator, .androidDevice:
            try await runADB(
                serial: device.id,
                arguments: [
                    "shell", "am", "broadcast",
                    "-a", "com.android.systemui.demo",
                    "-e", "command", "exit"
                ],
                label: "Exit demo mode"
            )
        case .iOSSimulator:
            try await runXcrun(
                arguments: ["simctl", "status_bar", device.id, "clear"],
                label: "Clear status bar"
            )
        case .iOSDevice:
            throw DeviceAutomationError.unsupported(
                "Status bar overrides are Simulator / Android only."
            )
        }
    }

    func setOrientation(
        _ orientation: DeviceOrientation,
        on device: StreamedDevice
    ) async throws {
        switch device.kind {
        case .androidEmulator, .androidDevice:
            try await runADB(
                serial: device.id,
                arguments: [
                    "shell", "settings", "put", "system",
                    "accelerometer_rotation", "0"
                ],
                label: "Lock rotation"
            )
            try await runADB(
                serial: device.id,
                arguments: [
                    "shell", "settings", "put", "system",
                    "user_rotation", orientation.androidUserRotation
                ],
                label: "Set orientation"
            )
        case .iOSSimulator:
            try await setIOSSimulatorOrientation(orientation, device: device)
        case .iOSDevice:
            throw DeviceAutomationError.unsupported(
                "Orientation control works on Simulator and Android only."
            )
        }
    }

    func rotateClockwise(on device: StreamedDevice) async throws {
        switch device.kind {
        case .androidEmulator, .androidDevice:
            try await runADB(
                serial: device.id,
                arguments: ["shell", "settings", "put", "system", "accelerometer_rotation", "0"],
                label: "Lock rotation"
            )
            let current = try await androidUserRotation(serial: device.id)
            let next = (current + 1) % 4
            try await runADB(
                serial: device.id,
                arguments: [
                    "shell", "settings", "put", "system",
                    "user_rotation", String(next)
                ],
                label: "Rotate"
            )
        case .iOSSimulator:
            try await ensureSimulatorAccessibility()
            try await runIOSSimulatorRotateLeft(device: device)
        case .iOSDevice:
            throw DeviceAutomationError.unsupported(
                "Rotation works on Simulator and Android only."
            )
        }
    }

    /// Home button / home gesture for the selected guest.
    func pressHome(on device: StreamedDevice) async throws {
        switch device.kind {
        case .androidEmulator, .androidDevice:
            try await runADB(
                serial: device.id,
                arguments: ["shell", "input", "keyevent", "KEYCODE_HOME"],
                label: "Home"
            )
        case .iOSSimulator:
            // Prefer the hardware Home HID button — more reliable than a
            // home-indicator swipe on Xcode 26 (mouse HID rate-limits moves).
            try await sendIOSHome(udid: device.id)
        case .iOSDevice:
            throw DeviceAutomationError.unsupported(
                "Home works on Simulator and Android only. Use the device Home gesture."
            )
        }
    }

    /// Android system Back, or iOS interactive-pop edge swipe.
    func pressBack(on device: StreamedDevice) async throws {
        switch device.kind {
        case .androidEmulator, .androidDevice:
            try await runADB(
                serial: device.id,
                arguments: ["shell", "input", "keyevent", "KEYCODE_BACK"],
                label: "Back"
            )
        case .iOSSimulator:
            try await sendIOSSwipe(
                udid: device.id,
                from: Self.iosBackGesture.from,
                to: Self.iosBackGesture.to,
                duration: Self.iosBackGesture.duration,
                label: "Back"
            )
        case .iOSDevice:
            throw DeviceAutomationError.unsupported(
                "Back works on Simulator and Android only. Swipe from the left edge on device."
            )
        }
    }

    /// Normalized framebuffer gestures for iOS system navigation.
    nonisolated static let iosHomeGesture = (
        from: CGPoint(x: 0.5, y: 0.995),
        to: CGPoint(x: 0.5, y: 0.15),
        duration: 0.36
    )
    nonisolated static let iosBackGesture = (
        from: CGPoint(x: 0.02, y: 0.5),
        to: CGPoint(x: 0.75, y: 0.5),
        duration: 0.35
    )

    /// Stops the guest shown in a pane (headless/windowed AVD or Simulator).
    /// Physical devices are left alone — only the live view is closed by the caller.
    func terminateGuest(_ device: StreamedDevice) async throws {
        switch device.kind {
        case .androidEmulator:
            try await runADB(
                serial: device.id,
                arguments: ["emu", "kill"],
                label: "Stop emulator"
            )
        case .iOSSimulator:
            try await runXcrun(
                arguments: ["simctl", "shutdown", device.id],
                label: "Shut down Simulator"
            )
        case .androidDevice, .iOSDevice:
            return
        }
    }

    nonisolated static func normalizedURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") { return trimmed }
        if trimmed.contains(".") || trimmed.hasPrefix("localhost") {
            return "https://\(trimmed)"
        }
        // Custom schemes like myapp://path
        return trimmed
    }

    private static let androidDemoModeCommands: [[String]] = [
        [
            "shell", "am", "broadcast",
            "-a", "com.android.systemui.demo",
            "-e", "command", "enter"
        ],
        [
            "shell", "am", "broadcast",
            "-a", "com.android.systemui.demo",
            "-e", "command", "clock",
            "-e", "hhmm", "0941"
        ],
        [
            "shell", "am", "broadcast",
            "-a", "com.android.systemui.demo",
            "-e", "command", "network",
            "-e", "wifi", "show",
            "-e", "level", "4"
        ],
        [
            "shell", "am", "broadcast",
            "-a", "com.android.systemui.demo",
            "-e", "command", "battery",
            "-e", "level", "100",
            "-e", "plugged", "false"
        ],
        [
            "shell", "am", "broadcast",
            "-a", "com.android.systemui.demo",
            "-e", "command", "notifications",
            "-e", "visible", "false"
        ]
    ]

    private func runADB(
        serial: String,
        arguments: [String],
        label: String
    ) async throws {
        guard let adb else {
            throw DeviceAutomationError.commandFailed("adb is not available.")
        }
        let result = try await runner.run(
            executable: adb,
            arguments: ["-s", serial] + arguments,
            timeout: 12
        )
        guard result.exitCode == 0 else {
            throw DeviceAutomationError.commandFailed(
                Self.cleanMessage(
                    stdout: result.standardOutput,
                    stderr: result.standardError,
                    fallback: "\(label) failed."
                )
            )
        }
    }

    private func runXcrun(
        arguments: [String],
        standardInput: Data? = nil,
        label: String
    ) async throws {
        let invocation = simctlInvocation(for: arguments)
        let result = try await runner.run(
            executable: invocation.executable,
            arguments: invocation.arguments,
            environment: developerEnvironment,
            standardInput: standardInput,
            timeout: 12
        )
        guard result.exitCode == 0 else {
            throw DeviceAutomationError.commandFailed(
                Self.cleanMessage(
                    stdout: result.standardOutput,
                    stderr: result.standardError,
                    fallback: "\(label) failed."
                )
            )
        }
    }

    private func simctlInvocation(for arguments: [String]) -> SimctlCommand {
        if arguments.first == "simctl" {
            return toolchains.simctlCommand(Array(arguments.dropFirst()))
        }
        return SimctlCommand(executable: toolchains.xcrun, arguments: arguments)
    }

    private func androidUserRotation(serial: String) async throws -> Int {
        guard let adb else {
            throw DeviceAutomationError.commandFailed("adb is not available.")
        }
        let result = try await runner.run(
            executable: adb,
            arguments: [
                "-s", serial, "shell", "settings", "get", "system", "user_rotation"
            ],
            timeout: 12
        )
        return Int(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? 0
    }

    private func setIOSSimulatorOrientation(
        _ orientation: DeviceOrientation,
        device: StreamedDevice
    ) async throws {
        try await ensureSimulatorAccessibility()
        let wantLandscape = orientation == .landscape
        // Portrait vs landscape is an aspect check; one rotate flips between them
        // (including upside-down / opposite-landscape variants).
        guard let isLandscape = try await iosSimulatorWindowIsLandscape(device: device) else {
            // Can't read window size (Accessibility / missing window). Only best-effort
            // rotate when landscape is requested so we don't flip an already-portrait sim.
            if wantLandscape {
                try await runIOSSimulatorRotateLeft(device: device)
            }
            return
        }
        if isLandscape == wantLandscape {
            return
        }
        try await runIOSSimulatorRotateLeft(device: device)
    }

    private func ensureSimulatorAccessibility() async throws {
        let trusted = await MainActor.run {
            AccessibilityPermission.requestTrustIfNeeded()
        }
        guard trusted else {
            await MainActor.run {
                AccessibilityPermission.openSystemSettings()
            }
            throw DeviceAutomationError.accessibilityRequired(
                "Allow Viewport in System Settings → Privacy & Security → Accessibility, then try Rotate again."
            )
        }
    }

    private func runIOSSimulatorRotateLeft(device: StreamedDevice) async throws {
        let escapedName = Self.appleScriptEscaped(device.name)
        try await runAppleScript(
            """
            tell application "Simulator" to activate
            delay 0.05
            tell application "System Events"
                tell process "Simulator"
                    set frontmost to true
                    \(Self.appleScriptRaiseSimulatorWindow(escapedName: escapedName))
                    click menu item "Rotate Left" of menu "Device" of menu bar 1
                end tell
            end tell
            """,
            label: "Rotate Simulator"
        )
    }

    /// Injects a timed HID swipe on a booted Simulator (framebuffer-normalized).
    @MainActor
    private func sendIOSSwipe(
        udid: String,
        from start: CGPoint,
        to end: CGPoint,
        duration: TimeInterval,
        label: String
    ) async throws {
        let input = IOSSimulatorHIDInput()
        guard input.isAvailable else {
            throw DeviceAutomationError.unsupported(
                "SimulatorKit is unavailable for \(label.lowercased())."
            )
        }

        // Instant down/move/up in one runloop tick is treated as a tap by iOS.
        let succeeded = await input.swipe(
            from: start,
            to: end,
            duration: duration,
            udid: udid
        )
        let detail = input.lastErrorMessage
        input.reset()

        guard succeeded else {
            throw DeviceAutomationError.commandFailed(
                detail.map { "\(label) failed to inject a Simulator HID gesture (\($0))." }
                    ?? "\(label) failed to inject a Simulator HID gesture."
            )
        }
    }

    /// Hardware Home button, with home-indicator swipe as fallback.
    @MainActor
    private func sendIOSHome(udid: String) async throws {
        let input = IOSSimulatorHIDInput()
        guard input.isAvailable else {
            throw DeviceAutomationError.unsupported(
                "SimulatorKit is unavailable for home."
            )
        }

        if await input.pressHomeButton(udid: udid) {
            input.reset()
            return
        }

        let buttonError = input.lastErrorMessage
        input.reset()
        let swipeOK = await input.swipe(
            from: Self.iosHomeGesture.from,
            to: Self.iosHomeGesture.to,
            duration: Self.iosHomeGesture.duration,
            udid: udid
        )
        let swipeError = input.lastErrorMessage
        input.reset()

        guard swipeOK else {
            let detail = [buttonError, swipeError]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " — ")
            throw DeviceAutomationError.commandFailed(
                detail.isEmpty
                    ? "Home failed to inject a Simulator HID gesture."
                    : "Home failed to inject a Simulator HID gesture (\(detail))."
            )
        }
    }

    /// Returns whether the Simulator window for `device` is currently landscape-shaped.
    private func iosSimulatorWindowIsLandscape(device: StreamedDevice) async throws -> Bool? {
        let escapedName = Self.appleScriptEscaped(device.name)
        let output = try await runAppleScript(
            """
            tell application "System Events"
                tell process "Simulator"
                    \(Self.appleScriptResolveSimulatorWindow(escapedName: escapedName))
                    if targetWindow is missing value then return ""
                    set windowSize to size of targetWindow
                    return ((item 1 of windowSize) as text) & "," & ((item 2 of windowSize) as text)
                end tell
            end tell
            """,
            label: "Query Simulator orientation"
        )
        let parts = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return nil }
        return parts[0] > parts[1]
    }

    /// Runs AppleScript in-process so Accessibility trust attaches to Viewport,
    /// not a detached `/usr/bin/osascript` helper that never shows in the list.
    @discardableResult
    private func runAppleScript(_ script: String, label: String) async throws -> String {
        let outcome: (Bool, String) = await MainActor.run {
            let appleScript = NSAppleScript(source: script)
            var errorInfo: NSDictionary?
            let result = appleScript?.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let message = [
                    errorInfo[NSAppleScript.errorMessage] as? String,
                    errorInfo[NSAppleScript.errorBriefMessage] as? String
                ]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
                return (false, message ?? "\(label) failed.")
            }
            let output = result?.stringValue ?? ""
            return (true, output)
        }

        guard outcome.0 else {
            if !AccessibilityPermission.isTrusted {
                throw DeviceAutomationError.accessibilityRequired(
                    "Allow Viewport in System Settings → Privacy & Security → Accessibility, then try Rotate again."
                )
            }
            throw DeviceAutomationError.commandFailed(
                Self.cleanMessage(
                    stdout: "",
                    stderr: outcome.1,
                    fallback: "\(label) failed. Ensure Simulator is running and Accessibility is allowed for Viewport."
                )
            )
        }
        return outcome.1
    }

    nonisolated static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Raises the Simulator window matching `escapedName`, falling back to the
    /// frontmost Simulator window when title suffixes prevent an exact match.
    nonisolated static func appleScriptRaiseSimulatorWindow(escapedName: String) -> String {
        """
        set matchedWindows to (every window whose name contains "\(escapedName)")
        if (count of matchedWindows) > 0 then
            perform action "AXRaise" of item 1 of matchedWindows
            delay 0.05
        else if (count of windows) > 0 then
            perform action "AXRaise" of front window
            delay 0.05
        end if
        """
    }

    /// Resolves `targetWindow` by device name, then frontmost Simulator window.
    nonisolated static func appleScriptResolveSimulatorWindow(escapedName: String) -> String {
        """
        set targetWindow to missing value
        set matchedWindows to (every window whose name contains "\(escapedName)")
        if (count of matchedWindows) > 0 then
            set targetWindow to item 1 of matchedWindows
        else if (count of windows) > 0 then
            set targetWindow to front window
        end if
        """
    }

    nonisolated static func cleanMessage(
        stdout: String,
        stderr: String,
        fallback: String
    ) -> String {
        let lines = [stderr, stdout]
            .flatMap { $0.split(whereSeparator: \.isNewline) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.last.map { String($0) } ?? fallback
    }
}
