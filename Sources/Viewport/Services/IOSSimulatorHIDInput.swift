import AppKit
import Foundation
import IndigoTouch

/// Direct Simulator HID input. Events are sent to CoreSimulator rather than to
/// Simulator.app, so Viewport stays in front and needs no Accessibility access.
@MainActor
final class IOSSimulatorHIDInput {
    private var session: UnsafeMutableRawPointer?
    private var sessionUDID: String?

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

    func touchDown(at point: CGPoint, udid: String) {
        sendTouch(point, phase: 1, udid: udid)
    }

    func touchMove(to point: CGPoint, udid: String) {
        sendTouch(point, phase: 0, udid: udid)
    }

    func touchUp(at point: CGPoint, udid: String) {
        sendTouch(point, phase: 2, udid: udid)
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

    private func sendTouch(
        _ point: CGPoint,
        phase: Int32,
        udid: String
    ) {
        guard let session = session(for: udid) else { return }
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
            report(error, operation: "send touch")
            closeSession()
        }
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
            report(error, operation: "send key")
            closeSession()
        }
        return succeeded
    }

    private func session(for udid: String) -> UnsafeMutableRawPointer? {
        if sessionUDID == udid, let session {
            return session
        }
        closeSession()
        guard isAvailable else { return nil }

        var error = errorBuffer()
        guard let opened = ViewportHIDSessionOpen(
            udid,
            &error,
            error.count
        ) else {
            report(error, operation: "open HID session")
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

    private func report(_ buffer: [CChar], operation: String) {
        let message = buffer.withUnsafeBufferPointer { pointer in
            pointer.baseAddress.map(String.init(cString:)) ?? "Unknown error"
        }
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
