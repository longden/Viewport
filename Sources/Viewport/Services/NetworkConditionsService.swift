import Foundation

/// Android network shaping / airplane mode, plus proxy and CA setup per device.
actor NetworkConditionsService {
    private let shell: DeviceCommandShell
    /// Simulators given the proxy CA. simctl can add a trusted root but not
    /// remove one, so clearing the proxy says how to get rid of it.
    private var simulatorsTrustingProxyCA: Set<String> = []

    init(shell: DeviceCommandShell = DeviceCommandShell()) {
        self.shell = shell
    }

    func setProfile(_ profile: NetworkProfile, on device: StreamedDevice) async throws {
        switch device.kind {
        case .androidEmulator:
            for arguments in Self.emulatorProfileCommands(profile) {
                try await shell.emulatorConsole(
                    serial: device.id,
                    arguments,
                    label: "Network \(profile.title)"
                )
            }
        case .androidDevice:
            throw DeviceAutomationError.unsupported(
                "Network throttling works on Android emulators. Physical phones use their real connection."
            )
        case .iOSSimulator:
            throw DeviceAutomationError.unsupported(Self.iOSThrottleMessage)
        case .iOSDevice:
            throw DeviceAutomationError.unsupported("Physical iPhones are view-only in Viewport.")
        }
    }

    func setOffline(_ offline: Bool, on device: StreamedDevice) async throws {
        switch device.kind {
        case .androidEmulator, .androidDevice:
            let result = try await shell.adbAllowingFailure(
                serial: device.id,
                ["shell"] + Self.airplaneModeArguments(offline)
            )
            if result.exitCode != 0 {
                // Android 10 and older: toggle the radios directly.
                for arguments in Self.legacyRadioCommands(offline) {
                    try await shell.adb(
                        serial: device.id,
                        ["shell"] + arguments,
                        label: offline ? "Go offline" : "Go online"
                    )
                }
            }
        case .iOSSimulator:
            throw DeviceAutomationError.unsupported(
                "Simulators share the Mac’s connection and can’t go offline on their own."
            )
        case .iOSDevice:
            throw DeviceAutomationError.unsupported("Physical iPhones are view-only in Viewport.")
        }
    }

    /// `previousReversePort` is the loopback port an earlier apply reversed; it is
    /// removed unless the new settings reuse it.
    func applyProxy(
        _ settings: ProxySettings,
        certificate: ProxyCertificate?,
        previousReversePort: Int? = nil,
        on device: StreamedDevice
    ) async throws -> String? {
        switch device.kind {
        case .androidEmulator, .androidDevice:
            if let previousReversePort,
               !(settings.isLoopback && settings.port == previousReversePort) {
                _ = try? await shell.adbAllowingFailure(
                    serial: device.id,
                    ["reverse", "--remove", "tcp:\(previousReversePort)"]
                )
            }
            if settings.isLoopback {
                try await shell.adb(
                    serial: device.id,
                    Self.androidReverseArguments(port: settings.port),
                    label: "Forward proxy port"
                )
            }
            try await shell.adb(
                serial: device.id,
                ["shell"] + Self.androidProxyArguments(settings.androidProxyValue),
                label: "Set proxy"
            )
            return nil
        case .iOSSimulator:
            if let certificate {
                try await shell.simctl(
                    ["keychain", device.id, "add-root-cert", certificate.url.path],
                    label: "Trust proxy certificate"
                )
                simulatorsTrustingProxyCA.insert(device.id)
                return "Simulators use the Mac’s proxy settings; most proxy apps set them for you. "
                    + "\(device.name) now trusts the proxy CA until its keychain is reset."
            }
            return "Simulators use the Mac’s proxy settings; most proxy apps set them for you."
        case .iOSDevice:
            throw DeviceAutomationError.unsupported("Physical iPhones are view-only in Viewport.")
        }
    }

    func clearProxy(port: Int?, on device: StreamedDevice) async throws {
        switch device.kind {
        case .androidEmulator, .androidDevice:
            try await shell.adb(
                serial: device.id,
                ["shell"] + Self.androidProxyArguments(":0"),
                label: "Clear proxy"
            )
            if let port {
                _ = try? await shell.adbAllowingFailure(
                    serial: device.id,
                    ["reverse", "--remove", "tcp:\(port)"]
                )
            }
        case .iOSSimulator:
            var message = "Simulators follow the Mac’s proxy settings; turn the proxy off in your proxy app."
            if simulatorsTrustingProxyCA.contains(device.id) {
                message += " \(device.name) still trusts the proxy CA; run "
                    + "`xcrun simctl keychain \(device.id) reset` or erase the Simulator to remove it."
            }
            throw DeviceAutomationError.unsupported(message)
        case .iOSDevice:
            throw DeviceAutomationError.unsupported("Physical iPhones are view-only in Viewport.")
        }
    }

    /// Copies the CA into Downloads so it can be installed from Android Settings.
    func copyCertificateToAndroid(
        _ certificate: ProxyCertificate,
        on device: StreamedDevice
    ) async throws {
        guard device.source == .android else {
            throw DeviceAutomationError.unsupported("Certificate copy is for Android devices.")
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewport-proxy-ca-\(UUID().uuidString).crt")
        try Data(certificate.pemText.utf8).write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await shell.adb(
            serial: device.id,
            ["push", temporary.path, Self.androidCertificateDestination],
            label: "Copy certificate"
        )
    }

    nonisolated static let androidCertificateDestination = "/sdcard/Download/viewport-proxy-ca.crt"

    nonisolated static let iOSThrottleMessage =
        "Simulators share the Mac’s connection. Use Network Link Conditioner (Xcode Additional Tools) to throttle them."

    nonisolated static func emulatorProfileCommands(_ profile: NetworkProfile) -> [[String]] {
        [
            ["network", "speed", profile.emulatorSpeed],
            ["network", "delay", profile.emulatorDelay]
        ]
    }

    nonisolated static func airplaneModeArguments(_ offline: Bool) -> [String] {
        ["cmd", "connectivity", "airplane-mode", offline ? "enable" : "disable"]
    }

    nonisolated static func legacyRadioCommands(_ offline: Bool) -> [[String]] {
        let state = offline ? "disable" : "enable"
        return [["svc", "wifi", state], ["svc", "data", state]]
    }

    nonisolated static func androidReverseArguments(port: Int) -> [String] {
        ["reverse", "tcp:\(port)", "tcp:\(port)"]
    }

    /// `:0` is the documented way to clear `http_proxy` without a reboot.
    nonisolated static func androidProxyArguments(_ value: String) -> [String] {
        ["settings", "put", "global", "http_proxy", value]
    }
}
