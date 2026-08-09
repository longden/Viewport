import Foundation

/// Builds `emulator` CLI arguments for headless gRPC capture.
enum AndroidEmulatorLaunchArguments {
    static let preferHeadlessUserDefaultsKey = "preferHeadlessAndroidEmulators"

    /// Default gRPC port for the first headless emulator (`emulator-5554` → 8554).
    static let baseGRPCPort = 8554

    nonisolated static func make(
        avdName: String,
        preferHeadless: Bool,
        runningEmulatorCount: Int
    ) -> [String] {
        var arguments = ["-avd", avdName]
        guard preferHeadless else { return arguments }

        let grpcPort = grpcPort(forRunningEmulatorCount: runningEmulatorCount)
        arguments += ["-no-window", "-grpc", String(grpcPort)]
        return arguments
    }

    nonisolated static func grpcPort(forRunningEmulatorCount count: Int) -> Int {
        baseGRPCPort + max(count, 0)
    }

    /// Reads `emulator_console_auth_token` from the AVD directory when present.
    nonisolated static func consoleAuthToken(
        forAVD avdName: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        guard isSafeAVDName(avdName) else { return nil }
        let tokenURL = homeDirectory
            .appendingPathComponent(".android/avd/\(avdName).avd/emulator_console_auth_token")
        guard let token = try? String(contentsOf: tokenURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Rejects AVD names that could escape `.android/avd/` via path traversal.
    nonisolated static func isSafeAVDName(_ avdName: String) -> Bool {
        let trimmed = avdName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.contains(".."),
              !trimmed.hasPrefix(".") else {
            return false
        }
        return true
    }
}
