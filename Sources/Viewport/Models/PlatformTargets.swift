import Foundation

/// Which visible panes an environment action applies to.
struct PlatformTargets: Equatable {
    var android: Bool
    var iOS: Bool
    var web: Bool

    init(android: Bool = true, iOS: Bool = true, web: Bool = true) {
        self.android = android
        self.iOS = iOS
        self.web = web
    }

    func includes(_ source: ViewerSource) -> Bool {
        switch source {
        case .android: android
        case .iOS: iOS
        case .web: web
        }
    }

    init(defaults: UserDefaults, key: String) {
        let stored = defaults.dictionary(forKey: key) as? [String: Bool] ?? [:]
        self.init(
            android: stored["android"] ?? true,
            iOS: stored["iOS"] ?? true,
            web: stored["web"] ?? true
        )
    }

    func save(to defaults: UserDefaults, key: String) {
        defaults.set(["android": android, "iOS": iOS, "web": web], forKey: key)
    }
}

/// One-line outcome shown under an environment action.
struct EnvironmentStatus: Equatable {
    let message: String
    let isError: Bool

    static func from(_ result: DeviceInjectionResult, verb: String) -> EnvironmentStatus {
        EnvironmentStatus(
            message: result.summary(verb: verb),
            isError: !result.didSucceed
        )
    }

    static func failure(_ error: Error) -> EnvironmentStatus {
        EnvironmentStatus(message: error.localizedDescription, isError: true)
    }

    var systemImage: String {
        isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }
}
