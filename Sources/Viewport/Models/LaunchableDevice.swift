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
