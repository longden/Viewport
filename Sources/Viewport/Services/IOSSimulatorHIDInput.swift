import AppKit
import Foundation
import IndigoTouch

/// Direct Simulator HID input via SimulatorKit Indigo.
///
/// Coordinates are **framebuffer-normalized** top-left 0…1 (same space as
/// Surface / `simctl` frames). Do not apply Simulator.app chrome crop here —
/// that crop belongs only to host-window capture. Events go to CoreSimulator,
/// so Viewport can stay frontmost without Accessibility permission.
@MainActor
final class IOSSimulatorHIDInput {
    // Accessed from nonisolated `deinit` to close the native session.
    private nonisolated(unsafe) var session: UnsafeMutableRawPointer?
    private var sessionUDID: String?
    /// Last native error string for callers that want a richer failure message.
    private(set) var lastErrorMessage: String?

    deinit {
        if let session {
            ViewportHIDSessionClose(session)
        }
    }

    var isAvailable: Bool {
        ViewportHIDLoadFrameworks()
    }

    func reset() {
        closeSession()
    }

    @discardableResult
    func touchDown(at point: CGPoint, udid: String) -> Bool {
        sendTouch(point, phase: 1, udid: udid)
    }

    @discardableResult
    func touchMove(to point: CGPoint, udid: String) -> Bool {
        // Prefer touch-down samples for drags. Move/drag NSEvent types are
        // rate-limited inside IndigoHIDMessageForMouseNSEvent on Xcode 26.
        sendTouch(point, phase: 1, udid: udid)
    }

    @discardableResult
    func touchUp(at point: CGPoint, udid: String) -> Bool {
        sendTouch(point, phase: 2, udid: udid)
    }

    /// Hardware Home button (down + up). Prefer this over a home-indicator
    /// swipe — `IndigoHIDMessageForMouseNSEvent` rate-limits dense move streams
    /// and can return NULL mid-gesture on Xcode 26.
    @discardableResult
    func pressHomeButton(udid: String) async -> Bool {
        await pressHardwareButton(code: 0, udid: udid)
    }

    /// Hardware Lock / side button (down + up).
    @discardableResult
    func pressLockButton(udid: String) async -> Bool {
        await pressHardwareButton(code: 1, udid: udid)
    }

