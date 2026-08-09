import Foundation

enum ViewerSource: String, CaseIterable, Identifiable, Codable {
    case web
    case android
    case iOS

    var id: String { rawValue }

    var title: String {
        switch self {
        case .web:
            "Web"
        case .android:
            "Android"
        case .iOS:
            "iOS"
        }
    }

    var detail: String {
        switch self {
        case .web:
            "Browser"
        case .android:
            "Device"
        case .iOS:
            "Device"
        }
    }

    var launchDetail: String {
        switch self {
        case .web:
            "Browser"
        case .android:
            "Emulator"
        case .iOS:
            "Simulator"
        }
    }

    var systemImage: String {
        switch self {
        case .web:
            "globe"
        case .android:
            "apps.iphone"
        case .iOS:
            "iphone"
        }
    }
}

struct CaptureDescriptor: Equatable {
    let applicationName: String
    let bundleIdentifier: String
    let windowTitle: String

    func matches(_ source: ViewerSource) -> Bool {
        let application = applicationName.lowercased()
        let bundle = bundleIdentifier.lowercased()
        let title = windowTitle.lowercased()
        let combined = "\(application) \(bundle) \(title)"

        switch source {
        case .web:
            return false
        case .android:
            return [
                "qemu-system",
                "android emulator",
                "genymotion",
                "bluestacks",
                "noxplayer"
            ].contains(where: combined.contains)
        case .iOS:
            return bundle.contains("iphonesimulator")
                || application == "simulator"
                || title.contains("ios simulator")
        }
    }
}
