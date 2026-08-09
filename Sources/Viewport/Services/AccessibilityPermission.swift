import AppKit
import ApplicationServices
import Foundation

enum AccessibilityPermission {
    /// Whether Viewport itself is trusted for Accessibility (AX / System Events).
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts macOS to add Viewport to Privacy → Accessibility when untrusted.
    /// Calling this from the app process (not `/usr/bin/osascript`) is what makes
    /// Viewport appear in the list.
    @discardableResult
    static func requestTrustIfNeeded() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate),
               NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
