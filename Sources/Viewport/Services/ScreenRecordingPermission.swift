import AppKit
import CoreGraphics
import Foundation

enum ScreenRecordingPermission {
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Opens Privacy → Screen Recording. After ad-hoc rebuilds macOS often keeps
    /// a stale enabled "Viewport" row for an old code identity — toggle it, or
    /// enable the new Viewport row, then return to the app.
    static func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate),
               NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    /// Opens Settings when access is missing, then requests the system prompt.
    /// Returns whether Screen Recording is granted afterward.
    @discardableResult
    static func requestAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        openSystemSettings()
        return CGRequestScreenCaptureAccess()
    }
}
