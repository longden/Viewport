import Foundation

/// Invokes the [simslim](https://github.com/MobAI-App/simslim) CLI. Viewport does
/// not reimplement daemon allowlists — it only launches the installed tool.
struct SimSlimClient {
    static let installCommand = "brew install mobai-app/tap/simslim"
    static let githubURL = URL(string: "https://github.com/MobAI-App/simslim")!
    static let githubTitle = "simslim on GitHub"
    /// Keep Safari / universal-link services so `simctl openurl` still works.
    static let exceptCategories = "web"
    static let onTimeout: TimeInterval = 600
    static let offTimeout: TimeInterval = 300
    static let statusTimeout: TimeInterval = 45

    private let executable: URL
    private let runner: CommandRunner
    private let environment: [String: String]

    init(
        executable: URL,
        runner: CommandRunner,
        environment: [String: String] = [:]
    ) {
        self.executable = executable
        self.runner = runner
        self.environment = environment
    }

    func enableLightSim(
        udid: String,
        isBooted: Bool,
        runtime: String?
    ) async throws {
        try await run(
            arguments: Self.onArguments(
                udid: udid,
                noReboot: Self.shouldUseNoReboot(
                    isBooted: isBooted,
                    runtime: runtime
                )
            ),
            timeout: Self.onTimeout,
            command: "Enable Light Sim"
        )
    }

    func restoreStockIfSlimmed(udid: String) async throws {
        guard try await isSlimmed(udid: udid) else { return }
        try await run(
            arguments: Self.offArguments(udid: udid),
            timeout: Self.offTimeout,
            command: "Restore stock Simulator"
        )
    }

    func isSlimmed(udid: String) async throws -> Bool {
        let result = try await runner.run(
            executable: executable,
            arguments: Self.statusArguments(udid: udid),
            environment: environment,
            timeout: Self.statusTimeout
        )
        guard result.exitCode == 0 else {
            // Shutdown guests cannot report launchd state; treat as stock.
            return false
        }
        return try Self.isSlimmed(statusJSON: Data(result.standardOutput.utf8))
    }

    private func run(
        arguments: [String],
        timeout: TimeInterval,
        command: String
    ) async throws {
        let result = try await runner.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout
        )
        guard result.exitCode == 0 else {
            throw CommandRunnerError.commandFailed(
                command: command,
                code: result.exitCode,
                message: result.standardError.isEmpty
                    ? result.standardOutput
                    : result.standardError
            )
        }
    }

    static func onArguments(udid: String, noReboot: Bool) -> [String] {
        var arguments = ["on", udid, "--except", exceptCategories]
        if noReboot {
            arguments.insert("--no-reboot", at: 2)
        }
        return arguments
    }

    /// Older runtimes cannot persist launchd overrides across a reboot.
    /// Live slimming also works when simslim has to boot a shutdown guest first.
    static func shouldUseNoReboot(isBooted: Bool, runtime: String?) -> Bool {
        guard !isBooted else { return true }
        guard let runtime, runtime.hasPrefix("iOS ") else { return true }
        let version = runtime.dropFirst("iOS ".count).split(separator: ".")
        guard let major = version.first.flatMap({ Int($0) }) else { return true }
        if major > 18 { return false }
        if major < 18 { return true }
        guard version.count > 1, let minor = Int(version[1]) else {
            return true
        }
        return minor < 5
    }

    static func offArguments(udid: String) -> [String] {
        ["off", udid]
    }

    static func statusArguments(udid: String) -> [String] {
        ["status", udid, "--json"]
    }

    static func isSlimmed(statusJSON: Data) throws -> Bool {
        let status = try JSONDecoder().decode(StatusPayload.self, from: statusJSON)
        return status.managedDisabled > 0
    }

    private struct StatusPayload: Decodable {
        let managedDisabled: Int
    }
}
