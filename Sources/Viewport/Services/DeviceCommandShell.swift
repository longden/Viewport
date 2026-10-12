import Foundation

/// adb / simctl execution for the environment tools (location, apps, network,
/// inspector). Failures surface as `DeviceAutomationError` like the compare tools.
actor DeviceCommandShell {
    private let runner: CommandRunner
    private let adbURL: URL?
    private let simctlBase: SimctlCommand
    private let developerEnvironment: [String: String]

    init(
        runner: CommandRunner = CommandRunner(),
        toolchains: ToolchainLocator = ToolchainLocator()
    ) {
        self.runner = runner
        adbURL = toolchains.adb
        simctlBase = toolchains.simctlCommand([])
        developerEnvironment = toolchains.developerEnvironment
    }

    nonisolated var hasADB: Bool { adbURL != nil }

    @discardableResult
    func adb(
        serial: String,
        _ arguments: [String],
        label: String,
        timeout: TimeInterval = 15
    ) async throws -> CommandResult {
        let result = try await adbAllowingFailure(
            serial: serial,
            arguments,
            timeout: timeout
        )
        guard result.exitCode == 0 else {
            throw DeviceAutomationError.commandFailed(
                DeviceAutomationService.cleanMessage(
                    stdout: result.standardOutput,
                    stderr: result.standardError,
                    fallback: "\(label) failed."
                )
            )
        }
        return result
    }

    /// Returns the raw result so callers can inspect output from tools that
    /// report errors on stdout with a zero exit code (`pm`, `emu`).
    func adbAllowingFailure(
        serial: String,
        _ arguments: [String],
        timeout: TimeInterval = 15
    ) async throws -> CommandResult {
        guard let adbURL else {
            throw DeviceAutomationError.commandFailed("adb is not available.")
        }
        return try await runner.run(
            executable: adbURL,
            arguments: ["-s", serial] + arguments,
            timeout: timeout
        )
    }

    /// Emulator console command (`adb emu …`). The console reports failures as
    /// `KO: …` on stdout with a zero exit code.
    func emulatorConsole(
        serial: String,
        _ arguments: [String],
        label: String
    ) async throws {
        let result = try await adb(serial: serial, ["emu"] + arguments, label: label)
        if let failure = Self.emulatorConsoleFailure(in: result.standardOutput) {
            throw DeviceAutomationError.commandFailed("\(label) failed: \(failure)")
        }
    }

    nonisolated static func emulatorConsoleFailure(in output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("KO") }
            .map { line in
                let message = line.dropFirst(2).trimmingCharacters(
                    in: CharacterSet(charactersIn: ": ")
                )
                return message.isEmpty ? "the emulator rejected the command" : message
            }
    }

    func adbData(
        serial: String,
        _ arguments: [String],
        label: String,
        timeout: TimeInterval = 20
    ) async throws -> Data {
        guard let adbURL else {
            throw DeviceAutomationError.commandFailed("adb is not available.")
        }
        let result = try await runner.runData(
            executable: adbURL,
            arguments: ["-s", serial] + arguments,
            timeout: timeout
        )
        guard result.exitCode == 0 else {
            throw DeviceAutomationError.commandFailed(
                DeviceAutomationService.cleanMessage(
                    stdout: String(decoding: result.standardOutput, as: UTF8.self),
                    stderr: String(decoding: result.standardError, as: UTF8.self),
                    fallback: "\(label) failed."
                )
            )
        }
        return result.standardOutput
    }

    @discardableResult
    func simctl(
        _ arguments: [String],
        standardInput: Data? = nil,
        label: String,
        timeout: TimeInterval = 15
    ) async throws -> CommandResult {
        let result = try await runner.run(
            executable: simctlBase.executable,
            arguments: simctlBase.arguments + arguments,
            environment: developerEnvironment,
            standardInput: standardInput,
            timeout: timeout
        )
        guard result.exitCode == 0 else {
            throw DeviceAutomationError.commandFailed(
                DeviceAutomationService.cleanMessage(
                    stdout: result.standardOutput,
                    stderr: result.standardError,
                    fallback: "\(label) failed."
                )
            )
        }
        return result
    }
}

extension DeviceInjectionResult {
    /// Records one device outcome; unsupported devices are skipped, not failed.
    mutating func record(_ device: StreamedDevice, _ outcome: Result<Void, Error>) {
        switch outcome {
        case .success:
            succeeded.append(device.name)
        case let .failure(error):
            if case let .unsupported(message) = error as? DeviceAutomationError {
                if !skipped.contains(message) {
                    skipped.append(message)
                }
            } else {
                skipped.append("\(device.name): \(error.localizedDescription)")
            }
        }
    }

    /// Runs `work` per device and collects the outcomes.
    static func collect(
        _ devices: [StreamedDevice],
        _ work: (StreamedDevice) async throws -> Void
    ) async -> DeviceInjectionResult {
        var result = DeviceInjectionResult()
        for device in devices {
            do {
                try await work(device)
                result.record(device, .success(()))
            } catch {
                result.record(device, .failure(error))
            }
        }
        return result
    }
}
