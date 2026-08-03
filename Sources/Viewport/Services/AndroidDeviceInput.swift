import AppKit
import Foundation

actor AndroidDeviceInput {
    private let runner: CommandRunner
    private let adb: URL?
    /// Serializes live motion `adb` launches and coalesces MOVE storms.
    nonisolated private let motionLimiter = AndroidMotionEventLimiter()

    init(runner: CommandRunner = CommandRunner()) {
        self.runner = runner

        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        let sdkPath = environment["ANDROID_SDK_ROOT"]
            ?? environment["ANDROID_HOME"]
            ?? home.appendingPathComponent("Library/Android/sdk").path

        adb = ExecutableLocator.executable(
            named: "adb",
            candidates: [
                URL(fileURLWithPath: sdkPath)
                    .appendingPathComponent("platform-tools/adb"),
                URL(fileURLWithPath: "/opt/homebrew/bin/adb")
            ]
        )
    }

    nonisolated var isAvailable: Bool {
        adb != nil
    }

    func tap(
        serial: String,
        deviceSize: CGSize,
        at normalizedPoint: CGPoint
    ) async {
        let point = Self.devicePoint(
            normalizedPoint,
            deviceSize: deviceSize
        )
        _ = try? await run(
            serial: serial,
            arguments: [
                "shell", "input", "tap",
                String(Int(point.x)),
                String(Int(point.y))
            ]
        )
    }

    func swipe(
        serial: String,
        deviceSize: CGSize,
        from start: CGPoint,
        to end: CGPoint,
        duration: TimeInterval
    ) async {
        let startPoint = Self.devicePoint(start, deviceSize: deviceSize)
        let endPoint = Self.devicePoint(end, deviceSize: deviceSize)
        // Keep the injected swipe short so UI feels responsive even when the
        // pointer gesture on macOS lasted longer.
        let milliseconds = min(max(Int(duration * 1_000), 40), 180)
        _ = try? await run(
            serial: serial,
            arguments: [
                "shell", "input", "swipe",
                String(Int(startPoint.x)),
                String(Int(startPoint.y)),
                String(Int(endPoint.x)),
                String(Int(endPoint.y)),
                String(milliseconds)
            ]
        )
    }

    /// Live dragging via `adb shell input motionevent`. MOVE events are
    /// coalesced so a drag cannot spawn dozens of concurrent adb children.
    nonisolated func motionEvent(
        serial: String,
        deviceSize: CGSize,
        action: AndroidMotionAction,
        at normalizedPoint: CGPoint
    ) {
        guard let adb else { return }
        let point = Self.devicePoint(normalizedPoint, deviceSize: deviceSize)
        motionLimiter.submit(
            adb: adb,
            arguments: [
                "-s", serial,
                "shell", "input", "motionevent",
                action.rawValue,
                String(Int(point.x)),
                String(Int(point.y))
            ],
            action: action
        )
    }

    func key(serial: String, event: NSEvent) async {
        guard event.type == .keyDown else { return }
        if let keyCode = Self.androidKeyCode(for: event) {
            _ = try? await run(
                serial: serial,
                arguments: ["shell", "input", "keyevent", keyCode]
            )
            return
        }

        guard let text = event.characters, !text.isEmpty else { return }
        let encoded = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: " ", with: "%s")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\"", with: "\\\"")
        _ = try? await run(
            serial: serial,
            arguments: ["shell", "input", "text", encoded]
        )
    }

    private func run(
        serial: String,
        arguments: [String]
    ) async throws -> CommandResult {
        guard let adb else {
            throw CommandRunnerError.executableNotFound("adb")
        }

        return try await runner.run(
            executable: adb,
            arguments: ["-s", serial] + arguments,
            timeout: 2
        )
    }

    private static func androidKeyCode(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 36, 76:
            "KEYCODE_ENTER"
        case 48:
            "KEYCODE_TAB"
        case 51, 117:
            "KEYCODE_DEL"
        case 53:
            "KEYCODE_ESCAPE"
        case 123:
            "KEYCODE_DPAD_LEFT"
        case 124:
            "KEYCODE_DPAD_RIGHT"
        case 125:
            "KEYCODE_DPAD_DOWN"
        case 126:
            "KEYCODE_DPAD_UP"
        default:
            nil
        }
    }

    nonisolated private static func devicePoint(
        _ normalizedPoint: CGPoint,
        deviceSize: CGSize
    ) -> CGPoint {
        CGPoint(
            x: min(max(normalizedPoint.x, 0), 1) * deviceSize.width,
            y: min(max(normalizedPoint.y, 0), 1) * deviceSize.height
        )
    }
}

enum AndroidMotionAction: String {
    case down = "DOWN"
    case move = "MOVE"
    case up = "UP"
}

/// At most one in-flight `adb` process. MOVE events overwrite each other;
/// DOWN/UP flush the latest MOVE first so the gesture ends at the right point.
private final class AndroidMotionEventLimiter: @unchecked Sendable {
    private struct Launch {
        let adb: URL
        let arguments: [String]
    }

    private let lock = NSLock()
    private var isRunning = false
    private var pendingMove: Launch?
    private var pendingOrdered: [Launch] = []

    func submit(adb: URL, arguments: [String], action: AndroidMotionAction) {
        let launch = Launch(adb: adb, arguments: arguments)
        lock.lock()
        switch action {
        case .move:
            pendingMove = launch
        case .down:
            pendingOrdered.append(launch)
        case .up:
            if let pendingMove {
                pendingOrdered.append(pendingMove)
                self.pendingMove = nil
            }
            pendingOrdered.append(launch)
        }
        let shouldStart = !isRunning
        if shouldStart {
            isRunning = true
        }
        lock.unlock()
        guard shouldStart else { return }
        drain()
    }

    private func drain() {
        lock.lock()
        let next: Launch?
        if !pendingOrdered.isEmpty {
            next = pendingOrdered.removeFirst()
        } else if let pendingMove {
            self.pendingMove = nil
            next = pendingMove
        } else {
            next = nil
            isRunning = false
        }
        lock.unlock()

        guard let next else { return }
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let process = Process()
            process.executableURL = next.adb
            process.arguments = next.arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                // Ignore launch failures; the next gesture event can retry.
            }
            self?.drain()
        }
    }
}
