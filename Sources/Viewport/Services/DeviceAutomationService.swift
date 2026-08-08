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

    var errorDescription: String? {
        switch self {
        case let .noTarget(message):
            message
        case let .unsupported(message):
            message
        case let .commandFailed(message):
            message
        }
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

/// Cross-device helpers for compare workflows: open URL, push, appearance,
/// font scale, and clean status bars.
actor DeviceAutomationService {
    private let runner: CommandRunner
    private let adb: URL?
    private let xcrun: URL
    private let developerEnvironment: [String: String]

    init(
        runner: CommandRunner = CommandRunner(),
        toolchains: ToolchainLocator = ToolchainLocator()
    ) {
        self.runner = runner
        adb = toolchains.adb
        xcrun = toolchains.xcrun
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

    /// Sends a simulated remote push to an iOS Simulator via `simctl push`.
    func sendPush(
        payloadJSON: String,
        bundleID: String,
        on device: StreamedDevice
    ) async throws {
        let trimmedBundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBundle.isEmpty else {
            throw DeviceAutomationError.commandFailed("Enter an app bundle ID.")
        }
        let payload = try Self.validatedAPNsPayloadData(payloadJSON)

        switch device.kind {
        case .iOSSimulator:
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("viewport-push-\(UUID().uuidString).apns")
            try payload.write(to: fileURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: fileURL) }
            try await runXcrun(
                arguments: [
                    "simctl", "push", device.id, trimmedBundle, fileURL.path
                ],
                label: "Push notification"
            )
        case .iOSDevice:
            throw DeviceAutomationError.unsupported(
                "Push injection works on iOS Simulator only. Physical iPhones need real APNs."
            )
        case .androidEmulator, .androidDevice:
            throw DeviceAutomationError.unsupported(
                "Use Post local notification for Android. Simulator push is iOS-only."
            )
        }
    }

    /// Posts a local system notification on Android (not FCM).
    func postLocalNotification(
        title: String,
        body: String,
        tag: String,
        on device: StreamedDevice
    ) async throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw DeviceAutomationError.commandFailed("Enter a notification title.")
        }
        guard !trimmedBody.isEmpty else {
            throw DeviceAutomationError.commandFailed("Enter notification text.")
        }
        let resolvedTag = trimmedTag.isEmpty ? "viewport" : trimmedTag

        switch device.kind {
        case .androidEmulator, .androidDevice:
            // Quote for the device shell so spaces and punctuation survive.
            let shell = [
                "cmd", "notification", "post",
                "-t", Self.shellSingleQuoted(trimmedTitle),
                Self.shellSingleQuoted(resolvedTag),
                Self.shellSingleQuoted(trimmedBody)
            ].joined(separator: " ")
            try await runADB(
                serial: device.id,
                arguments: ["shell", shell],
                label: "Post notification"
            )
        case .iOSSimulator, .iOSDevice:
            throw DeviceAutomationError.unsupported(
                "Local notification posting is Android-only. Use Send push on iOS Simulator."
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

    nonisolated static let defaultAPNsPayloadJSON = """
        {
          "aps": {
            "alert": { "title": "Viewport", "body": "Test notification" },
            "sound": "default",
            "badge": 1
          }
        }
        """

    nonisolated static let silentAPNsPayloadJSON = """
        {
          "aps": {
            "content-available": 1
          }
        }
        """

    nonisolated static let customDataAPNsPayloadJSON = """
        {
          "aps": {
            "alert": { "title": "Viewport", "body": "Open a deep link" },
            "sound": "default"
          },
          "deepLink": "myapp://home"
        }
        """

    /// Validates APNs JSON and returns UTF-8 data for `simctl push`.
    nonisolated static func validatedAPNsPayloadData(_ json: String) throws -> Data {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DeviceAutomationError.commandFailed("Enter an APNs JSON payload.")
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw DeviceAutomationError.commandFailed("APNs payload must be UTF-8 JSON.")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw DeviceAutomationError.commandFailed(
                "APNs payload is not valid JSON."
            )
        }
        guard let dictionary = object as? [String: Any],
              dictionary["aps"] != nil else {
            throw DeviceAutomationError.commandFailed(
                "APNs payload must be an object with a top-level \"aps\" key."
            )
        }
        guard data.count <= 4096 else {
            throw DeviceAutomationError.commandFailed(
                "APNs payload must be 4096 bytes or less."
            )
        }
        return data
    }

    nonisolated static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
        label: String
    ) async throws {
        let result = try await runner.run(
            executable: xcrun,
            arguments: arguments,
            environment: developerEnvironment,
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
