import Foundation

struct AndroidEmulatorProfile: Identifiable, Hashable {
    let id: String

    var displayName: String {
        switch id {
        case "small_phone":
            "Small Phone"
        case "medium_phone":
            "Medium Phone"
        case "medium_tablet":
            "Medium Tablet"
        case "small_desktop":
            "Small Desktop"
        case "medium_desktop":
            "Medium Desktop"
        case "large_desktop":
            "Large Desktop"
        default:
            id.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var detail: String {
        switch id {
        case "small_phone", "medium_phone":
            "Best for everyday app testing"
        case "medium_tablet":
            "Larger screen for tablet layouts"
        case "small_desktop", "medium_desktop", "large_desktop":
            "Desktop-class Android window"
        default:
            "Android virtual device"
        }
    }

    var isRecommended: Bool {
        id == "medium_phone"
    }

    var systemImage: String {
        isRecommended ? "plus.circle.fill" : "plus.circle"
    }
}
