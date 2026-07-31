import AppKit
import Foundation

actor AndroidDeviceInput {
    private let runner: CommandRunner
    private let adb: URL?

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
        let milliseconds = min(max(Int(duration * 1_000), 100), 2_000)
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
            arguments: ["-s", serial] + arguments
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

    private static func devicePoint(
        _ normalizedPoint: CGPoint,
        deviceSize: CGSize
    ) -> CGPoint {
        CGPoint(
            x: min(max(normalizedPoint.x, 0), 1) * deviceSize.width,
            y: min(max(normalizedPoint.y, 0), 1) * deviceSize.height
        )
    }
}
