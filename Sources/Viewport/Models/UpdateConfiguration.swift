import Foundation

struct UpdateConfiguration {
    let isEnabled: Bool
    let installedVersion: String

    init(info: [String: Any], isDevelopmentBuild: Bool) {
        let version = info["CFBundleShortVersionString"] as? String ?? "Development"
        let build = info["CFBundleVersion"] as? String
        installedVersion = build.map { "\(version) (\($0))" } ?? version
        let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:))
        // Sparkle validates releases against the installed app's Apple signing identity.
        // Keep Sparkle pinned: Apple-only verification is supported but deprecated in 2.10.
        let appleSigning = info["ViewportAppleSigningUpdates"] as? Bool == true
            && info["SUPublicEDKey"] == nil
            && info["SUPublicDSAKey"] == nil
            && info["SUVerifyUpdateBeforeExtraction"] as? Bool != true
            && info["SURequireSignedFeed"] as? Bool != true
        isEnabled = !isDevelopmentBuild
            && info["ViewportUpdatesEnabled"] as? Bool == true
            && feed?.scheme == "https"
            && feed?.host != nil
            && feed?.user == nil
            && feed?.password == nil
            && appleSigning
    }

    static var current: UpdateConfiguration {
        #if DEBUG
        let isDevelopmentBuild = true
        #else
        let isDevelopmentBuild = false
        #endif
        return UpdateConfiguration(
            info: Bundle.main.infoDictionary ?? [:],
            isDevelopmentBuild: isDevelopmentBuild
        )
    }
}

/// Result of the quiet update probe shown in the toolbar chip and Updates window.
enum UpdateAvailability: Equatable {
    case unknown
    case checking
    case upToDate
    case available(version: String)
    case failed(String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    /// Sparkle reports "no update" as an error on the finished cycle.
    static func afterCycle(_ current: UpdateAvailability, error: Error?) -> UpdateAvailability {
        guard let error = error as NSError? else {
            return current == .checking ? .upToDate : current
        }
        if isNoUpdate(error) {
            return current.isAvailable ? current : .upToDate
        }
        // Cancelled user-driven sessions keep whatever the probe found.
        if error.domain == NSCocoaErrorDomain, error.code == NSUserCancelledError {
            return current == .checking ? .unknown : current
        }
        return current.isAvailable ? current : .failed(error.localizedDescription)
    }

    static func isNoUpdate(_ error: NSError) -> Bool {
        error.domain == "SUSparkleErrorDomain" && error.code == 1001
    }
}
