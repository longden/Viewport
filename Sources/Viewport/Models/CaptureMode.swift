import Foundation

enum CaptureMode: String, CaseIterable, Identifiable {
    case direct
    case classic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct:
            "Direct"
        case .classic:
            "Legacy"
        }
    }

    var detail: String {
        switch self {
        case .direct:
            "Framebuffer APIs"
        case .classic:
            "Window / scrcpy"
        }
    }

    var systemImage: String {
        switch self {
        case .direct:
            "rectangle.connected.to.line.below"
        case .classic:
            "rectangle.dashed"
        }
    }
}
