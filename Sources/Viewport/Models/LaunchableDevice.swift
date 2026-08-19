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
    let id: String
    let source: ViewerSource
    let name: String
    let runtime: String?
    let state: DeviceState

    var detail: String {
        [runtime, state.label]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// Matches a live pane guest, including Android where the pane uses an ADB
    /// serial while Play/boot uses the AVD name.
    func matchesSessionGuest(_ guest: StreamedDevice) -> Bool {
        switch guest.kind {
        case .iOSSimulator:
            return source == .iOS && id == guest.id
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