    /// Injects a timed swipe.
    ///
    /// Matches Meta idb: a stream of touch-*down* samples with delays, then up.
    /// Xcode 26's `IndigoHIDMessageForMouseNSEvent` rate-limits dragged/move
    /// event types and returns NULL ("Could not create an Indigo HID message"),
    /// so we never send phase-0 moves for gestures.
    @discardableResult
    func swipe(
        from start: CGPoint,
        to end: CGPoint,
        duration: TimeInterval,
        udid: String
    ) async -> Bool {
        let distance = hypot(end.x - start.x, end.y - start.y)
        let steps = distance < 0.02
            ? 1
            : max(3, min(Int(distance / 0.08), 12))
        let stepDelay = max(duration / Double(steps + 2), 0.025)

        for step in 0...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress
            )
            guard touchDown(at: point, udid: udid) else { return false }
            try? await Task.sleep(for: .seconds(stepDelay))
        }

        // Extra down at the end avoids inertial scroll on Apple Silicon sims (idb).
        guard touchDown(at: end, udid: udid) else { return false }
        try? await Task.sleep(for: .seconds(stepDelay))
        return touchUp(at: end, udid: udid)
    }

    func sendKey(_ event: NSEvent, udid: String) -> Bool {
        guard event.type == .keyDown,
              let usage = Self.hidUsage(for: event) else {
            return false
        }

        let modifiers: [(NSEvent.ModifierFlags, UInt32)] = [
            (.control, 0xE0),
            (.shift, 0xE1),
            (.option, 0xE2),
            (.command, 0xE3)
        ]
        let activeModifiers = modifiers.filter {
            event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .contains($0.0)
        }

        for (_, modifierUsage) in activeModifiers {
            guard sendKeyboard(modifierUsage, keyDown: true, udid: udid) else {
                return false
            }
        }
        guard sendKeyboard(usage, keyDown: true, udid: udid),
              sendKeyboard(usage, keyDown: false, udid: udid) else {
            return false
        }
        for (_, modifierUsage) in activeModifiers.reversed() {
            guard sendKeyboard(modifierUsage, keyDown: false, udid: udid) else {
                return false
            }
        }
        return true
    }

    private func pressHardwareButton(code: UInt32, udid: String) async -> Bool {
        guard sendButton(code, keyDown: true, udid: udid) else { return false }
        try? await Task.sleep(for: .milliseconds(60))
        return sendButton(code, keyDown: false, udid: udid)
    }

    @discardableResult
    private func sendTouch(
        _ point: CGPoint,
        phase: Int32,
        udid: String
    ) -> Bool {
        guard let session = session(for: udid) else { return false }
        var error = errorBuffer()
        let succeeded = ViewportHIDSessionSendTouch(
            session,
            min(max(point.x, 0), 1),
            min(max(point.y, 0), 1),
            phase,
            &error,
            error.count
        )
        if !succeeded {
            let message = cString(error)
            lastErrorMessage = message
            report(message, operation: "send touch")
            // Message-build failures (rate-limit NULL) leave the client usable.
            if !message.localizedCaseInsensitiveContains("Could not create") {
                closeSession()
            }
        }
        return succeeded
    }

    private func sendButton(
        _ code: UInt32,
        keyDown: Bool,
        udid: String
    ) -> Bool {
        guard let session = session(for: udid) else { return false }
        var error = errorBuffer()
        let succeeded = ViewportHIDSessionSendButton(
            session,
            code,
            keyDown,
            &error,
            error.count
        )
        if !succeeded {
            let message = cString(error)
            lastErrorMessage = message
            report(message, operation: "send button")
            closeSession()
        }
        return succeeded
    }

    private func sendKeyboard(
        _ usage: UInt32,
        keyDown: Bool,
        udid: String
    ) -> Bool {
        guard let session = session(for: udid) else { return false }
        var error = errorBuffer()
        let succeeded = ViewportHIDSessionSendKeyboard(
            session,
            usage,
            keyDown,
            &error,
            error.count
        )
        if !succeeded {
            let message = cString(error)
            lastErrorMessage = message
            report(message, operation: "send key")
            closeSession()
        }
        return succeeded
    }

    private func session(for udid: String) -> UnsafeMutableRawPointer? {
        if sessionUDID == udid, let session {
            return session
        }
        closeSession()
        guard isAvailable else {
            lastErrorMessage = "SimulatorKit frameworks are unavailable"
            return nil
        }

        var error = errorBuffer()
        guard let opened = ViewportHIDSessionOpen(
            udid,
            &error,
            error.count
        ) else {
            let message = cString(error)
            lastErrorMessage = message
            report(message, operation: "open HID session")
            return nil
        }
        session = opened
        sessionUDID = udid
        return opened
    }

    private func closeSession() {
        if let session {
            ViewportHIDSessionClose(session)
        }
        session = nil
        sessionUDID = nil
    }

    private func errorBuffer() -> [CChar] {
        [CChar](repeating: 0, count: 512)
    }

    private func cString(_ buffer: [CChar]) -> String {
        buffer.withUnsafeBufferPointer { pointer in
            pointer.baseAddress.map(String.init(cString:)) ?? "Unknown error"
        }
    }

    private func report(_ message: String, operation: String) {
        NSLog("Viewport iOS HID %@ failed: %@", operation, message)
    }

    private static func hidUsage(for event: NSEvent) -> UInt32? {
        switch event.keyCode {
        case 36, 76: return 0x28
        case 53: return 0x29
        case 51, 117: return 0x2A
        case 48: return 0x2B
        case 49: return 0x2C
        case 123: return 0x50
        case 124: return 0x4F
        case 125: return 0x51
        case 126: return 0x52
        default: break
        }

        guard let character = event.charactersIgnoringModifiers?
            .lowercased().first else {
            return nil
        }
        if character >= "a", character <= "z",
           let scalar = character.unicodeScalars.first {
            return 0x04 + scalar.value - 97
        }
        if character >= "1", character <= "9",
           let scalar = character.unicodeScalars.first {
            return 0x1E + scalar.value - 49
        }
        if character == "0" { return 0x27 }
        return nil
    }
}
