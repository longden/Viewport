import Foundation

struct CommandResult: Equatable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

enum CommandRunnerError: LocalizedError {
    case executableNotFound(String)
    case failedToLaunch(String)
    case commandFailed(command: String, code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case let .executableNotFound(name):
            "\(name) is not installed."
        case let .failedToLaunch(message):
            message
        case let .commandFailed(command, code, message):
            "\(command) exited with code \(code): \(message)"
        }
    }
}

actor CommandRunner {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:]
    ) async throws -> CommandResult {
        try Task.checkCancellation()

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()

        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            environment,
            uniquingKeysWith: { _, override in override }
        )
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            throw CommandRunnerError.failedToLaunch(error.localizedDescription)
        }

        let outputHandle = standardOutput.fileHandleForReading
        let errorHandle = standardError.fileHandleForReading

        return try await withTaskCancellationHandler {
            let outputTask = Task.detached(priority: .utility) {
                outputHandle.readDataToEndOfFile()
            }
            let errorTask = Task.detached(priority: .utility) {
                errorHandle.readDataToEndOfFile()
            }
            let exitTask = Task.detached(priority: .utility) {
                process.waitUntilExit()
                return process.terminationStatus
            }

            let exitCode = await exitTask.value
            let outputData = await outputTask.value
            let errorData = await errorTask.value
            try Task.checkCancellation()

            return CommandResult(
                exitCode: exitCode,
                standardOutput: String(decoding: outputData, as: UTF8.self),
                standardError: String(decoding: errorData, as: UTF8.self)
            )
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    func launchDetached(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:]
    ) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            environment,
            uniquingKeysWith: { _, override in override }
        )
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CommandRunnerError.failedToLaunch(error.localizedDescription)
        }
    }
}

enum ExecutableLocator {
    static func executable(
        named name: String,
        candidates: [URL] = []
    ) -> URL? {
        let fileManager = FileManager.default
        let pathCandidates = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
            ?? []

        return (candidates + pathCandidates).first(where: {
            fileManager.isExecutableFile(atPath: $0.path)
        })
    }
}
