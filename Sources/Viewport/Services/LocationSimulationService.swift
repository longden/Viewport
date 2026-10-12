import Foundation

/// Simulated GPS for Simulators and Android emulators.
actor LocationSimulationService {
    private let shell: DeviceCommandShell

    init(shell: DeviceCommandShell = DeviceCommandShell()) {
        self.shell = shell
    }

    func set(_ coordinate: GeoCoordinate, on device: StreamedDevice) async throws {
        switch device.kind {
        case .iOSSimulator:
            try await shell.simctl(
                Self.simctlSetArguments(udid: device.id, coordinate: coordinate),
                label: "Set location"
            )
        case .androidEmulator:
            try await shell.emulatorConsole(
                serial: device.id,
                Self.emulatorGeoFixArguments(coordinate),
                label: "Set location"
            )
        case .androidDevice:
            throw DeviceAutomationError.unsupported(Self.androidDeviceMessage)
        case .iOSDevice:
            throw DeviceAutomationError.unsupported(Self.iOSDeviceMessage)
        }
    }

    func clear(on device: StreamedDevice) async throws {
        switch device.kind {
        case .iOSSimulator:
            try await shell.simctl(
                ["location", device.id, "clear"],
                label: "Clear location"
            )
        case .androidEmulator:
            throw DeviceAutomationError.unsupported(
                "Android emulators keep their last location until you set a new one."
            )
        case .androidDevice:
            throw DeviceAutomationError.unsupported(Self.androidDeviceMessage)
        case .iOSDevice:
            throw DeviceAutomationError.unsupported(Self.iOSDeviceMessage)
        }
    }

    /// Simulator-native route playback; Simulator interpolates between waypoints.
    func startRoute(
        _ route: LocationRoute,
        metersPerSecond: Double,
        on device: StreamedDevice
    ) async throws {
        guard device.kind == .iOSSimulator else {
            throw DeviceAutomationError.unsupported(
                "Native route playback is Simulator-only."
            )
        }
        try await shell.simctl(
            Self.simctlStartArguments(udid: device.id, metersPerSecond: metersPerSecond),
            standardInput: Self.simctlWaypointInput(route),
            label: "Play route"
        )
    }

    nonisolated static let androidDeviceMessage =
        "Physical Android phones need a mock-location app. Use an emulator for simulated GPS."
    nonisolated static let iOSDeviceMessage =
        "Physical iPhones can’t be given a simulated location from Viewport."

    nonisolated static func simctlSetArguments(
        udid: String,
        coordinate: GeoCoordinate
    ) -> [String] {
        ["location", udid, "set", coordinate.simctlArgument]
    }

    /// Waypoints come from stdin (`-`) so long GPX tracks don't hit argv limits.
    nonisolated static func simctlStartArguments(
        udid: String,
        metersPerSecond: Double
    ) -> [String] {
        [
            "location", udid, "start",
            "--speed=\(GeoCoordinate.format(max(metersPerSecond, 0.1), digits: 2))",
            "--interval=1",
            "-"
        ]
    }

    nonisolated static func simctlWaypointInput(_ route: LocationRoute) -> Data {
        Data(
            (route.points.map(\.simctlArgument).joined(separator: "\n") + "\n").utf8
        )
    }

    /// The emulator console takes longitude first.
    nonisolated static func emulatorGeoFixArguments(_ coordinate: GeoCoordinate) -> [String] {
        [
            "geo", "fix",
            GeoCoordinate.format(coordinate.longitude),
            GeoCoordinate.format(coordinate.latitude)
        ]
    }
}
