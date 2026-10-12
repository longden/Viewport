import Foundation

/// App permissions, push notifications, and installed-app lookup.
actor AppEnvironmentService {
    private let shell: DeviceCommandShell

    init(shell: DeviceCommandShell = DeviceCommandShell()) {
        self.shell = shell
    }

    func installedApps(on device: StreamedDevice) async throws -> [InstalledApp] {
        switch device.kind {
        case .iOSSimulator:
            let result = try await shell.simctl(
                ["listapps", device.id],
                label: "List apps"
            )
            return InstalledAppParser.parseSimulatorApps(result.standardOutput)
        case .androidEmulator, .androidDevice:
            let result = try await shell.adb(
                serial: device.id,
                ["shell", "pm", "list", "packages", "-3"],
                label: "List packages"
            )
            return InstalledAppParser.parseAndroidPackages(result.standardOutput)
        case .iOSDevice:
            return []
        }
    }

    func apply(
        _ action: PermissionAction,
        _ permission: AppPermission,
        appID: String,
        on device: StreamedDevice
    ) async throws {
        try Self.requireIdentifier(appID)
        switch device.kind {
        case .iOSSimulator:
            guard let service = permission.simctlService else {
                throw DeviceAutomationError.unsupported(
                    "\(permission.title) can’t be set on Simulator."
                )
            }
            try await shell.simctl(
                Self.simctlPrivacyArguments(
                    udid: device.id,
                    action: action,
                    service: service,
                    bundleID: appID
                ),
                label: "\(action.title) \(permission.title)"
            )
        case .androidEmulator, .androidDevice:
            let permissions = permission.androidPermissions
            guard !permissions.isEmpty else {
                throw DeviceAutomationError.unsupported(
                    "\(permission.title) has no Android runtime permission."
                )
            }
            var applied = 0
            var lastFailure: String?
            for androidPermission in permissions {
                for arguments in Self.androidPermissionCommands(
                    action: action,
                    package: appID,
                    permission: androidPermission
                ) {
                    let result = try await shell.adbAllowingFailure(
                        serial: device.id,
                        ["shell"] + arguments
                    )
                    if result.exitCode == 0 {
                        if arguments.contains("grant") || arguments.contains("revoke") {
                            applied += 1
                        }
                        continue
                    }
                    let failure = Self.androidShellException(
                        result.standardOutput + "\n" + result.standardError
                    )
                    if let failure, Self.isIgnorableAndroidPermissionFailure(failure) {
                        break
                    }
                    lastFailure = failure ?? "\(action.title) \(permission.title) failed."
                }
            }
            if applied == 0 {
                if let lastFailure {
                    throw DeviceAutomationError.commandFailed(lastFailure)
                }
                throw DeviceAutomationError.unsupported(
                    "\(appID) doesn’t request \(permission.title.lowercased()) on Android."
                )
            }
        case .iOSDevice:
            throw DeviceAutomationError.unsupported(Self.iOSDeviceMessage)
        }
    }

    func resetAllPermissions(appID: String, on device: StreamedDevice) async throws {
        try Self.requireIdentifier(appID)
        switch device.kind {
        case .iOSSimulator:
            try await shell.simctl(
                ["privacy", device.id, "reset", "all", appID],
                label: "Reset permissions"
            )
        case .androidEmulator, .androidDevice:
            var resetAny = false
            for permission in AppPermission.allCases where !permission.androidPermissions.isEmpty {
                do {
                    try await apply(.reset, permission, appID: appID, on: device)
                    resetAny = true
                } catch let error as DeviceAutomationError {
                    if case .unsupported = error { continue }
                    throw error
                }
            }
            if !resetAny {
                throw DeviceAutomationError.unsupported(
                    "\(appID) doesn’t request any runtime permissions on Android."
                )
            }
        case .iOSDevice:
            throw DeviceAutomationError.unsupported(Self.iOSDeviceMessage)
        }
    }

    func sendPush(
        payload: Data,
        bundleID: String,
        on device: StreamedDevice
    ) async throws {
        try Self.requireIdentifier(bundleID)
        switch device.kind {
        case .iOSSimulator:
            try await shell.simctl(
                ["push", device.id, bundleID, "-"],
                standardInput: payload,
                label: "Send push"
            )
        case .androidEmulator, .androidDevice:
            throw DeviceAutomationError.unsupported(
                "Android pushes need Firebase Cloud Messaging; Viewport sends simulated pushes to iOS Simulators."
            )
        case .iOSDevice:
            throw DeviceAutomationError.unsupported(Self.iOSDeviceMessage)
        }
    }

    nonisolated static let iOSDeviceMessage =
        "Physical iPhones are view-only in Viewport."

    nonisolated static func simctlPrivacyArguments(
        udid: String,
        action: PermissionAction,
        service: String,
        bundleID: String
    ) -> [String] {
        ["privacy", udid, action.rawValue, service, bundleID]
    }

    /// `pm` commands for one permission. Reset revokes, then clears the
    /// user-set / user-fixed flags so the app prompts again.
    nonisolated static func androidPermissionCommands(
        action: PermissionAction,
        package: String,
        permission: String
    ) -> [[String]] {
        switch action {
        case .grant:
            [["pm", "grant", package, permission]]
        case .revoke:
            [["pm", "revoke", package, permission]]
        case .reset:
            [
                ["pm", "revoke", package, permission],
                ["pm", "clear-permission-flags", package, permission, "user-set", "user-fixed"]
            ]
        }
    }

    /// Pulls the exception message out of a `pm` stack trace.
    nonisolated static func androidShellException(_ output: String) -> String? {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let line = lines.first(where: {
            ($0.hasPrefix("java.") || $0.hasPrefix("android.")) && $0.contains(":")
                || $0.hasPrefix("Error:")
        }) else {
            return lines.first { !$0.isEmpty && !$0.hasPrefix("at ") && !$0.hasPrefix("Exception occurred") }
        }
        guard let colon = line.firstIndex(of: ":") else { return line }
        let message = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return message.isEmpty ? line : message
    }

    /// Permissions an app doesn't declare, or that don't exist on this API level.
    nonisolated static func isIgnorableAndroidPermissionFailure(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("has not requested permission")
            || lowered.contains("unknown permission")
            || lowered.contains("not a changeable permission type")
            || lowered.contains("is not a runtime permission")
    }

    private static func requireIdentifier(_ identifier: String) throws {
        guard InstalledAppParser.isValidIdentifier(identifier) else {
            throw DeviceAutomationError.commandFailed(
                "Enter an app bundle ID or package name, such as com.example.app."
            )
        }
    }
}
