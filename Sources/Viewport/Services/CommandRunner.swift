import Darwin
import Foundation

struct CommandResult: Equatable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

struct CommandDataResult: Equatable {
    let exitCode: Int32
    let standardOutput: Data
    let standardError: Data
}

enum CommandRunnerError: LocalizedError {
    case executableNotFound(String)
    case failedToLaunch(String)
    case commandFailed(command: String, code: Int32, message: String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case let .executableNotFound(name):
            "\(name) is not installed."
        case let .failedToLaunch(message):
            message
        case let .commandFailed(command, code, message):
            "\(command) exited with code \(code): \(message)"
        case let .timedOut(command):
            "\(command) timed out."
        }
    }
}

actor CommandRunner {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        timeout: TimeInterval? = nil
    ) async throws -> CommandResult {
        let result = try await runData(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout
        )

        return CommandResult(
            exitCode: result.exitCode,
            standardOutput: String(decoding: result.standardOutput, as: UTF8.self),
            standardError: String(decoding: result.standardError, as: UTF8.self)
        )
    }

    func runData(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        timeout: TimeInterval? = nil
    ) async throws -> CommandDataResult {
        try Task.checkCancellation()
        let execution = ProcessExecution(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout
        )
        return try await withTaskCancellationHandler {
            try await execution.run()
        } onCancel: {
            execution.cancel()
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

private final class ProcessExecution: @unchecked Sendable {
    private let process = Process()
    private let standardOutput = Pipe()
    private let standardError = Pipe()
    private let timeout: TimeInterval?
    private let commandName: String
    private let lock = NSLock()

    private var continuation: CheckedContinuation<CommandDataResult, Error>?
    private var output = Data()
    private var errorOutput = Data()
    private var outputIsFinished = false
    private var errorIsFinished = false
    private var exitCode: Int32?
    private var cancellationRequested = false
    private var launchHasStarted = false
    private var forcedError: Error?
    private var hasResumed = false

    init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?
    ) {
        self.timeout = timeout
        commandName = ([executable.lastPathComponent] + arguments)
            .joined(separator: " ")

        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            environment,
            uniquingKeysWith: { _, override in override }
        )
        process.standardOutput = standardOutput
        process.standardError = standardError
    }

    func run() async throws -> CommandDataResult {
        try await withCheckedThrowingContinuation { continuation in
            start(continuation: continuation)
        }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        forcedError = CancellationError()
        let isRunning = process.isRunning
        let shouldFinishWithoutLaunch = continuation != nil
            && !launchHasStarted
        let shouldForceFinish = launchHasStarted && !isRunning
        lock.unlock()

        if isRunning {
            stopProcess()
            scheduleForcedCompletion(after: 0.6)
        } else if shouldFinishWithoutLaunch || shouldForceFinish {
            forceFinishPipes()
        }
    }

    private func start(
        continuation: CheckedContinuation<CommandDataResult, Error>
    ) {
        lock.lock()
        self.continuation = continuation
        let isCancelled = cancellationRequested
        lock.unlock()

        guard !isCancelled else {
            finishWithoutProcess()
            return
        }

        standardOutput.fileHandleForReading.readabilityHandler = {
            [weak self] handle in
            self?.consume(handle.availableData, isStandardOutput: true)
        }
        standardError.fileHandleForReading.readabilityHandler = {
            [weak self] handle in
            self?.consume(handle.availableData, isStandardOutput: false)
        }
        process.terminationHandler = { [weak self] process in
            self?.processDidTerminate(with: process.terminationStatus)
        }

        lock.lock()
        launchHasStarted = true
        lock.unlock()
        do {
            try process.run()
        } catch {
            lock.lock()
            forcedError = CommandRunnerError.failedToLaunch(
                error.localizedDescription
            )
            outputIsFinished = true
            errorIsFinished = true
            exitCode = -1
            let completion = takeCompletionIfReady()
            lock.unlock()
            resume(completion)
            return
        }

        lock.lock()
        let shouldCancelAfterLaunch = cancellationRequested
        lock.unlock()
        if shouldCancelAfterLaunch {
            stopProcess()
            scheduleForcedCompletion(after: 0.6)
        }

        if let timeout {
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + timeout
            ) { [weak self] in
                self?.timeOutIfNeeded()
            }
        }
    }

    private func consume(_ data: Data, isStandardOutput: Bool) {
        lock.lock()
        if data.isEmpty {
            if isStandardOutput {
                outputIsFinished = true
            } else {
                errorIsFinished = true
            }
        } else if isStandardOutput {
            output.append(data)
        } else {
            errorOutput.append(data)
        }
        let completion = takeCompletionIfReady()
        lock.unlock()
        resume(completion)
    }

    private func processDidTerminate(with status: Int32) {
        lock.lock()
        exitCode = status
        let completion = takeCompletionIfReady()
        lock.unlock()
        resume(completion)

        if completion == nil {
            // Pipe EOF can race with termination on macOS. Don't leave the
            // continuation hung if empty readability callbacks never arrive.
            scheduleForcedCompletion(after: 0.25)
        }
    }

    private func timeOutIfNeeded() {
        lock.lock()
        guard !hasResumed, exitCode == nil else {
            lock.unlock()
            return
        }
        forcedError = CommandRunnerError.timedOut(commandName)
        lock.unlock()
        stopProcess()
        scheduleForcedCompletion(after: 0.6)
    }

    private func stopProcess() {
        if process.isRunning {
            process.terminate()
        }

        let pid = process.processIdentifier
        guard pid > 0 else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + 0.5
        ) { [weak self] in
            guard let self, self.process.isRunning else { return }
            Darwin.kill(pid, SIGKILL)
        }
    }

    private func scheduleForcedCompletion(after delay: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + delay
        ) { [weak self] in
            self?.forceFinishPipes()
        }
    }

    private func forceFinishPipes() {
        lock.lock()
        guard !hasResumed else {
            lock.unlock()
            return
        }
        outputIsFinished = true
        errorIsFinished = true
        if exitCode == nil {
            exitCode = -1
        }
        let completion = takeCompletionIfReady()
        lock.unlock()
        resume(completion)
    }

    private func finishWithoutProcess() {
        lock.lock()
        outputIsFinished = true
        errorIsFinished = true
        exitCode = -1
        let completion = takeCompletionIfReady()
        lock.unlock()
        resume(completion)
    }

    private func takeCompletionIfReady() -> Result<CommandDataResult, Error>? {
        guard !hasResumed,
              outputIsFinished,
              errorIsFinished,
              let exitCode else {
            return nil
        }
        hasResumed = true

        if let forcedError {
            return .failure(forcedError)
        }
        return .success(
            CommandDataResult(
                exitCode: exitCode,
                standardOutput: output,
                standardError: errorOutput
            )
        )
    }

    private func resume(
        _ completion: Result<CommandDataResult, Error>?
    ) {
        guard let completion else { return }
        standardOutput.fileHandleForReading.readabilityHandler = nil
        standardError.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: completion)
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
