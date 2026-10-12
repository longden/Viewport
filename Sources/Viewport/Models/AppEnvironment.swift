import Foundation

/// Runtime permissions that can be set from the Apps tools on both platforms.
enum AppPermission: String, CaseIterable, Identifiable {
    case location
    case locationAlways
    case camera
    case microphone
    case photos
    case contacts
    case calendar
    case reminders
    case motion
    case notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .location: "Location (while using)"
        case .locationAlways: "Location (always)"
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .photos: "Photos"
        case .contacts: "Contacts"
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .motion: "Motion & fitness"
        case .notifications: "Notifications"
        }
    }

    var systemImage: String {
        switch self {
        case .location: "location"
        case .locationAlways: "location.fill"
        case .camera: "camera"
        case .microphone: "mic"
        case .photos: "photo.on.rectangle"
        case .contacts: "person.crop.circle"
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .motion: "figure.walk"
        case .notifications: "bell.badge"
        }
    }

    /// `simctl privacy` service name. Simulator has no camera, and notification
    /// permission isn't exposed by simctl.
    var simctlService: String? {
        switch self {
        case .location: "location"
        case .locationAlways: "location-always"
        case .camera, .notifications: nil
        case .microphone: "microphone"
        case .photos: "photos"
        case .contacts: "contacts"
        case .calendar: "calendar"
        case .reminders: "reminders"
        case .motion: "motion"
        }
    }

    /// Android runtime permissions behind this row. Media permissions cover
    /// both Android 13+ and the legacy storage permission.
    var androidPermissions: [String] {
        switch self {
        case .location:
            ["android.permission.ACCESS_FINE_LOCATION", "android.permission.ACCESS_COARSE_LOCATION"]
        case .locationAlways:
            [
                "android.permission.ACCESS_FINE_LOCATION",
                "android.permission.ACCESS_COARSE_LOCATION",
                "android.permission.ACCESS_BACKGROUND_LOCATION"
            ]
        case .camera:
            ["android.permission.CAMERA"]
        case .microphone:
            ["android.permission.RECORD_AUDIO"]
        case .photos:
            [
                "android.permission.READ_MEDIA_IMAGES",
                "android.permission.READ_MEDIA_VIDEO",
                "android.permission.READ_EXTERNAL_STORAGE"
            ]
        case .contacts:
            ["android.permission.READ_CONTACTS", "android.permission.WRITE_CONTACTS"]
        case .calendar:
            ["android.permission.READ_CALENDAR", "android.permission.WRITE_CALENDAR"]
        case .reminders:
            []
        case .motion:
            ["android.permission.ACTIVITY_RECOGNITION"]
        case .notifications:
            ["android.permission.POST_NOTIFICATIONS"]
        }
    }
}

enum PermissionAction: String, CaseIterable, Identifiable {
    case grant
    case revoke
    case reset

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grant: "Allow"
        case .revoke: "Deny"
        case .reset: "Reset"
        }
    }

    var pastTense: String {
        switch self {
        case .grant: "Allowed"
        case .revoke: "Denied"
        case .reset: "Reset"
        }
    }
}

struct InstalledApp: Identifiable, Hashable {
    let id: String
    let name: String

    var menuLabel: String {
        name == id ? id : "\(name) — \(id)"
    }
}

enum InstalledAppParser {
    /// `simctl listapps` prints an OpenStep plist keyed by bundle ID.
    static func parseSimulatorApps(_ output: String, includeSystem: Bool = false) -> [InstalledApp] {
        guard let data = output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any] else {
            return []
        }
        return plist.compactMap { bundleID, value -> InstalledApp? in
            guard let info = value as? [String: Any] else { return nil }
            let type = info["ApplicationType"] as? String
            guard includeSystem || type == "User" else { return nil }
            let name = (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String)
                ?? bundleID
            return InstalledApp(id: bundleID, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `pm list packages` lines look like `package:com.example.app`.
    static func parseAndroidPackages(_ output: String) -> [InstalledApp] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> InstalledApp? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("package:") else { return nil }
                let id = String(trimmed.dropFirst("package:".count))
                guard !id.isEmpty else { return nil }
                return InstalledApp(id: id, name: id)
            }
            .sorted { $0.id < $1.id }
    }

    /// Bundle IDs and package names: letters, digits, `.`, `_`, `-`.
    static func isValidIdentifier(_ identifier: String) -> Bool {
        let trimmed = identifier.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 255 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return trimmed.unicodeScalars.allSatisfy(allowed.contains)
            && !trimmed.hasPrefix(".")
            && !trimmed.hasPrefix("-")
    }
}

enum PushPayloadTemplate: String, CaseIterable, Identifiable {
    case alert
    case badgeAndSound
    case deepLink
    case rich
    case silent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alert: "Alert"
        case .badgeAndSound: "Alert, badge, and sound"
        case .deepLink: "Alert with deep link"
        case .rich: "Rich (mutable content)"
        case .silent: "Silent (background)"
        }
    }

    var json: String {
        switch self {
        case .alert:
            """
            {
              "aps": {
                "alert": {
                  "title": "Viewport",
                  "body": "This is a test notification."
                }
              }
            }
            """
        case .badgeAndSound:
            """
            {
              "aps": {
                "alert": {
                  "title": "New message",
                  "subtitle": "From Viewport",
                  "body": "You have 3 unread messages."
                },
                "badge": 3,
                "sound": "default"
              }
            }
            """
        case .deepLink:
            """
            {
              "aps": {
                "alert": {
                  "title": "Order shipped",
                  "body": "Tap to track your package."
                }
              },
              "url": "myapp://orders/1234"
            }
            """
        case .rich:
            """
            {
              "aps": {
                "alert": {
                  "title": "Photo shared",
                  "body": "Long-press to preview."
                },
                "mutable-content": 1,
                "category": "PHOTO"
              },
              "image-url": "https://example.com/image.jpg"
            }
            """
        case .silent:
            """
            {
              "aps": {
                "content-available": 1
              }
            }
            """
        }
    }
}

enum PushPayloadValidator {
    static let maximumBytes = 4_096

    enum ValidationError: LocalizedError, Equatable {
        case invalidJSON(String)
        case notAnObject
        case missingAPS
        case tooLarge(Int)

        var errorDescription: String? {
            switch self {
            case let .invalidJSON(detail):
                "The payload isn’t valid JSON (\(detail))."
            case .notAnObject:
                "The payload must be a JSON object."
            case .missingAPS:
                "The payload needs an \"aps\" dictionary."
            case let .tooLarge(bytes):
                "The payload is \(bytes) bytes; Apple limits pushes to \(PushPayloadValidator.maximumBytes)."
            }
        }
    }

    /// Returns compact JSON ready for `simctl push … -`.
    static func validate(_ text: String) throws -> Data {
        let data = Data(text.utf8)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
                ?? "check commas and quotes"
            throw ValidationError.invalidJSON(detail)
        }
        guard let dictionary = object as? [String: Any] else {
            throw ValidationError.notAnObject
        }
        guard dictionary["aps"] is [String: Any] else {
            throw ValidationError.missingAPS
        }
        let compact = try JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys])
        guard compact.count <= maximumBytes else {
            throw ValidationError.tooLarge(compact.count)
        }
        return compact
    }
}
