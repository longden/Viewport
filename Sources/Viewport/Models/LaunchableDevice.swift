import Foundation

enum DeviceState: String, Codable {
    case shutdown
    case starting
    case booted
    case offline
    case unavailable
    case unknown
}

struct LaunchableDevice: Identifiable, Hashable {
    /// Unique Play-menu row. Light Sim rows use `lightsim:<UDID>` so they can
    /// sit next to the stock simulator while still mapping to the same guest.
    let id: String
    let source: ViewerSource
    let name: String
    let runtime: String?
    let state: DeviceState

    /// Prefix for companion rows that boot the same Simulator through simslim.
    static let lightSimIDPrefix = "lightsim:"

    /// CoreSimulator UDID or Android AVD id — never the Light Sim menu prefix.
    var guestID: String {
        guard id.hasPrefix(Self.lightSimIDPrefix) else { return id }
        return String(id.dropFirst(Self.lightSimIDPrefix.count))
    }

    var isLightSim: Bool {
        id.hasPrefix(Self.lightSimIDPrefix)
    }

    var detail: String {
        [runtime, state.label]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// Companion Play-menu row that slims this Simulator via simslim.
    func asLightSim() -> LaunchableDevice {
        guard source == .iOS, !isLightSim else { return self }
        return LaunchableDevice(
            id: Self.lightSimIDPrefix + id,
            source: source,
            name: "Light Sim — \(name)",
            runtime: runtime,
            state: state
        )
    }

    /// Matches a live pane guest, including Android where the pane uses an ADB
    /// serial while Play/boot uses the AVD name.
    func matchesSessionGuest(_ guest: StreamedDevice) -> Bool {
        switch guest.kind {
        case .iOSSimulator:
            return source == .iOS && guestID == guest.id
        case .androidEmulator:
            guard source == .android else { return false }
            if id == guest.id { return true }
            if name == guest.name { return true }
            let avdName = guest.name.replacingOccurrences(of: " ", with: "_")
            return id == avdName
        case .androidDevice, .iOSDevice:
            return false
        }
    }
}

extension DeviceState {
    var label: String? {
        switch self {
        case .shutdown:
            nil
        case .starting:
            "Starting"
        case .booted:
            "Running"
        case .offline:
            "Offline"
        case .unavailable:
            "Unavailable"
        case .unknown:
            "Unknown"
        }
    }
}
